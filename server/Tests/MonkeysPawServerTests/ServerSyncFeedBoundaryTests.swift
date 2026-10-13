import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedBoundaryTests {
    @Test func missingZeroForeignDatabaseAndAboveHeadCursorsSelectSnapshots() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let initial = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            #expect(initial.scopes[0].mode == .snapshot && initial.scopes[0].cursor == "0")
            let head = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let current = try await fixture.feedRequest(cursors: [identity.key: head])
            let cases: [SyncAPI.PullRequest] = [
                .init(databaseID: nil, cursors: current.cursors),
                .init(databaseID: UUID().uuidString.lowercased(), cursors: current.cursors),
                .init(databaseID: current.databaseID, cursors: [:]),
                .init(databaseID: current.databaseID, cursors: [identity.key: "0"]),
                .init(databaseID: current.databaseID, cursors: [identity.key: String(head + 1)]),
                .init(databaseID: current.databaseID, cursors: [identity.key: String(Int64.max)])
            ]
            for request in cases {
                let response = try await fixture.feed.pull(request: request, session: session.identity)
                #expect(response.scopes[0].mode == .snapshot && response.scopes[0].head == head)
                #expect(response.scopes[0].cursor == String(head) && !response.scopes[0].hasMore)
            }
            #expect(try await fixture.feed.pull(request: current, session: session.identity).scopes[0].mode == .delta)
            let foreign = "group:\(PersistenceTestRepository.group)"
            let removed = SyncAPI.PullRequest(databaseID: current.databaseID, cursors: current.cursors.merging([foreign: "1"]) { _, new in new })
            #expect(try await fixture.feed.pull(request: removed, session: session.identity).removed == [foreign])
        }
    }

    @Test func cursorAtThePurgedBoundaryIsCurrentAndEmptyScopesKeepDurableHeads() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let seqs = try await fixture.seedFeed(identity: identity, count: 3)
            try await fixture.persistence.database.write { sql in
                try await sql.raw("DELETE FROM changes WHERE scope_key = \(bind: identity.key) AND seq <= \(bind: seqs[1])").run()
                try await sql.raw("INSERT INTO scope_floors VALUES (\(bind: identity.key), \(bind: seqs[1] + 1))").run()
            }
            let stale = try await fixture.feedRequest(cursors: [identity.key: seqs[0]])
            #expect(try await fixture.feed.pull(request: stale, session: session.identity).scopes[0].mode == .snapshot)
            let boundary = try await fixture.feedRequest(cursors: [identity.key: seqs[1]])
            let response = try await fixture.feed.pull(request: boundary, session: session.identity)
            #expect(response.scopes[0].items.map(\.seq) == [seqs[2]] && response.scopes[0].cursor == String(seqs[2]))
            try await fixture.persistence.database.write { sql in
                try await sql.raw("DELETE FROM changes WHERE scope_key = \(bind: identity.key)").run()
                try await sql.raw("UPDATE scope_floors SET floor_seq = \(bind: seqs[2] + 1) WHERE scope_key = \(bind: identity.key)").run()
            }
            let empty = try await fixture.feed.pull(request: response.continuation, session: session.identity).scope(identity.key)
            #expect(empty.head == seqs[2] && empty.cursor == String(seqs[2]) && empty.items.isEmpty && !empty.hasMore)
            let snapshot = try await fixture.feed.pull(request: boundary, session: session.identity)
            #expect(snapshot.scopes[0].mode == .snapshot && snapshot.scopes[0].head == seqs[2])
            let completed = try await fixture.feed.pull(request: snapshot.continuation, session: session.identity)
            #expect(completed.scopes[0].mode == .delta && completed.scopes[0].items.isEmpty)
        }
    }

    @Test(arguments: ["disable", "revoke", "wrong_user", "wrong_device"])
    func serviceRechecksTheSessionAfterBearerAuthentication(change: String) async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let authenticated = try await fixture.account.sessions.authenticate(token: session.token.value)
            let identity = PromptOwnership.user(ownerID: user.id)
            let head = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let request = try await fixture.feedRequest(cursors: [identity.key: head])
            let caller: SessionIdentity
            switch change {
            case "disable":
                try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: user.id)")
                caller = authenticated
            case "revoke":
                try await fixture.account.sessions.logout(authenticated)
                caller = authenticated
            case "wrong_user": caller = .init(userID: feedTestID(99), deviceID: authenticated.deviceID)
            default: caller = .init(userID: user.id, deviceID: feedTestID(99))
            }
            await #expect(throws: AccountError.unauthorized) { _ = try await fixture.feed.pull(request: request, session: caller) }
        }
    }
}
