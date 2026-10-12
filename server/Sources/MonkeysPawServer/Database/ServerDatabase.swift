import FluentSQLiteDriver
import Foundation
import HummingbirdFluent
import SQLKit

/// Owns connections; repositories are the only consumers of transaction access.
public final class ServerDatabase: Sendable {
    private let fluent: Fluent
    private let writer: any Database
    private let gate = WriterGate()
    private static let readers = DatabaseID(string: "readers")

    private init(configuration: DatabaseConfiguration) throws {
        try FileManager.default.createDirectory(
            at: configuration.dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // SQL and driver errors can contain credentials or prompt text (§12).
        var logger = Logger(label: "monkeyspaw-database")
        logger.logLevel = .critical
        fluent = Fluent(logger: logger)
        let sqlite = SQLiteConfiguration(storage: .file(path: configuration.databasePath), enableForeignKeys: true)
        for id in [DatabaseID.sqlite, Self.readers] {
            fluent.databases.use(
                .sqlite(
                    sqlite,
                    connectionPoolTimeout: .seconds(ServerLimits.databasePoolTimeoutSeconds),
                    sqlLogLevel: nil
                ),
                as: id
            )
        }
        writer = fluent.db(.sqlite)
    }

    static func open(configuration: DatabaseConfiguration) async throws -> ServerDatabase {
        let database = try ServerDatabase(configuration: configuration)
        do {
            // Changing journal mode inside BEGIN is illegal. Do this before migrations.
            try await database.writer.withConnection { connection in
                let sql = try Self.sql(connection)
                try await Self.configure(sql)
                guard let row = try await sql.raw("PRAGMA journal_mode = WAL").first(),
                      try row.decode(column: "journal_mode", as: String.self).lowercased() == "wal" else {
                    throw PersistenceError.walUnavailable
                }
            }
            return database
        } catch {
            await database.shutdown()
            throw error
        }
    }

    /// Keeps the database alive through serving, and closes it on every exit path.
    public static func withMigratedDatabase<T: Sendable>(
        configuration: DatabaseConfiguration,
        operation: @Sendable (ServerDatabase) async throws -> T
    ) async throws -> T {
        let database: ServerDatabase
        do {
            database = try await open(configuration: configuration)
        } catch {
            throw StartupError()
        }
        do {
            do {
                try await database.migrate()
            } catch {
                throw StartupError()
            }
            let result = try await operation(database)
            await database.shutdown()
            return result
        } catch {
            await database.shutdown()
            throw error
        }
    }

    func migrate(_ migrations: [ServerMigration] = [.foundation]) async throws {
        try await MigrationRepository(database: self).apply(migrations)
    }

    func shutdown() async {
        await fluent.databases.shutdownAsync()
    }

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        try await fluent.db(Self.readers).withConnection { connection in
            let sql = try Self.sql(connection)
            try await Self.configure(sql)
            try await sql.raw("PRAGMA query_only = ON").run()
            try await Self.verifyWAL(sql)
            return try await Self.transaction(sql, begin: "BEGIN", operation: operation)
        }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        let cancellation = TransactionCancellation()
        return try await withTaskCancellationHandler {
            try await gate.run {
                try await self.writer.withConnection { connection in
                    try cancellation.check()
                    let sql = try Self.sql(connection)
                    try await Self.configure(sql)
                    try await Self.verifyWAL(sql)
                    return try await Self.transaction(sql, begin: "BEGIN IMMEDIATE") { transaction in
                        let result = try await operation(transaction)
                        try cancellation.check()
                        return result
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func sql(_ connection: any Database) throws -> any SQLDatabase {
        guard let sql = connection as? any SQLDatabase else { throw PersistenceError.unsupportedDriver }
        return sql
    }

    private static func configure(_ sql: any SQLDatabase) async throws {
        try await sql.raw("PRAGMA foreign_keys = ON").run()
        try await sql.raw("PRAGMA busy_timeout = \(literal: ServerLimits.databaseBusyTimeoutMilliseconds)").run()
        try await sql.raw("PRAGMA synchronous = FULL").run()

        for (pragma, expected) in [("foreign_keys", 1), ("busy_timeout", ServerLimits.databaseBusyTimeoutMilliseconds), ("synchronous", 2)] {
            guard let row = try await sql.raw("PRAGMA \(unsafeRaw: pragma)").first(),
                  try row.decode(column: pragma == "busy_timeout" ? "timeout" : pragma, as: Int.self) == expected else {
                throw PersistenceError.invalidPragma
            }
        }
    }

    private static func verifyWAL(_ sql: any SQLDatabase) async throws {
        guard let row = try await sql.raw("PRAGMA journal_mode").first(),
              try row.decode(column: "journal_mode", as: String.self).lowercased() == "wal" else {
            throw PersistenceError.walUnavailable
        }
    }

    private static func transaction<T: Sendable>(
        _ sql: any SQLDatabase,
        begin: SQLQueryString,
        operation: @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        try await sql.raw(begin).run()
        do {
            let result = try await operation(sql)
            try Task.checkCancellation()
            try await sql.raw("COMMIT").run()
            return result
        } catch {
            try? await sql.raw("ROLLBACK").run()
            throw error
        }
    }
}

private struct StartupError: Error, CustomStringConvertible {
    var description: String { "Database initialization or migration failed." }
}

enum PersistenceError: Error {
    case unsupportedDriver
    case invalidPragma
    case walUnavailable
    case missingDatabaseID
}
