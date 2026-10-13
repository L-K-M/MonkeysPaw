import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSnapshotLifecycleTests {
    @Test func expiryIsBoundedAndRestartedManifestsCannotSpliceOldPages() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let key = "user:\(user.id)"
            _ = try await fixture.seedSnapshot(identity: .user(ownerID: user.id), author: user, count: 201)
            let initial = SyncAPI.PullRequest(databaseID: nil, cursors: [:])
            let first = try await fixture.feed.pull(request: initial, session: session.identity)
            #expect(first == (try await fixture.feed.pull(request: initial, session: session.identity)))
            fixture.account.clock.advance(TimeInterval(ServerLimits.snapshotLifetimeSeconds - 1))
            let final = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            #expect(!final.scopes[0].hasMore)
            fixture.account.clock.advance(1)
            await #expect(throws: PromptError(.snapshotExpired(scopes: [key]))) {
                _ = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            }
            let restarted = try await fixture.feed.pull(request: initial, session: session.identity)
            #expect(restarted.scopes[0].head == first.scopes[0].head && restarted.scopes[0].items == first.scopes[0].items)
            #expect(restarted.scopes[0].cursor != first.scopes[0].cursor)
            #expect(try await fixture.persistence.count("snapshots") == 1)
            await #expect(throws: PromptError(.snapshotExpired(scopes: [key]))) {
                _ = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            }
        }
    }

    @Test func malformedAlteredForeignAndOutOfRangeCursorsAreRejected() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let key = "user:\(user.id)"
            _ = try await fixture.seedSnapshot(identity: .user(ownerID: user.id), author: user, count: 201)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            let cursor = first.scopes[0].cursor
            let parts = cursor.split(separator: ":").map(String.init)
            var invalid = ["snap:opaque", "snap:", cursor + ":extra"]
            for (index, value) in [(1, "2"), (2, parts[2].uppercased()), (3, "private"), (4, "bad-id"),
                                   (5, "0201"), (5, "0"), (5, "9223372036854775808"), (6, "bad-id"),
                                   (7, "0200"), (7, "-1"), (7, "9223372036854775808"),
                                   (8, String(repeating: "0", count: 64)), (8, String(repeating: "x", count: 64))] {
                var modified = parts
                modified[index] = value
                invalid.append(modified.joined(separator: ":"))
            }
            // Syntactically valid tampering still fails authentication.
            for index in [5, 7] {
                var modified = parts
                modified[index] = "1"
                invalid.append(modified.joined(separator: ":"))
            }
            for value in invalid {
                let request = SyncAPI.PullRequest(databaseID: first.databaseID, cursors: [key: value])
                await #expect(throws: AccountError.malformedRequest) { _ = try await fixture.feed.pull(request: request, session: session.identity) }
            }
            let foreign = SyncAPI.PullRequest(databaseID: first.databaseID, cursors: ["group:\(PersistenceTestRepository.group)": cursor])
            await #expect(throws: AccountError.malformedRequest) { _ = try await fixture.feed.pull(request: foreign, session: session.identity) }
            let wrongDatabase = SyncAPI.PullRequest(databaseID: UUID().uuidString.lowercased(), cursors: [key: cursor])
            await #expect(throws: AccountError.malformedRequest) { _ = try await fixture.feed.pull(request: wrongDatabase, session: session.identity) }
            let signingKey = try await fixture.feedRepository.read { feed, _, _ in try await feed.snapshots.signingKey() }
            let parsed = try SnapshotCursor(cursor)
            let outOfRange = SnapshotCursor(databaseID: first.databaseID, scopeKey: key, head: parsed.head,
                                            generation: parsed.generation, position: 201).value(using: signingKey)
            await #expect(throws: AccountError.malformedRequest) {
                _ = try await fixture.feed.pull(request: .init(databaseID: first.databaseID, cursors: [key: outOfRange]), session: session.identity)
            }
        }
    }

    @Test func allAccessibleExpiredScopesAreReportedTogetherAndUUIDRotationExpiresContinuations() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id), shared = PromptOwnership.group(groupID: group.id)
            _ = try await fixture.seedSnapshot(identity: personal, author: user, count: 201)
            _ = try await fixture.seedSnapshot(identity: shared, author: user, count: 201, startingID: 1_000)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            #expect(first.scopes.allSatisfy { $0.hasMore })
            fixture.account.clock.advance(TimeInterval(ServerLimits.snapshotLifetimeSeconds))
            let expected = PromptError(.snapshotExpired(scopes: [personal.key, shared.key].sorted()))
            await #expect(throws: expected) { _ = try await fixture.feed.pull(request: first.continuation, session: session.identity) }
            let restarted = try await fixture.feed.pull(request: .init(databaseID: first.databaseID, cursors: [:]), session: session.identity)
            let newID = UUID().uuidString
            try await fixture.persistence.database.write { sql in
                try await sql.raw("DELETE FROM snapshots").run()
                try await sql.raw("UPDATE meta SET database_id = \(bind: newID)").run()
            }
            await #expect(throws: expected) { _ = try await fixture.feed.pull(request: restarted.continuation, session: session.identity) }
            let recovered = try await fixture.feed.pull(request: .init(databaseID: restarted.databaseID, cursors: [:]), session: session.identity)
            #expect(recovered.databaseID == newID.lowercased() && recovered.scopes.allSatisfy { $0.mode == .snapshot })
        }
    }

    @Test func failedMaterializationRollsBackAllManifestsAndEmptyScopeInitialization() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            _ = try await fixture.seedSnapshot(identity: .group(groupID: group.id), author: user, count: 201)
            try await fixture.persistence.execute("""
                CREATE TRIGGER fail_snapshot BEFORE INSERT ON snapshots WHEN NEW.scope_key LIKE 'group:%'
                BEGIN SELECT RAISE(ABORT, 'Injected snapshot failure'); END
                """)
            let request = SyncAPI.PullRequest(databaseID: nil, cursors: [:])
            await #expect(throws: (any Error).self) { _ = try await fixture.feed.pull(request: request, session: session.identity) }
            #expect(try await fixture.persistence.count("snapshots") == 0)
            #expect(try await fixture.persistence.count("scope_heads") == 1)
            try await fixture.persistence.execute("DROP TRIGGER fail_snapshot")
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            #expect(first.scopes[1].hasMore)
            #expect(try await fixture.persistence.count("snapshots") == 2)
        }
    }
}
