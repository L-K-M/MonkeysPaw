import MonkeysPawCore
import SQLKit

struct InviteRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    // Storage also admits owner invites from the explicit CLI operator (§8.2).
    enum Target: Sendable, Equatable {
        case account
        case group(groupID: String, role: SyncAPI.Role)
    }

    let tokenHash: String
    let target: Target
    let createdBy: String
    let expiresAt: String
    let consumedAt: String?
    var description: String { "InviteRecord(<redacted>)" }
    var debugDescription: String { description }
}

private extension InviteRecord {
    init(row: any SQLRow) throws {
        tokenHash = try row.decode(column: "token_hash", as: String.self)
        createdBy = try row.decode(column: "created_by", as: String.self)
        expiresAt = try row.decode(column: "expires_at", as: String.self)
        consumedAt = try row.decode(column: "consumed_at", as: String?.self)
        let groupID = try row.decode(column: "group_id", as: String?.self)
        let role = try row.decode(column: "role", as: String?.self)
        switch (groupID, role) {
        case (nil, nil): target = .account
        case (.some(let id), .some(let value)):
            guard let role = SyncAPI.Role(rawValue: value) else { throw PersistenceError.invalidAccountRecord }
            target = .group(groupID: id, role: role)
        default: throw PersistenceError.invalidAccountRecord
        }
    }
}

struct InviteRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, GroupRepository.Transaction) async throws -> T
    ) async throws -> T {
        try await database.read { try await operation(Transaction(sql: $0), GroupRepository.Transaction(sql: $0)) }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository,
                                         GroupRepository.Transaction, AuditRepository) async throws -> T
    ) async throws -> T {
        try await database.write {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0), DeviceRepository(sql: $0),
                                GroupRepository.Transaction(sql: $0), AuditRepository(sql: $0))
        }
    }

    struct Transaction: Sendable {
        private let sql: any SQLDatabase

        init(sql: any SQLDatabase) { self.sql = sql }

        func invite(tokenHash: String) async throws -> InviteRecord? {
            try await sql.raw("""
                SELECT token_hash, group_id, role, created_by, expires_at, consumed_at
                FROM invites WHERE token_hash = \(bind: tokenHash)
                """).first().map(InviteRecord.init(row:))
        }

        func insert(_ invite: InviteRecord) async throws {
            let groupID: String?
            let role: String?
            switch invite.target {
            case .account: groupID = nil; role = nil
            case .group(let id, let value): groupID = id; role = value.rawValue
            }
            try await sql.raw("""
                INSERT INTO invites (token_hash, group_id, role, created_by, expires_at, consumed_at)
                VALUES (\(bind: invite.tokenHash), \(bind: groupID), \(bind: role), \(bind: invite.createdBy),
                        \(bind: invite.expiresAt), \(bind: invite.consumedAt))
                """).run()
        }

        func consume(tokenHash: String, at: String) async throws {
            try await sql.raw("""
                UPDATE invites SET consumed_at = \(bind: at)
                WHERE token_hash = \(bind: tokenHash) AND consumed_at IS NULL AND expires_at > \(bind: at)
                """).run()
            guard let row = try await sql.raw("SELECT changes() AS count").first(),
                  try row.decode(column: "count", as: Int.self) == 1 else { throw AccountError.malformedRequest }
        }
    }
}
