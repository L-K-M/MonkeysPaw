import Foundation
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedMetadataTests {
    @Test func metadataThatFitsButExcludesTheFirstItemFailsInsteadOfContinuingEmpty() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: personal, count: 1).last)
            let name = String(repeating: "\u{01}", count: 255)
            let groups = (1...4_200).map {
                SyncAPI.Group(id: feedTestID(10_000 + $0), name: name, createdBy: user.id, createdAt: user.createdAt)
            }
            let groupCursors = try await fixture.persistence.database.write { sql in
                let repository = GroupRepository.Transaction(sql: sql)
                var cursors: [String: Int64] = [:]
                for group in groups {
                    try await repository.insert(group)
                    try await repository.upsertMember(groupID: group.id, userID: user.id, role: .owner, at: user.createdAt)
                    let key = "group:\(group.id)"
                    let row = try #require(await sql.raw(PersistenceTestRepository.change(scope: "group", owner: nil,
                        group: group.id, key: key) + " RETURNING seq").first())
                    cursors[key] = try row.decode(column: "seq", as: Int64.self)
                }
                return cursors
            }
            let content = String(repeating: "\u{01}", count: Limits.maxPromptBytes)
            let seq = try #require(await fixture.seedFeed(identity: personal, count: 1, startingID: 100, content: content).last)
            let request = try await fixture.feedRequest(cursors: groupCursors.merging([personal.key: baseline]) { _, new in new })
            let scopes: [SyncAPI.SyncScope] = [.init(identity: .user(userID: user.id), mode: .delta, head: seq,
                cursor: String(seq), hasMore: false, items: [])] + (try groups.map {
                let head = try #require(groupCursors["group:\($0.id)"])
                return .init(identity: .group(groupID: $0.id, name: name, role: .owner), mode: .delta,
                             head: head, cursor: String(head), hasMore: false, items: [])
            })
            let encoder = JSONEncoder()
            let metadataBytes = try encoder.encode(SyncAPI.PullResponse(databaseID: try #require(request.databaseID), scopes: scopes, removed: [])).count
            let item = SyncAPI.FeedItem.upsert(seq: seq, prompt: .init(id: feedTestID(100), rev: 1, path: "100.md", content: content))
            // Metadata itself fits. Its escaped group names leave insufficient room for one valid item.
            #expect(metadataBytes < ServerLimits.syncPageBytes)
            #expect(metadataBytes + (try encoder.encode(item).count) > ServerLimits.syncPageBytes)
            #expect(try encoder.encode(request).count < SyncAPI.requestEnvelopeMaxBytes)
            await #expect(throws: SyncFeedError.responseTooLarge) {
                _ = try await fixture.feed.pull(request: request, session: session.identity)
            }
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                    body: .init(bytes: encoder.encode(request))) {
                    try PromptHTTPTest.error($0, .failure(.internalError))
                    #expect(String(buffer: $0.body) == "{\"code\":\"internal_error\"}")
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func deltaReservesExpandedHeadCursorAndCompletionFalseBeforeAdmittingItems(wideHead: Bool) async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            // The false-only case keeps every cursor at three digits, isolating the boolean's one byte.
            if !wideHead {
                try await fixture.persistence.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('changes', 99)")
            }
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            if wideHead {
                try await fixture.persistence.execute("UPDATE sqlite_sequence SET seq = 999999999999999999 WHERE name = 'changes'")
            }
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let databaseID = try #require(request.databaseID)
            let head = wideHead ? Int64(1_000_000_000_000_000_031) : baseline + 32
            let full = String(repeating: "x", count: Limits.maxPromptBytes)
            var contents = Array(repeating: full, count: 31) + [""]
            func candidate(cursor: String, hasMore: Bool) -> SyncAPI.PullResponse {
                let items = contents.enumerated().map { index, content in
                    SyncAPI.FeedItem.upsert(seq: head - 31 + Int64(index),
                        prompt: .init(id: feedTestID(index + 100), rev: 1, path: "\(index + 100).md", content: content))
                }
                return .init(databaseID: databaseID, scopes: [.init(identity: .user(userID: user.id), mode: .delta,
                    head: head, cursor: cursor, hasMore: hasMore, items: items)], removed: [])
            }
            let encoder = JSONEncoder()
            let padding = ServerLimits.syncPageBytes + 1 - (try encoder.encode(candidate(cursor: String(head), hasMore: false)).count)
            try #require((1...Limits.maxPromptBytes).contains(padding))
            contents[31] = String(repeating: "x", count: padding)
            #expect(try encoder.encode(candidate(cursor: String(head), hasMore: false)).count == ServerLimits.syncPageBytes + 1)
            let unreserved = candidate(cursor: wideHead ? String(baseline) : String(head), hasMore: !wideHead)
            #expect(try encoder.encode(unreserved).count <= ServerLimits.syncPageBytes)
            let sequences = try await fixture.seedFeed(identity: identity, changes: contents.enumerated().map {
                .init(id: feedTestID($0.offset + 100), path: "\($0.offset + 100).md", content: $0.element)
            })
            try #require(sequences.last == head)
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            let page = try first.scope(identity.key)
            #expect(page.items.map(\.seq) == Array(sequences.prefix(31)))
            #expect(page.cursor == String(sequences[30]) && page.head == head && page.hasMore)
            #expect(try encoder.encode(first).count <= ServerLimits.syncPageBytes)
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            let last = try second.scope(identity.key)
            let itemIsUnconsumed = last.items == [.upsert(seq: head, prompt: .init(id: feedTestID(131), rev: 1, path: "131.md", content: contents[31]))]
            #expect(itemIsUnconsumed)
            #expect(last.cursor == String(head) && !last.hasMore)
            #expect(try encoder.encode(second).count <= ServerLimits.syncPageBytes)
        }
    }

    @Test func snapshotReservesTheWidestContinuationBeforeAdmittingItems() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let key = "user:\(user.id)"
            let databaseID = try await MetaRepository(database: fixture.persistence.database).databaseID().uuidString.lowercased()
            let signingKey = try await fixture.feedRepository.read { feed, _, _ in try await feed.snapshots.signingKey() }
            let generation = UUID().uuidString.lowercased()
            let full = String(repeating: "x", count: Limits.maxPromptBytes)
            var prompts = (1...100).map {
                SyncAPI.FeedPrompt(id: feedTestID($0), rev: 1, path: "\($0).md", content: $0 <= 31 ? full : "")
            }
            func candidate(position: Int, hasMore: Bool) -> SyncAPI.PullResponse {
                let cursor = SnapshotCursor(databaseID: databaseID, scopeKey: key, head: 100, generation: generation, position: position).value(using: signingKey)
                return .init(databaseID: databaseID, scopes: [.init(identity: .user(userID: user.id), mode: .snapshot, head: 100,
                    cursor: cursor, hasMore: hasMore, items: prompts.prefix(32).map { .upsert(seq: 100, prompt: $0) })], removed: [])
            }
            let encoder = JSONEncoder()
            // Position 100 is complete, so 99 is the widest valid unfinished continuation.
            let padding = ServerLimits.syncPageBytes + 1 - (try encoder.encode(candidate(position: 99, hasMore: false)).count)
            try #require((1...Limits.maxPromptBytes).contains(padding))
            prompts[31] = .init(id: prompts[31].id, rev: 1, path: prompts[31].path, content: String(repeating: "x", count: padding))
            #expect(try encoder.encode(candidate(position: 99, hasMore: false)).count == ServerLimits.syncPageBytes + 1)
            #expect(try encoder.encode(candidate(position: 0, hasMore: false)).count == ServerLimits.syncPageBytes)
            #expect(try encoder.encode(candidate(position: 32, hasMore: true)).count == ServerLimits.syncPageBytes)
            let frozenPrompts = prompts
            try await fixture.promptRepository.write { repository, _, _, _ in
                for prompt in frozenPrompts.reversed() {
                    let record = PromptRecord(id: prompt.id, identity: .user(ownerID: user.id), path: prompt.path, pathKey: prompt.path,
                        content: prompt.content, title: "Fixture", rev: 1, createdBy: user.id, createdAt: user.createdAt,
                        updatedBy: user.id, updatedAt: user.createdAt, deletedAt: nil)
                    try await repository.insert(record)
                    try await repository.appendRevision(record, origin: .edit)
                    _ = try await repository.appendUpsert(record)
                }
            }
            // A cached manifest lets the independently encoded boundary use its actual generation.
            let manifest = try encoder.encode(FrozenSnapshot(generation: generation, prompts: frozenPrompts))
            let now = fixture.account.clock.now()
            try await fixture.persistence.execute("""
                INSERT INTO snapshots (database_id, scope_key, head_seq, manifest, created_at, expires_at)
                VALUES (\(bind: databaseID.uppercased()), \(bind: key), 100, \(bind: manifest), \(bind: ServerTimestamp.string(now)),
                        \(bind: ServerTimestamp.string(now.addingTimeInterval(600))))
                """)
            let first = try await fixture.feed.pull(request: .init(databaseID: databaseID, cursors: [:]), session: session.identity)
            let page = try first.scope(key)
            let firstItemsMatch = page.items == frozenPrompts.prefix(31).map { .upsert(seq: 100, prompt: $0) }
            #expect(firstItemsMatch)
            let continuation = try SnapshotCursor(page.cursor)
            #expect(page.hasMore && continuation.position == 31)
            #expect(try encoder.encode(first).count <= ServerLimits.syncPageBytes)
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            let last = try second.scope(key)
            let remainingItemsMatch = last.items == frozenPrompts.dropFirst(31).map { .upsert(seq: 100, prompt: $0) }
            #expect(remainingItemsMatch)
            #expect(last.cursor == "100" && !last.hasMore)
            #expect(try encoder.encode(second).count <= ServerLimits.syncPageBytes)
        }
    }
}
