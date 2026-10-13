import Foundation
import MonkeysPawCore
import SQLKit

struct FeedScopeRecord: Sendable {
    let identity: SyncAPI.ScopeIdentity
    let head: Int64
    let floor: Int64
}

struct SyncFeedRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.read {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0), DeviceRepository(sql: $0))
        }
    }

    struct Transaction: Sendable {
        private let sql: any SQLDatabase

        init(sql: any SQLDatabase) { self.sql = sql }

        func databaseID() async throws -> String {
            guard let row = try await sql.raw("SELECT database_id FROM meta WHERE singleton = 1").first(),
                  let id = try UUID(uuidString: row.decode(column: "database_id", as: String.self)) else {
                throw PersistenceError.missingDatabaseID
            }
            // Storage uses uppercase UUIDs; S1's wire contract uses lowercase.
            return id.uuidString.lowercased()
        }

        func scopes(userID: String) async throws -> [FeedScopeRecord] {
            let key = "user:\(userID)"
            guard let privateRow = try await sql.raw("""
                SELECT COALESCE(h.head_seq, 0) AS head, COALESCE(f.floor_seq, 1) AS floor
                FROM (SELECT \(bind: key) AS scope_key) s
                LEFT JOIN scope_heads h ON h.scope_key = s.scope_key
                LEFT JOIN scope_floors f ON f.scope_key = s.scope_key
                """).first() else { throw SyncFeedPersistenceError.invalidRecord }
            let personal = try FeedScopeRecord(identity: .user(userID: userID), head: privateRow.decode(column: "head", as: Int64.self),
                                               floor: privateRow.decode(column: "floor", as: Int64.self))
            let groups = try await sql.raw("""
                SELECT g.id, g.name, m.role, COALESCE(h.head_seq, 0) AS head, COALESCE(f.floor_seq, 1) AS floor
                FROM memberships m JOIN groups g ON g.id = m.group_id
                LEFT JOIN scope_heads h ON h.scope_key = 'group:' || g.id
                LEFT JOIN scope_floors f ON f.scope_key = 'group:' || g.id
                WHERE m.user_id = \(bind: userID) AND g.deleted_at IS NULL ORDER BY g.id
                """).all().map { row -> FeedScopeRecord in
                    guard let role = try SyncAPI.Role(rawValue: row.decode(column: "role", as: String.self)) else {
                        throw SyncFeedPersistenceError.invalidRecord
                    }
                    return try .init(identity: .group(groupID: row.decode(column: "id", as: String.self),
                                                       name: row.decode(column: "name", as: String.self), role: role),
                                     head: row.decode(column: "head", as: Int64.self), floor: row.decode(column: "floor", as: Int64.self))
                }
            return [personal] + groups
        }

        func nextSequence(key: String, after cursor: Int64, through head: Int64) async throws -> Int64? {
            try await sql.raw("""
                SELECT seq FROM changes
                WHERE scope_key = \(bind: key) AND seq > \(bind: cursor) AND seq <= \(bind: head)
                ORDER BY seq LIMIT 1
                """).first()?.decode(column: "seq", as: Int64.self)
        }

        func item(key: String, seq: Int64) async throws -> SyncAPI.FeedItem {
            guard let row = try await sql.raw("""
                SELECT seq, prompt_id, kind, path, rev, content FROM changes
                WHERE scope_key = \(bind: key) AND seq = \(bind: seq)
                """).first() else { throw SyncFeedPersistenceError.invalidRecord }
            let id = try row.decode(column: "prompt_id", as: String.self)
            switch try row.decode(column: "kind", as: String.self) {
            case "upsert":
                return try .upsert(seq: seq, prompt: .init(id: id, rev: row.decode(column: "rev", as: Int64.self),
                                                         path: row.decode(column: "path", as: String.self),
                                                         content: row.decode(column: "content", as: String.self)))
            case "delete": return .delete(seq: seq, id: id)
            case "move_out": return .moveOut(seq: seq, id: id)
            default: throw SyncFeedPersistenceError.invalidRecord
            }
        }
    }
}

enum SyncFeedPersistenceError: Error {
    case invalidRecord
}
