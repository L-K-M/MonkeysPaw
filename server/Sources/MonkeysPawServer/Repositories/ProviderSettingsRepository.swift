import MonkeysPawCore
import SQLKit

/// §26 S1: the stored document is opaque ciphertext; `rev` orders writes.
struct ProviderSettingsRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let userID: String
    let rev: Int64
    let document: String
    let updatedAt: String

    var description: String { "ProviderSettingsRecord(<redacted>)" }
    var debugDescription: String { description }
}

struct ProviderSettingsRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.read {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0), DeviceRepository(sql: $0))
        }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.write {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0), DeviceRepository(sql: $0))
        }
    }

    struct Transaction: Sendable {
        private let sql: any SQLDatabase

        init(sql: any SQLDatabase) { self.sql = sql }

        func record(userID: String) async throws -> ProviderSettingsRecord? {
            try await sql.raw("SELECT * FROM provider_settings WHERE user_id = \(bind: userID)").first()
                .map(Self.record(row:))
        }

        /// Last writer wins: one upsert unconditionally replaces the document
        /// and increments the account-scoped revision.
        func upsert(userID: String, document: String, at: String) async throws -> ProviderSettingsRecord {
            try await sql.raw("""
                INSERT INTO provider_settings (user_id, rev, document, updated_at)
                VALUES (\(bind: userID), 1, \(bind: document), \(bind: at))
                ON CONFLICT (user_id) DO UPDATE
                SET rev = rev + 1, document = excluded.document, updated_at = excluded.updated_at
                """).run()
            guard let record = try await record(userID: userID) else {
                throw PersistenceError.invalidAccountRecord
            }
            return record
        }

        private static func record(row: any SQLRow) throws -> ProviderSettingsRecord {
            try .init(userID: row.decode(column: "user_id", as: String.self),
                      rev: row.decode(column: "rev", as: Int64.self),
                      document: row.decode(column: "document", as: String.self),
                      updatedAt: row.decode(column: "updated_at", as: String.self))
        }
    }
}
