import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerRetentionFeedTests {
    @Test func aPurgedGapSnapshotsButCompletionAtFloorMinusOneStaysCurrent() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let key = "user:\(user.id)"
            _ = try await fixture.writePrompt(session: session.identity)
            _ = try await fixture.writePrompt(baseRev: 1, session: session.identity)
            let head = try await fixture.writePrompt(baseRev: 2, session: session.identity)
            let gap = try await fixture.feedRequest(cursors: [key: 1])
            fixture.account.clock.advance(TimeInterval((ServerLimits.changeRetentionDays + 1) * 24 * 60 * 60))
            #expect(try await fixture.retention.run().changes == 3)
            #expect(try await fixture.persistence.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == String(head.seq + 1))
            let snapshot = try await fixture.feed.pull(request: gap, session: session.identity)
            let page = try snapshot.scope(key)
            #expect(page.mode == .snapshot && page.head == head.seq && page.cursor == String(head.seq) && !page.hasMore)
            #expect(page.items.count == 1)
            for _ in 0..<3 {
                let delta = try await fixture.feed.pull(request: snapshot.continuation, session: session.identity).scope(key)
                #expect(delta.mode == .delta && delta.head == head.seq && delta.cursor == page.cursor)
                #expect(delta.items.isEmpty && !delta.hasMore)
                #expect(try await fixture.retention.run() == RetentionCounts())
            }
            let boundary = try await fixture.feedRequest(cursors: [key: head.seq - 1])
            #expect(try await fixture.feed.pull(request: boundary, session: session.identity).scope(key).mode == .snapshot)
        }
    }

    @Test func pendingDeltaPayloadsRemainExactAfterTheirRevisionsArePruned() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let anchorID = GroupTestFixture.otherPrompt
            let anchor = try await fixture.writePrompt(id: anchorID, path: "Anchor.md", session: session.identity)
            let original = promptContent(body: "Original pending event\n")
            _ = try await fixture.writePrompt(content: original, session: session.identity)
            _ = try await fixture.writePrompt(id: anchorID, baseRev: 1, path: "Anchor.md", session: session.identity)
            for rev: Int64 in 1...201 {
                _ = try await fixture.writePrompt(baseRev: rev, content: promptContent(body: "Version \(rev + 1)\n"), session: session.identity)
            }
            let request = try await fixture.feedRequest(cursors: ["user:\(user.id)": anchor.seq])
            let before = try await fixture.feed.pull(request: request, session: session.identity)
            #expect(before.scopes[0].items.count == 3)
            #expect(before.scopes[0].items.first == .upsert(seq: 2, prompt: .init(id: GroupTestFixture.livePrompt, rev: 1,
                path: "Example.md", content: original)))
            #expect(try await fixture.retention.run().revisions == 2)
            #expect(try await fixture.persistence.string("SELECT MIN(rev) AS rev FROM prompt_revisions WHERE prompt_id = \(bind: GroupTestFixture.livePrompt)", column: "rev") == "3")
            #expect(try await fixture.feed.pull(request: request, session: session.identity) == before)
            #expect(try await fixture.persistence.count("changes") == 204)
        }
    }

    @Test func inFlightFrozenPagesSurviveChangePurgeAndPruningTheirCapturedRevision() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let group = try await fixture.group(owner: user)
            let identity = PromptOwnership.group(groupID: group.id)
            let prompts = try await fixture.seedSnapshot(identity: identity, author: user, count: 201)
            fixture.account.clock.advance(TimeInterval((ServerLimits.changeRetentionDays + 1) * 24 * 60 * 60))
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            let page = try first.scope(identity.key)
            #expect(page.hasMore)
            let manifest = try await fixture.persistence.string("SELECT hex(manifest) AS bytes FROM snapshots WHERE scope_key = \(bind: identity.key)", column: "bytes")
            let last = prompts[200]
            for rev: Int64 in 1...201 {
                _ = try await fixture.writePrompt(id: last.id, baseRev: rev, scope: identity.scope, path: last.path,
                    content: snapshotContent(id: last.id, body: "Updated \(rev + 1)\n"), session: session.identity)
            }
            let result = try await fixture.retention.run()
            #expect(result.changes == 201 && result.floors == 3 && result.revisions == 2)
            #expect(try await fixture.persistence.string("SELECT MIN(rev) AS rev FROM prompt_revisions WHERE prompt_id = \(bind: last.id)", column: "rev") == "3")
            #expect(try await fixture.persistence.string("SELECT hex(manifest) AS bytes FROM snapshots WHERE scope_key = \(bind: identity.key)", column: "bytes") == manifest)
            let final = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            let completed = try final.scope(identity.key)
            #expect(completed.mode == .snapshot && completed.cursor == String(page.head) && !completed.hasMore)
            #expect(page.items + completed.items == prompts.map { .upsert(seq: page.head, prompt: $0) })
            let delta = try await fixture.feed.pull(request: final.continuation, session: session.identity).scope(identity.key)
            #expect(delta.mode == .delta && delta.items.count == 1 && !delta.hasMore)
            if case .upsert(_, let prompt) = try #require(delta.items.first) {
                #expect(prompt.id == last.id && prompt.rev == 202 && prompt.content.contains("Updated 202"))
            } else { Issue.record("Expected the retained final upsert") }
        }
    }

    @Test func actualPurgeKeepsRetiredIDsAndAuthorizesBeforeDeletedResponses() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let editor = try await fixture.user("editor")
            let viewer = try await fixture.user("viewer", kind: .admin)
            let outsider = try await fixture.user("outsider", kind: .admin)
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: editor, role: .editor)
            try await fixture.member(groupID: group.id, user: viewer, role: .viewer)
            let session = try await fixture.account.session(owner)
            _ = try await fixture.writePrompt(scope: .group(groupID: group.id), session: session.identity)
            _ = try await fixture.prompts.delete(id: GroupTestFixture.livePrompt, query: .init(baseRev: 1), session: session.identity)
            let retiredAt = try await fixture.persistence.string("SELECT retired_at FROM retired_prompt_ids", column: "retired_at")
            fixture.account.clock.advance(TimeInterval((ServerLimits.changeRetentionDays + 1) * 24 * 60 * 60))
            let result = try await fixture.retention.run()
            #expect(result.changes == 2 && result.tombstones == 1 && result.revisions == 2)
            #expect(try await fixture.persistence.count("prompts") == 0)
            #expect(try await fixture.persistence.count("retired_prompt_ids") == 1)
            #expect(try await fixture.persistence.string("SELECT retired_at FROM retired_prompt_ids", column: "retired_at") == retiredAt)
            for user in [owner, editor, viewer, outsider] {
                let actor = try await fixture.account.session(user)
                let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Revived.md", content: promptContent())
                if user.id == outsider.id {
                    await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.put(id: GroupTestFixture.livePrompt, request: request, session: actor.identity) }
                } else if user.id == viewer.id {
                    await #expect(throws: AccountError.forbidden) { _ = try await fixture.prompts.put(id: GroupTestFixture.livePrompt, request: request, session: actor.identity) }
                } else {
                    await #expect(throws: PromptError(.deleted)) { _ = try await fixture.prompts.put(id: GroupTestFixture.livePrompt, request: request, session: actor.identity) }
                }
            }
            #expect(try await fixture.persistence.count("prompts") == 0)
        }
    }
}

extension GroupTestFixture {
    var retention: RetentionService { .init(database: persistence.database, clock: account.clock.now) }
}
