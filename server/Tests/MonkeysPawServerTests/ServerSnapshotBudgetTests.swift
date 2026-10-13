import Foundation
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSnapshotBudgetTests {
    @Test func twoSnapshotsShareTwoHundredItemsAcrossAllTheirPages() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id), shared = PromptOwnership.group(groupID: group.id)
            let privatePrompts = try await fixture.seedSnapshot(identity: personal, author: user, count: 201)
            let groupPrompts = try await fixture.seedSnapshot(identity: shared, author: user, count: 201, startingID: 1_000)
            var request = SyncAPI.PullRequest(databaseID: nil, cursors: [:])
            var collected: [String: [SyncAPI.FeedItem]] = [:]
            for turn in 0..<3 {
                let response = try await fixture.feed.pull(request: request, session: session.identity)
                #expect(response.scopes.reduce(0) { $0 + $1.items.count } == (turn == 2 ? 2 : 200))
                for page in response.scopes {
                    #expect(page.items.count == (turn == 2 ? 1 : 100))
                    #expect(page.mode == .snapshot && page.hasMore == (turn < 2))
                    #expect(page.cursor.hasPrefix("snap:") == (turn < 2))
                    #expect(page.items.allSatisfy { $0.seq == page.head })
                    collected[page.identity.key, default: []] += page.items
                }
                request = response.continuation
            }
            #expect(collected[personal.key] == privatePrompts.map { .upsert(seq: 201, prompt: $0) })
            #expect(collected[shared.key] == groupPrompts.map { .upsert(seq: 402, prompt: $0) })
        }
    }

    @Test(arguments: [false, true], [SyncAPI.Mode.snapshot, .delta])
    func snapshotsAndDeltasShareTheExactSerializedHTTPBudget(escaped: Bool, groupMode: SyncAPI.Mode) async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id), shared = PromptOwnership.group(groupID: group.id)
            let count = escaped ? 12 : 20
            let content = String(repeating: escaped ? "\u{01}" : "x", count: Limits.maxPromptBytes)
            _ = try await fixture.service.rename(id: group.id, request: .init(name: String(repeating: "\"\\/\t", count: 60)), session: session.identity)
            _ = try await fixture.seedSnapshot(identity: personal, author: user, count: count, content: content)
            var cursors: [String: String] = [:]
            if groupMode == .snapshot {
                _ = try await fixture.seedSnapshot(identity: shared, author: user, count: count, startingID: 1_000, content: content)
            } else {
                cursors[shared.key] = String(try #require(await fixture.seedFeed(identity: shared, count: 1).last))
                _ = try await fixture.seedFeed(identity: shared, count: count, startingID: 1_000, content: content)
            }
            let removed = Dictionary(uniqueKeysWithValues: (0..<100).map { ("group:\(feedTestID(100_000 + $0))", "1") })
            cursors.merge(removed) { _, new in new }
            let databaseID = try await MetaRepository(database: fixture.persistence.database).databaseID().uuidString.lowercased()
            let request = SyncAPI.PullRequest(databaseID: databaseID, cursors: cursors)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) {
                    let response = try PromptHTTPTest.success($0, as: SyncAPI.PullResponse.self)
                    #expect($0.body.readableBytes <= ServerLimits.syncPageBytes && $0.body.readableBytes <= SyncAPI.responseEnvelopeMaxBytes)
                    #expect(response.scopes.reduce(0) { $0 + $1.items.count } == (escaped ? 5 : 31))
                    #expect(response.scopes.allSatisfy { $0.hasMore })
                    #expect(response.removed == removed.keys.sorted())
                    #expect(try response.scope(personal.key).mode == .snapshot)
                    #expect(try response.scope(shared.key).mode == groupMode)
                }
            }
            var next = request
            var collected: [String: [String]] = [:]
            var finished = false
            for _ in 0..<10 {
                let response = try await fixture.feed.pull(request: next, session: session.identity)
                #expect(try JSONEncoder().encode(response).count <= ServerLimits.syncPageBytes)
                #expect(response.scopes.reduce(0) { $0 + $1.items.count } <= ServerLimits.syncPageMaxItems)
                #expect(!response.scopes.flatMap(\.items).isEmpty)
                for page in response.scopes {
                    for item in page.items {
                        guard case .upsert(_, let prompt) = item else { Issue.record("Expected an upsert"); continue }
                        #expect(prompt.content == content)
                        if page.mode == .snapshot { #expect(item.seq == page.head) }
                        collected[page.identity.key, default: []].append(prompt.id)
                    }
                }
                next = response.continuation
                if !response.scopes.contains(where: { $0.hasMore }) { finished = true; break }
            }
            #expect(finished)
            #expect(collected[personal.key] == (1...count).map(feedTestID))
            #expect(collected[shared.key] == (1_000..<(1_000 + count)).map(feedTestID))
        }
    }

    @Test func oversizedManifestsFailAtomicallyRatherThanFreezePartialScopes() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let content = String(repeating: "\u{01}", count: Limits.maxPromptBytes)
            _ = try await fixture.seedSnapshot(identity: .user(ownerID: user.id), author: user, count: 43, content: content)
            await #expect(throws: SyncFeedError.snapshotTooLarge) {
                _ = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            }
            #expect(try await fixture.persistence.count("snapshots") == 0)
            #expect(try await fixture.persistence.count("prompts") == 43)
        }
    }

    @Test func storageEvictsOldestManifestsAndTheirContinuationsExpire() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let key = "user:\(user.id)"
            _ = try await fixture.seedSnapshot(identity: .user(ownerID: user.id), author: user, count: 201)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            fixture.account.clock.advance(1)
            let created = ServerTimestamp.string(fixture.account.clock.now())
            let expires = ServerTimestamp.string(fixture.account.clock.now().addingTimeInterval(TimeInterval(ServerLimits.snapshotLifetimeSeconds)))
            try await fixture.persistence.database.write { sql in
                let row = try #require(await sql.raw("SELECT length(manifest) AS bytes FROM snapshots").first())
                let existing = try row.decode(column: "bytes", as: Int.self)
                for head in 1...4 {
                    let bytes = ServerLimits.snapshotMaxBytes - (head == 4 ? existing : 0)
                    try await sql.raw("""
                        INSERT INTO snapshots (database_id, scope_key, head_seq, manifest, created_at, expires_at)
                        VALUES (\(bind: first.databaseID.uppercased()), \(bind: key), \(bind: head), zeroblob(\(bind: bytes)),
                                \(bind: created), \(bind: expires))
                        """).run()
                }
            }
            _ = try await fixture.writePrompt(id: feedTestID(1), baseRev: 1, path: "1.md",
                                              content: snapshotContent(id: feedTestID(1), body: "Changed\n"), session: session.identity)
            let restarted = try await fixture.feed.pull(request: .init(databaseID: first.databaseID, cursors: [:]), session: session.identity)
            #expect(restarted.scopes[0].head == 202 && restarted.scopes[0].hasMore)
            await #expect(throws: PromptError(.snapshotExpired(scopes: [key]))) {
                _ = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            }
            let stored = try await fixture.persistence.database.read { sql in
                let row = try #require(await sql.raw("SELECT SUM(length(manifest)) AS bytes FROM snapshots").first())
                return try row.decode(column: "bytes", as: Int.self)
            }
            #expect(stored <= ServerLimits.snapshotTotalMaxBytes)
        }
    }
}
