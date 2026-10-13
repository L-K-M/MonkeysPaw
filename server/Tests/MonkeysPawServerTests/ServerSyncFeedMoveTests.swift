import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedMoveTests {
    @Test func oldGroupPayloadsSurvivePrivateEditsDeletionAndPhysicalHistoryPurge() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader")
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: reader, role: .viewer)
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(reader)
            let personal = PromptOwnership.user(ownerID: reader.id)
            let shared = PromptOwnership.group(groupID: group.id)
            let privateCursor = try #require(await fixture.seedFeed(identity: personal, count: 1).last)
            let groupCursor = try await fixture.writePrompt(id: GroupTestFixture.otherPrompt, scope: shared.scope,
                                                           path: "Baseline.md", session: ownerSession.identity).seq
            let id = GroupTestFixture.livePrompt
            let old = try await fixture.writePrompt(scope: shared.scope, path: "Original.md",
                                                     content: promptContent(id: id, body: "Historical group bytes\n"), session: ownerSession.identity)
            let original = try await fixture.prompts.get(id: id, session: ownerSession.identity)
            let separator = try await fixture.writePrompt(id: GroupTestFixture.secondLivePrompt, scope: shared.scope,
                                                          path: "Separator.md", session: ownerSession.identity)
            let move = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: .user, path: "Private.md"), session: ownerSession.identity)
            _ = try await fixture.writePrompt(baseRev: 2, path: "Edited.md", content: promptContent(id: id, body: "Private bytes must not leak\n"),
                                              session: ownerSession.identity)
            _ = try await fixture.prompts.delete(id: id, query: .init(baseRev: 3), session: ownerSession.identity)
            try await fixture.persistence.database.write { sql in
                try await sql.raw("DELETE FROM prompt_revisions WHERE prompt_id = \(bind: id)").run()
                try await sql.raw("DELETE FROM prompts WHERE id = \(bind: id)").run()
            }
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, shared.key: groupCursor])
            let response = try await fixture.feed.pull(request: request, session: session.identity)
            let page = try response.scope(shared.key)
            #expect(page.items.map(\.seq) == [old.seq, separator.seq, move.seq - 1])
            #expect(page.items.first == .upsert(seq: old.seq, prompt: .init(id: id, rev: 1, path: original.path, content: original.content)))
            #expect(page.items.last == .moveOut(seq: move.seq - 1, id: id))
            #expect(page.cursor == String(move.seq - 1) && page.head == move.seq - 1 && !page.hasMore)
            #expect(response.scopes.count == 2 && response.removed.isEmpty)
            #expect(try response.scope(personal.key).items.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func moveOutThenBackInPreservesTheFinalUpsert(interveningPrompt: Bool) async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("owner")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id), shared = PromptOwnership.group(groupID: group.id)
            let privateCursor = try #require(await fixture.seedFeed(identity: personal, count: 1).last)
            _ = try await fixture.writePrompt(scope: shared.scope, path: "Original.md", session: session.identity)
            let separatorID = GroupTestFixture.secondLivePrompt
            let groupCursor = try await fixture.writePrompt(id: separatorID, scope: shared.scope, path: "Separator.md", session: session.identity).seq
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, shared.key: groupCursor])
            let id = GroupTestFixture.livePrompt
            let leave = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: .user, path: "Private.md"), session: session.identity)
            var separator: Int64?
            if interveningPrompt {
                separator = try await fixture.writePrompt(id: separatorID, baseRev: 1, scope: shared.scope, path: "Separator.md", session: session.identity).seq
            }
            let reenter = try await fixture.prompts.move(id: id, request: .init(baseRev: 2, scope: shared.scope, path: "Returned.md"), session: session.identity)
            let final = try await fixture.prompts.get(id: id, session: session.identity)
            let response = try await fixture.feed.pull(request: request, session: session.identity)
            let page = try response.scope(shared.key)
            #expect(page.items.last == .upsert(seq: reenter.seq, prompt: .init(id: id, rev: 3, path: "Returned.md", content: final.content)))
            if let separator {
                #expect(page.items.map(\.seq) == [leave.seq - 1, separator, reenter.seq])
                #expect(page.items.first == .moveOut(seq: leave.seq - 1, id: id))
            } else { #expect(page.items.count == 1) }
            let privatePage = try response.scope(personal.key)
            #expect(privatePage.items == [.moveOut(seq: reenter.seq - 1, id: id)])
            #expect(privatePage.cursor == String(reenter.seq - 1) && page.cursor == String(reenter.seq))
            #expect(response.scopes.allSatisfy { !$0.hasMore })
        }
    }

    @Test func movePairCanSplitAcrossPagesWithoutSkippingEitherEvent() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("owner")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id), shared = PromptOwnership.group(groupID: group.id)
            let privateCursor = try await fixture.writePrompt(session: session.identity).seq
            let groupCursor = try #require(await fixture.seedFeed(identity: shared, count: 1).last)
            let pending = try await fixture.seedFeed(identity: shared, count: 199, startingID: 5_000)
            let id = GroupTestFixture.livePrompt
            let move = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: shared.scope, path: "Moved.md"), session: session.identity)
            let destination = try await fixture.prompts.get(id: id, session: session.identity)
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, shared.key: groupCursor])
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            let old = try first.scope(personal.key), new = try first.scope(shared.key)
            #expect(old.items == [.moveOut(seq: move.seq - 1, id: id)] && !old.hasMore)
            #expect(old.cursor == String(move.seq - 1))
            #expect(new.items.map(\.seq) == pending && new.hasMore)
            #expect(new.cursor == String(try #require(pending.last)) && new.head == move.seq)
            #expect(first.scopes.reduce(0) { $0 + $1.items.count } == 200)
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            #expect(try second.scope(personal.key).items.isEmpty)
            let final = try second.scope(shared.key)
            #expect(final.items == [.upsert(seq: move.seq, prompt: .init(id: id, rev: 2, path: "Moved.md", content: destination.content))])
            #expect(final.cursor == String(move.seq) && second.scopes.allSatisfy { !$0.hasMore })
        }
    }
}
