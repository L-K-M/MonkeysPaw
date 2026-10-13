import FluentSQLiteDriver
import Foundation
import SQLKit

struct BackupRepository: Sendable {
    let database: ServerDatabase

    func vacuum(into file: URL) async throws {
        try await database.maintenance { sql in
            try await sql.raw("VACUUM INTO \(bind: file.path)").run()
        }
    }

    func rotateIdentity() async throws -> UUID {
        try await database.write { sql in
            let id = UUID()
            // Snapshot payloads reference the old UUID and must never survive a restore.
            try await sql.raw("DELETE FROM snapshots").run()
            try await sql.raw("UPDATE meta SET database_id = \(bind: id.uuidString) WHERE singleton = 1").run()
            return id
        }
    }

    func checkpoint() async throws {
        try await database.maintenance { try await Self.checkpoint($0) }
    }

    static func validate(_ file: URL) async throws -> UUID {
        try DatabaseFiles.checkHeader(file)
        return try await connection(file, access: .immutable) { try await validate($0) }
    }

    static func stage(_ input: URL, into staged: URL) async throws {
        try DatabaseFiles.checkHeader(input)
        try await connection(input, access: .readOnly) { sql in
            _ = try await validate(sql)
            // SQLite snapshots even a source with WAL; never copy raw live database bytes.
            try await sql.raw("VACUUM INTO \(bind: staged.path)").run()
        }
        _ = try await validate(staged)
    }

    static func preparePrevious(_ file: URL) async throws {
        try DatabaseFiles.checkRegular(file)
        let hasJournal = try ["-wal", "-shm", "-journal"].contains {
            try DatabaseFiles.occupied(URL(fileURLWithPath: file.path + $0))
        }
        // With no journal to recover, preserve even damaged bytes without opening SQLite.
        if !hasJournal {
            try DatabaseFiles.sync(file)
            return
        }
        try DatabaseFiles.checkHeader(file)
        try await connection(file, access: .readWrite) { sql in
            try await sql.raw("PRAGMA synchronous = FULL").run()
            try await checkpoint(sql)
            // Exclusive application lock is held and every old connection closes before rename.
            guard let row = try await sql.raw("PRAGMA journal_mode = DELETE").first(),
                  try row.decode(column: "journal_mode", as: String.self) == "delete" else {
                throw BackupRestoreError.failed
            }
        }
        try DatabaseFiles.sync(file)
    }

    private static func checkpoint(_ sql: any SQLDatabase) async throws {
        guard let row = try await sql.raw("PRAGMA wal_checkpoint(TRUNCATE)").first(),
              try row.decode(column: "busy", as: Int.self) == 0 else {
            throw BackupRestoreError.databaseInUse
        }
    }

    private static func validate(_ sql: any SQLDatabase) async throws -> UUID {
        let integrity = try await sql.raw("PRAGMA integrity_check").all()
        guard integrity.count == 1,
              try integrity[0].decode(column: "integrity_check", as: String.self) == "ok",
              try await sql.raw("PRAGMA foreign_key_check").all().isEmpty else {
            throw BackupRestoreError.invalidBackup
        }
        guard let application = try await sql.raw("PRAGMA application_id").first(),
              try application.decode(column: "application_id", as: Int.self) == 0 else {
            throw BackupRestoreError.foreignBackup
        }
        let tables = Set(try await sql.raw("SELECT name FROM sqlite_schema WHERE type = 'table'").all().map {
            try $0.decode(column: "name", as: String.self)
        })
        let required: Set<String> = ["schema_migrations", "meta", "users", "groups", "memberships", "prompts",
            "prompt_revisions", "changes", "scope_heads", "scope_floors", "retired_prompt_ids", "snapshots",
            "devices", "invites", "login_account_buckets", "login_ip_buckets", "audit_events"]
        guard required.isSubset(of: tables) else { throw BackupRestoreError.foreignBackup }
        let names = try await sql.raw("SELECT name FROM schema_migrations ORDER BY name").all().map {
            try $0.decode(column: "name", as: String.self)
        }
        guard names.first == ServerMigration.foundation.name else { throw BackupRestoreError.foreignBackup }
        let known = ServerMigration.current.map(\.name)
        guard names == Array(known.prefix(names.count)),
              let version = try await sql.raw("PRAGMA user_version").first(),
              try version.decode(column: "user_version", as: Int.self) == 0 else {
            throw BackupRestoreError.newerSchema
        }
        let rows = try await sql.raw("SELECT singleton, database_id FROM meta").all()
        guard rows.count == 1, try rows[0].decode(column: "singleton", as: Int.self) == 1,
              let id = try UUID(uuidString: rows[0].decode(column: "database_id", as: String.self)),
              try rows[0].decode(column: "database_id", as: String.self) == id.uuidString else {
            throw BackupRestoreError.foreignBackup
        }
        return id
    }

    private enum Access { case readOnly, immutable, readWrite }

    private static func connection<T: Sendable>(
        _ file: URL, access: Access, operation: @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: access == .readWrite ? "rw" : "ro")]
        if access == .immutable { components.queryItems!.append(URLQueryItem(name: "immutable", value: "1")) }
        let connection = try await SQLiteConnection.open(storage: .file(path: components.url!.absoluteString),
                                                         logger: ServerLogging.logger(level: .critical)).get()
        do {
            let sql = connection.sql(queryLogLevel: nil)
            try await sql.raw("PRAGMA busy_timeout = \(literal: ServerLimits.databaseBusyTimeoutMilliseconds)").run()
            let result = try await operation(sql)
            try await connection.close()
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }
}
