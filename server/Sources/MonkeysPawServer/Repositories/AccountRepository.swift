import Foundation
import MonkeysPawCore
import SQLKit

struct AccountRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let username: String
    let displayName: String?
    let passwordHash: String
    let accountKind: SyncAPI.AccountKind
    let createdAt: String
    let disabledAt: String?

    var description: String { "AccountRecord(<redacted>)" }
    var debugDescription: String { description }
    var metadata: SyncAPI.User {
        .init(id: id, username: username, displayName: displayName, accountKind: accountKind,
              createdAt: createdAt, disabledAt: disabledAt)
    }
}

private extension AccountRecord {
    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: String.self)
        username = try row.decode(column: "username", as: String.self)
        displayName = try row.decode(column: "display_name", as: String?.self)
        passwordHash = try row.decode(column: "password_hash", as: String.self)
        guard let kind = try SyncAPI.AccountKind(rawValue: row.decode(column: "account_kind", as: String.self)) else {
            throw PersistenceError.invalidAccountRecord
        }
        accountKind = kind
        createdAt = try row.decode(column: "created_at", as: String.self)
        disabledAt = try row.decode(column: "disabled_at", as: String?.self)
    }
}

/// Account and device operations share one supplied SQL transaction.
struct AccountRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.read { try await operation(Transaction(sql: $0), DeviceRepository(sql: $0)) }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.write { try await operation(Transaction(sql: $0), DeviceRepository(sql: $0)) }
    }

    func writeAudited<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, DeviceRepository, AuditRepository) async throws -> T
    ) async throws -> T {
        try await database.write { try await operation(Transaction(sql: $0), DeviceRepository(sql: $0), AuditRepository(sql: $0)) }
    }

    struct Transaction: Sendable {
        fileprivate let sql: any SQLDatabase

        init(sql: any SQLDatabase) { self.sql = sql }

        func hasUsers() async throws -> Bool {
            try await sql.raw("SELECT 1 FROM users LIMIT 1").first() != nil
        }

        func user(id: String) async throws -> AccountRecord? {
            try await sql.raw("SELECT * FROM users WHERE id = \(bind: id)").first().map(AccountRecord.init(row:))
        }

        func user(username: String) async throws -> AccountRecord? {
            try await sql.raw("SELECT * FROM users WHERE username = \(bind: username)").first().map(AccountRecord.init(row:))
        }

        func hasActiveAdmin(excluding id: String) async throws -> Bool {
            try await sql.raw("""
                SELECT 1 FROM users WHERE account_kind = \(bind: SyncAPI.AccountKind.admin.rawValue)
                    AND disabled_at IS NULL AND id <> \(bind: id) LIMIT 1
                """).first() != nil
        }

        func insert(_ user: AccountRecord) async throws {
            try await sql.raw("""
                INSERT INTO users (id, username, display_name, password_hash, account_kind, created_at, disabled_at)
                VALUES (\(bind: user.id), \(bind: user.username), \(bind: user.displayName), \(bind: user.passwordHash),
                        \(bind: user.accountKind.rawValue), \(bind: user.createdAt), \(bind: user.disabledAt))
                """).run()
        }

        func changePassword(userID: String, hash: String) async throws {
            try await sql.raw("UPDATE users SET password_hash = \(bind: hash) WHERE id = \(bind: userID)").run()
        }

        func update(_ user: AccountRecord) async throws {
            try await sql.raw("""
                UPDATE users SET display_name = \(bind: user.displayName), password_hash = \(bind: user.passwordHash),
                    account_kind = \(bind: user.accountKind.rawValue), disabled_at = \(bind: user.disabledAt)
                WHERE id = \(bind: user.id)
                """).run()
        }

        func groups(userID: String) async throws -> [SyncAPI.GroupMembership] {
            let rows = try await sql.raw("""
                SELECT g.id, g.name, m.role FROM memberships m JOIN groups g ON g.id = m.group_id
                WHERE m.user_id = \(bind: userID) AND g.deleted_at IS NULL ORDER BY g.id
                """).all()
            return try rows.map { row in
                guard let role = try SyncAPI.Role(rawValue: row.decode(column: "role", as: String.self)) else {
                    throw PersistenceError.invalidAccountRecord
                }
                return try .init(groupID: row.decode(column: "id", as: String.self),
                                 name: row.decode(column: "name", as: String.self), role: role)
            }
        }
    }
}
