import MonkeysPawCore
import SQLKit

struct GroupRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.read {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0), DeviceRepository(sql: $0))
        }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository, AuditRepository) async throws -> T
    ) async throws -> T {
        try await database.write {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0), DeviceRepository(sql: $0), AuditRepository(sql: $0))
        }
    }

    struct Transaction: Sendable {
        private let sql: any SQLDatabase

        init(sql: any SQLDatabase) { self.sql = sql }

        func group(id: String) async throws -> SyncAPI.Group? {
            guard let row = try await sql.raw("SELECT * FROM groups WHERE id = \(bind: id) AND deleted_at IS NULL").first() else { return nil }
            return try .init(id: row.decode(column: "id", as: String.self), name: row.decode(column: "name", as: String.self),
                             createdBy: row.decode(column: "created_by", as: String.self), createdAt: row.decode(column: "created_at", as: String.self))
        }

        func members(groupID: String) async throws -> [SyncAPI.Member] {
            try await sql.raw("""
                SELECT m.*, u.username, u.display_name FROM memberships m JOIN users u ON u.id = m.user_id
                WHERE m.group_id = \(bind: groupID) ORDER BY m.user_id
                """).all().map(Self.member(row:))
        }

        func member(groupID: String, userID: String) async throws -> SyncAPI.Member? {
            try await sql.raw("""
                SELECT m.*, u.username, u.display_name FROM memberships m JOIN users u ON u.id = m.user_id
                WHERE m.group_id = \(bind: groupID) AND m.user_id = \(bind: userID)
                """).first().map(Self.member(row:))
        }

        func ownerCount(groupID: String) async throws -> Int {
            guard let row = try await sql.raw("""
                SELECT COUNT(*) AS count FROM memberships WHERE group_id = \(bind: groupID) AND role = 'owner'
                """).first() else { throw PersistenceError.invalidAccountRecord }
            return try row.decode(column: "count", as: Int.self)
        }

        func insert(_ group: SyncAPI.Group) async throws {
            try await sql.raw("""
                INSERT INTO groups (id, name, created_by, created_at)
                VALUES (\(bind: group.id), \(bind: group.name), \(bind: group.createdBy), \(bind: group.createdAt))
                """).run()
        }

        func rename(id: String, name: String) async throws {
            try await sql.raw("UPDATE groups SET name = \(bind: name) WHERE id = \(bind: id)").run()
        }

        func upsertMember(groupID: String, userID: String, role: SyncAPI.Role, at: String) async throws {
            try await sql.raw("""
                INSERT INTO memberships (group_id, user_id, role, joined_at)
                VALUES (\(bind: groupID), \(bind: userID), \(bind: role.rawValue), \(bind: at))
                ON CONFLICT (group_id, user_id) DO UPDATE SET role = excluded.role
                """).run()
        }

        func removeMember(groupID: String, userID: String) async throws {
            try await sql.raw("DELETE FROM memberships WHERE group_id = \(bind: groupID) AND user_id = \(bind: userID)").run()
        }

        func delete(id: String, actorID: String, at: String) async throws {
            // Retain the group identity for revision, feed and retired-ID foreign keys.
            try await sql.raw("UPDATE groups SET deleted_at = \(bind: at) WHERE id = \(bind: id)").run()
            try await sql.raw("""
                INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, group_id, path, content, created_at, origin)
                SELECT id, rev + 1, \(bind: actorID), scope, owner_id, group_id, path, content, \(bind: at), 'delete'
                FROM prompts WHERE group_id = \(bind: id) AND deleted_at IS NULL
                """).run()
            try await sql.raw("""
                INSERT INTO changes (scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at)
                SELECT 'group:' || group_id, scope, owner_id, group_id, id, 'delete', path, rev + 1, NULL, \(bind: at)
                FROM prompts WHERE group_id = \(bind: id) AND deleted_at IS NULL ORDER BY id
                """).run()
            try await sql.raw("""
                UPDATE prompts SET rev = rev + 1, updated_by = \(bind: actorID), updated_at = \(bind: at), deleted_at = \(bind: at)
                WHERE group_id = \(bind: id) AND deleted_at IS NULL
                """).run()
            // Earlier tombstones may predate retirement handling; never replace a retired ID.
            try await sql.raw("""
                INSERT INTO retired_prompt_ids (prompt_id, scope, owner_id, group_id, retired_at)
                SELECT p.id, p.scope, p.owner_id, p.group_id, p.deleted_at FROM prompts p
                WHERE p.group_id = \(bind: id) AND NOT EXISTS (
                    SELECT 1 FROM retired_prompt_ids r WHERE r.prompt_id = p.id)
                """).run()
            try await sql.raw("DELETE FROM memberships WHERE group_id = \(bind: id)").run()
        }

        private static func member(row: any SQLRow) throws -> SyncAPI.Member {
            guard let role = try SyncAPI.Role(rawValue: row.decode(column: "role", as: String.self)) else {
                throw PersistenceError.invalidAccountRecord
            }
            return try .init(userID: row.decode(column: "user_id", as: String.self), username: row.decode(column: "username", as: String.self),
                             displayName: row.decode(column: "display_name", as: String?.self), role: role,
                             joinedAt: row.decode(column: "joined_at", as: String.self))
        }
    }
}
