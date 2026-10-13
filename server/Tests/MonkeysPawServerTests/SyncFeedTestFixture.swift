import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

struct FeedTestChange: Sendable {
    var id = PersistenceTestRepository.prompt
    var path = "Example.md"
    var rev: Int64 = 1
    var kind = "upsert"
    var content: String? = "Event payload"
}

func feedTestID(_ index: Int) -> String { String(format: "%026d", index) }

extension GroupTestFixture {
    var feed: SyncFeedService { .init(database: persistence.database) }
    var feedRepository: SyncFeedRepository { .init(database: persistence.database) }

    /// Seed immutable feed rows without heads/revisions, proving the feed does not need either.
    func seedFeed(identity: PromptOwnership, changes: [FeedTestChange]) async throws -> [Int64] {
        try await persistence.database.write { sql in
            var sequences: [Int64] = []
            for change in changes {
                let row = try #require(await sql.raw("""
                    INSERT INTO changes (scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at)
                    VALUES (\(bind: identity.key), \(bind: identity.scopeName), \(bind: identity.ownerID), \(bind: identity.groupID),
                            \(bind: change.id), \(bind: change.kind), \(bind: change.path), \(bind: change.rev),
                            \(bind: change.content), \(bind: PersistenceTestRepository.time)) RETURNING seq
                    """).first())
                sequences.append(try row.decode(column: "seq", as: Int64.self))
            }
            return sequences
        }
    }

    func seedFeed(identity: PromptOwnership, count: Int, startingID: Int = 1, content: String = "Event payload") async throws -> [Int64] {
        try await seedFeed(identity: identity, changes: (startingID..<(startingID + count)).map {
            .init(id: feedTestID($0), path: "\($0).md", content: content)
        })
    }

    func feedRequest(cursors: [String: Int64]) async throws -> SyncAPI.PullRequest {
        let id = try await MetaRepository(database: persistence.database).databaseID().uuidString.lowercased()
        return .init(databaseID: id, cursors: cursors.mapValues(String.init))
    }
}

extension SyncAPI.PullResponse {
    var continuation: SyncAPI.PullRequest {
        .init(databaseID: databaseID, cursors: Dictionary(uniqueKeysWithValues: scopes.map { ($0.identity.key, $0.cursor) }))
    }

    func scope(_ key: String) throws -> SyncAPI.SyncScope { try #require(scopes.first { $0.identity.key == key }) }
}
