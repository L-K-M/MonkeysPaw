import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSnapshotMutationTests {
    @Test func editsDeletesRenamesAndMovesCannotChangeFrozenPagesAndLaterArriveAsDeltas() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("owner")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let shared = PromptOwnership.group(groupID: group.id)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            let prompts = try await fixture.seedSnapshot(identity: shared, author: user, count: 205)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            let page = try first.scope(shared.key)
            #expect(page.items.count == 200 && page.hasMore)
            let edited = try await fixture.writePrompt(id: prompts[200].id, baseRev: 1, scope: scope, path: prompts[200].path,
                                                       content: snapshotContent(id: prompts[200].id, body: "Edited after freezing\n"), session: session.identity)
            let deleted = try await fixture.prompts.delete(id: prompts[201].id, query: .init(baseRev: 1), session: session.identity)
            let moved = try await fixture.prompts.move(id: prompts[202].id, request: .init(baseRev: 1, scope: .user, path: "Mine.md"),
                                                       session: session.identity)
            _ = try await fixture.writePrompt(id: prompts[202].id, baseRev: 2, path: "Mine.md",
                                              content: snapshotContent(id: prompts[202].id, body: "Private bytes after move\n"), session: session.identity)
            let renamed = try await fixture.writePrompt(id: prompts[203].id, baseRev: 1, scope: scope, path: "Renamed.md",
                                                        content: snapshotContent(id: prompts[203].id), session: session.identity)
            let inserted = try await fixture.writePrompt(id: feedTestID(206), scope: scope, path: "New.md",
                                                         content: snapshotContent(id: feedTestID(206)), session: session.identity)
            let incomingID = feedTestID(999)
            _ = try await fixture.writePrompt(id: incomingID, path: "Incoming.md", content: snapshotContent(id: incomingID), session: session.identity)
            let incoming = try await fixture.prompts.move(id: incomingID, request: .init(baseRev: 1, scope: scope, path: "Incoming.md"),
                                                          session: session.identity)
            try await fixture.persistence.execute("DELETE FROM prompt_revisions")
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            let final = try second.scope(shared.key)
            #expect(final.mode == .snapshot && final.head == page.head && final.cursor == String(page.head) && !final.hasMore)
            #expect(page.items + final.items == prompts.map { .upsert(seq: page.head, prompt: $0) })
            #expect(!String(decoding: try JSONEncoder().encode(final), as: UTF8.self).contains("Private bytes after move"))
            let delta = try await fixture.feed.pull(request: second.continuation, session: session.identity).scope(shared.key)
            let expectedSequences = [edited.seq, deleted.seq, moved.seq - 1, renamed.seq, inserted.seq, incoming.seq]
            let expected = try await fixture.feedRepository.read { feed, _, _ in
                var items: [SyncAPI.FeedItem] = []
                for seq in expectedSequences { items.append(try await feed.item(key: shared.key, seq: seq)) }
                return items
            }
            #expect(delta.mode == .delta && delta.items == expected && !delta.hasMore)
            #expect(delta.head == incoming.seq && delta.cursor == String(incoming.seq))
            #expect(delta.items.contains(.delete(seq: deleted.seq, id: prompts[201].id)))
            #expect(delta.items.contains(.moveOut(seq: moved.seq - 1, id: prompts[202].id)))
        }
    }

    @Test(arguments: ["remove", "delete", "disable", "revoke", "rename_role"])
    func everyPageReauthorizesTheSessionAndCurrentMembership(change: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader", kind: .admin)
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: reader, role: .viewer)
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(reader)
            let shared = PromptOwnership.group(groupID: group.id)
            let prompts = try await fixture.seedSnapshot(identity: shared, author: owner, count: 201)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            let request = first.continuation
            switch change {
            case "remove": try await fixture.service.removeMember(id: group.id, userID: reader.id, session: ownerSession.identity)
            case "delete": try await fixture.service.delete(id: group.id, session: ownerSession.identity)
            case "disable": try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: reader.id)")
            case "revoke": try await fixture.account.sessions.logout(session.identity)
            default:
                _ = try await fixture.service.rename(id: group.id, request: .init(name: "Renamed"), session: ownerSession.identity)
                _ = try await fixture.service.upsertMember(id: group.id, userID: reader.id, request: .init(role: .editor), session: ownerSession.identity)
            }
            if change == "disable" || change == "revoke" {
                await #expect(throws: AccountError.unauthorized) { _ = try await fixture.feed.pull(request: request, session: session.identity) }
                return
            }
            let response = try await fixture.feed.pull(request: request, session: session.identity)
            if change == "rename_role" {
                let page = try response.scope(shared.key)
                #expect(page.identity == .group(groupID: group.id, name: "Renamed", role: .editor))
                #expect(page.items == [.upsert(seq: first.scopes[1].head, prompt: prompts[200])])
            } else {
                #expect(response.scopes.count == 1 && response.removed == [shared.key])
                #expect(response.scopes[0].items.isEmpty)
                // Even an expired, now-inaccessible continuation reveals no manifest state.
                fixture.account.clock.advance(TimeInterval(ServerLimits.snapshotLifetimeSeconds))
                #expect(try await fixture.feed.pull(request: request, session: session.identity).removed == [shared.key])
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func initialSnapshotsRespectScopeAccessAndStoredCanonicalBytes(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: reader, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(reader)
            let content = promptContent(metadata: "favorite: true\nprivate: false\n", body: "Shared body\n")
            _ = try await fixture.writePrompt(scope: .group(groupID: group.id), content: content, session: ownerSession.identity)
            let stored = try await fixture.prompts.get(id: GroupTestFixture.livePrompt, session: ownerSession.identity)
            let privateID = feedTestID(10)
            let privateContent = snapshotContent(id: privateID, metadata: "favorite: true\nprivate: false\n", body: "Private body\n")
            _ = try await fixture.writePrompt(id: privateID, content: privateContent, session: session.identity)
            let privateKey = "user:\(reader.id)", groupKey = "group:\(group.id)", hidden = "user:\(owner.id)"
            let request = SyncAPI.PullRequest(databaseID: nil, cursors: [hidden: "0", groupKey: "0"])
            let response = try await fixture.feed.pull(request: request, session: session.identity)
            let personal = try response.scope(privateKey)
            #expect(personal.items == [.upsert(seq: personal.head, prompt: .init(id: privateID, rev: 1, path: "Example.md", content: privateContent))])
            if role == .nonMember {
                #expect(response.scopes.count == 1 && response.removed == [groupKey, hidden].sorted())
            } else {
                let shared = try response.scope(groupKey)
                #expect(shared.mode == .snapshot && !shared.hasMore && response.removed == [hidden])
                #expect(shared.items == [.upsert(seq: shared.head, prompt: .init(id: stored.id, rev: stored.rev, path: stored.path, content: stored.content))])
                #expect(!stored.content.contains("favorite:") && !stored.content.contains("private:"))
            }
        }
    }
}
