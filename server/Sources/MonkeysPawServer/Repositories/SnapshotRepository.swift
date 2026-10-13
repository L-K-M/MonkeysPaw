import Crypto
import Foundation
import MonkeysPawCore
import SQLKit

struct SnapshotID: Hashable, Sendable {
    let databaseID: String
    let scopeKey: String
    let head: Int64
}

struct FrozenSnapshot: Codable, Sendable {
    let generation: String
    let prompts: [SyncAPI.FeedPrompt]
}

/// Uses the feed's transaction; creation never reads live prompts outside it.
struct SnapshotRepository: Sendable {
    private let sql: any SQLDatabase

    init(sql: any SQLDatabase) { self.sql = sql }

    func signingKey() async throws -> SymmetricKey {
        guard let row = try await sql.raw("SELECT secret FROM snapshot_cursor_key WHERE singleton = 1").first() else {
            throw SyncFeedPersistenceError.invalidRecord
        }
        return try SymmetricKey(data: row.decode(column: "secret", as: Data.self))
    }

    func snapshot(_ id: SnapshotID, now: Date) async throws -> FrozenSnapshot? {
        guard let row = try await sql.raw("""
            SELECT manifest FROM snapshots WHERE database_id = \(bind: id.databaseID.uppercased())
                AND scope_key = \(bind: id.scopeKey) AND head_seq = \(bind: id.head)
                AND expires_at > \(bind: ServerTimestamp.string(now))
            """).first() else { return nil }
        return try JSONDecoder().decode(FrozenSnapshot.self, from: row.decode(column: "manifest", as: Data.self))
    }

    func materialize(_ id: SnapshotID, identity: SyncAPI.ScopeIdentity, now: Date,
                     protecting protected: Set<SnapshotID>) async throws -> FrozenSnapshot {
        let encoder = JSONEncoder()
        let generation = UUID().uuidString.lowercased()
        var bytes = try encoder.encode(FrozenSnapshot(generation: generation, prompts: [])).count
        var prompts: [SyncAPI.FeedPrompt] = []
        var after = ""
        while true {
            let batch = try await livePrompts(identity: identity, after: after)
            if batch.isEmpty { break }
            for prompt in batch {
                bytes += try encoder.encode(prompt).count + (prompts.isEmpty ? 0 : 1)
                guard bytes <= ServerLimits.snapshotMaxBytes else { throw SyncFeedError.snapshotTooLarge }
                prompts.append(prompt)
                after = prompt.id
            }
        }
        guard id.head > 0 || prompts.isEmpty else { throw SyncFeedPersistenceError.invalidRecord }
        let snapshot = FrozenSnapshot(generation: generation, prompts: prompts)
        let manifest = try encoder.encode(snapshot)
        guard manifest.count <= ServerLimits.snapshotMaxBytes else { throw SyncFeedError.snapshotTooLarge }
        assert(manifest.count == bytes, "Snapshot JSON exceeded its serialized byte reservation")
        try await makeRoom(bytes: manifest.count, now: now, protecting: protected)
        // Empty scopes need a durable zero head before the snapshot's FK can name it.
        try await sql.raw("""
            INSERT INTO scope_heads (scope_key, head_seq)
            SELECT \(bind: id.scopeKey), 0 WHERE NOT EXISTS (SELECT 1 FROM scope_heads WHERE scope_key = \(bind: id.scopeKey))
            """).run()
        try await sql.raw("""
            INSERT INTO snapshots (database_id, scope_key, head_seq, manifest, created_at, expires_at)
            VALUES (\(bind: id.databaseID.uppercased()), \(bind: id.scopeKey), \(bind: id.head), \(bind: manifest),
                    \(bind: ServerTimestamp.string(now)),
                    \(bind: ServerTimestamp.string(now.addingTimeInterval(TimeInterval(ServerLimits.snapshotLifetimeSeconds)))))
            """).run()
        return snapshot
    }

    private func livePrompts(identity: SyncAPI.ScopeIdentity, after: String) async throws -> [SyncAPI.FeedPrompt] {
        let ownership: SQLQueryString
        switch identity {
        case .user(let id): ownership = "scope = 'user' AND owner_id = \(bind: id)"
        case .group(let id, _, _): ownership = "scope = 'group' AND group_id = \(bind: id)"
        }
        return try await sql.raw("""
            SELECT id, rev, path, content FROM prompts
            WHERE \(ownership) AND deleted_at IS NULL AND id > \(bind: after)
            ORDER BY id LIMIT \(literal: ServerLimits.syncPageMaxItems)
            """).all().map {
                try .init(id: $0.decode(column: "id", as: String.self), rev: $0.decode(column: "rev", as: Int64.self),
                          path: $0.decode(column: "path", as: String.self), content: $0.decode(column: "content", as: String.self))
            }
    }

    private func makeRoom(bytes: Int, now: Date, protecting protected: Set<SnapshotID>) async throws {
        try await sql.raw("DELETE FROM snapshots WHERE expires_at <= \(bind: ServerTimestamp.string(now))").run()
        guard let row = try await sql.raw("SELECT COALESCE(SUM(length(manifest)), 0) AS bytes FROM snapshots").first() else {
            throw SyncFeedPersistenceError.invalidRecord
        }
        var stored = try row.decode(column: "bytes", as: Int.self)
        if stored + bytes <= ServerLimits.snapshotTotalMaxBytes { return }
        let candidates = try await sql.raw("""
            SELECT database_id, scope_key, head_seq, length(manifest) AS bytes FROM snapshots
            ORDER BY created_at, scope_key, head_seq
            """).all()
        for row in candidates {
            let id = try SnapshotID(databaseID: row.decode(column: "database_id", as: String.self).lowercased(),
                                    scopeKey: row.decode(column: "scope_key", as: String.self), head: row.decode(column: "head_seq", as: Int64.self))
            if protected.contains(id) { continue }
            try await sql.raw("""
                DELETE FROM snapshots WHERE database_id = \(bind: id.databaseID.uppercased())
                    AND scope_key = \(bind: id.scopeKey) AND head_seq = \(bind: id.head)
                """).run()
            stored -= try row.decode(column: "bytes", as: Int.self)
            if stored + bytes <= ServerLimits.snapshotTotalMaxBytes { return }
        }
        // Never evict a manifest whose continuation is being returned in this pull.
        throw SyncFeedError.snapshotTooLarge
    }
}
