import Foundation
import SQLKit

struct LoginRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(_ operation: @escaping @Sendable (Transaction) async throws -> T) async throws -> T {
        try await database.read { try await operation(Transaction(sql: $0)) }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository) async throws -> T
    ) async throws -> T {
        try await database.write { try await operation(Transaction(sql: $0), .init(sql: $0), .init(sql: $0)) }
    }

    struct Transaction: Sendable {
        let sql: any SQLDatabase

        func buckets(username: String, ip: String, at now: Date) async throws -> (account: LoginBucket, ip: LoginBucket) {
            let account = try await load(table: "login_account_buckets", key: "username", value: username, at: now)
            let ip = try await load(table: "login_ip_buckets", key: "ip", value: ip, at: now)
            return (account, ip)
        }

        func recordFailure(username: String, ip: String, account: LoginBucket, address: LoginBucket) async throws {
            try await save(account, table: "login_account_buckets", key: "username", value: username)
            try await save(address, table: "login_ip_buckets", key: "ip", value: ip)
        }

        func resetAccount(username: String) async throws {
            try await sql.raw("DELETE FROM login_account_buckets WHERE username = \(bind: username)").run()
        }

        private func load(table: String, key: String, value: String, at now: Date) async throws -> LoginBucket {
            guard let row = try await sql.raw("SELECT * FROM \(ident: table) WHERE \(ident: key) = \(bind: value)").first() else {
                return LoginBucket(failures: 0, lockedUntil: nil, updatedAt: now)
            }
            let failures = try row.decode(column: "failures", as: Int.self)
            let lockString = try row.decode(column: "locked_until", as: String?.self)
            guard let updated = try ServerTimestamp.date(row.decode(column: "updated_at", as: String.self)),
                  lockString == nil || ServerTimestamp.date(lockString!) != nil else {
                throw PersistenceError.invalidLoginBucket
            }
            // Stored counters may come from a previous policy. Saturate work and
            // arithmetic while preserving the most restrictive current step.
            return LoginBucket(failures: min(failures, ServerLimits.loginMaximumFailures),
                               lockedUntil: lockString.flatMap(ServerTimestamp.date), updatedAt: updated).decayed(at: now)
        }

        private func save(_ bucket: LoginBucket, table: String, key: String, value: String) async throws {
            try await sql.raw("""
                INSERT INTO \(ident: table) (\(ident: key), failures, locked_until, updated_at)
                VALUES (\(bind: value), \(bind: bucket.failures), \(bind: bucket.lockedUntil.map(ServerTimestamp.string)),
                        \(bind: ServerTimestamp.string(bucket.updatedAt)))
                ON CONFLICT (\(ident: key)) DO UPDATE SET failures = excluded.failures,
                    locked_until = excluded.locked_until, updated_at = excluded.updated_at
                """).run()
        }
    }
}
