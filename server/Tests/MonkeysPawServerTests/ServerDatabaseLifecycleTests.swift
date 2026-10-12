import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerDatabaseLifecycleTests {
    private typealias Fixtures = PersistenceTestRepository

    @Test func writersAreSerialAcrossSuspensionAndReadersSeeCommittedData() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            let started = DatabaseTestLatch()
            let release = DatabaseTestLatch()
            let writer = Task {
                try await repository.database.write { sql in
                    try await sql.raw("UPDATE users SET display_name = 'uncommitted'").run()
                    await started.open()
                    await release.wait()
                }
            }
            await started.wait()
            do {
                // This must complete while the write transaction remains open.
                let value = try await repository.string("SELECT display_name FROM users LIMIT 1", column: "display_name")
                #expect(value == "Fixture")
                await release.open()
                try await writer.value
            } catch {
                await release.open()
                _ = await writer.result
                throw error
            }

            try await repository.execute("CREATE TABLE writer_probe (value INTEGER NOT NULL)")
            try await repository.execute("INSERT INTO writer_probe VALUES (0)")
            let activity = WriterActivity()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<32 {
                    group.addTask {
                        try await repository.database.write { sql in
                            await activity.enter()
                            let row = try #require(await sql.raw("SELECT value FROM writer_probe").first())
                            let value = try row.decode(column: "value", as: Int.self)
                            await Task.yield()
                            try await sql.raw("UPDATE writer_probe SET value = \(bind: value + 1)").run()
                            await activity.leave()
                        }
                    }
                }
                try await group.waitForAll()
            }
            #expect(await activity.maximum == 1)
            #expect(try await repository.string("SELECT value FROM writer_probe", column: "value") == "32")
        }
    }

    @Test func cancelledAndFailedWritersRollbackAndReleaseTheGate() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            let started = DatabaseTestLatch()
            let release = DatabaseTestLatch()
            let writer = Task {
                try await repository.database.write { sql in
                    try await sql.raw("UPDATE users SET display_name = 'cancelled'").run()
                    await started.open()
                    await release.wait()
                }
            }
            await started.wait()
            writer.cancel()
            await release.open()
            await #expect(throws: CancellationError.self) { try await writer.value }
            #expect(try await repository.string("SELECT display_name FROM users LIMIT 1", column: "display_name") == "Fixture")
            await #expect(throws: (any Error).self) {
                try await repository.database.write { sql in
                    try await sql.raw("UPDATE users SET display_name = 'failed'").run()
                    try await sql.raw("INSERT INTO no_such_table VALUES (1)").run()
                }
            }
            #expect(try await repository.string("SELECT display_name FROM users LIMIT 1", column: "display_name") == "Fixture")
            try await repository.execute("UPDATE users SET display_name = 'committed'")
        }
    }

    @Test func frozenSnapshotsHaveIdentityLifetimeStorageAndForeignKeyBounds() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.execute(Fixtures.change())
            let id = try await MetaRepository(database: repository.database).databaseID().uuidString
            let key = "user:\(Fixtures.user)"
            let insert: SQLQueryString = """
                INSERT INTO snapshots VALUES (\(bind: id), \(bind: key), 1, X'7b7d',
                    '2026-10-12T00:00:00.000Z', '2026-10-12T00:15:00.000Z')
                """
            try await repository.execute(insert)
            await repository.reject(insert)
            await repository.reject("UPDATE snapshots SET manifest = X'00'")
            await repository.reject("INSERT OR REPLACE INTO snapshots SELECT database_id, scope_key, head_seq, X'00', created_at, expires_at FROM snapshots")
            for (created, expires) in [("invalid", "invalid"), (Fixtures.time, Fixtures.time),
                                       (Fixtures.time, "2026-10-12T00:15:00.001Z"),
                                       (Fixtures.time, "2026-10-12T00:15:01.000Z"),
                                       (Fixtures.time, "2026-10-11T23:59:59.000Z")] {
                await repository.reject("INSERT INTO snapshots VALUES (\(bind: id), \(bind: key), 2, X'01', \(bind: created), \(bind: expires))")
            }
            for query: SQLQueryString in [
                "INSERT INTO snapshots SELECT 'wrong-database', scope_key, 2, manifest, created_at, expires_at FROM snapshots",
                "INSERT INTO snapshots SELECT database_id, 'missing', 2, manifest, created_at, expires_at FROM snapshots",
                "INSERT INTO snapshots SELECT database_id, scope_key, -1, manifest, created_at, expires_at FROM snapshots",
                "INSERT INTO snapshots SELECT database_id, scope_key, 1.5, manifest, created_at, expires_at FROM snapshots",
                "INSERT INTO snapshots SELECT database_id, scope_key, 2, 'text', created_at, expires_at FROM snapshots",
                "INSERT INTO snapshots SELECT database_id, scope_key, 2, X'', created_at, expires_at FROM snapshots",
                "INSERT INTO snapshots SELECT database_id, scope_key, 2, zeroblob(\(literal: ServerLimits.snapshotMaxBytes + 1)), created_at, expires_at FROM snapshots",
            ] {
                await repository.reject(query)
            }
            try await repository.execute("DELETE FROM snapshots")
            for head in 1...4 {
                try await repository.execute("""
                    INSERT INTO snapshots VALUES (\(bind: id), \(bind: key), \(bind: head),
                        zeroblob(\(literal: ServerLimits.snapshotMaxBytes)),
                        '2026-10-12T00:00:00.000Z', '2026-10-12T00:15:00.000Z')
                    """)
            }
            await repository.reject("""
                INSERT INTO snapshots VALUES (\(bind: id), \(bind: key), 5, X'01',
                    '2026-10-12T00:00:00.000Z', '2026-10-12T00:15:00.000Z')
                """)
            #expect(try await repository.count("snapshots") == 4)
        }
    }

    @Test func CLIRepeatedMigrationAndStartupMigrationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s5-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let first = try await Self.runCLI("migrate", dataDirectory: directory)
        #expect(first.status == 0)
        let identity = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            try await MetaRepository(database: database).databaseID()
        }
        #expect(try await Self.runCLI("migrate", dataDirectory: directory).status == 0)
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            #expect(try await MetaRepository(database: database).databaseID() == identity)
            // Undo only the marker and collide with an existing table to force real migration failure.
            try await Fixtures(database: database).execute("DELETE FROM schema_migrations")
        }
        for command in ["migrate", "serve"] {
            let result = try await Self.runCLI(command, dataDirectory: directory)
            #expect(result.exitedNormally)
            #expect(result.status != 0)
            #expect(result.error.contains("Database initialization or migration failed."))
            #expect(!result.error.contains("CREATE TABLE"))
        }
    }

    @Test func dataDirectoryDefaultsAndBlankValues() {
        #expect(DatabaseConfiguration(environment: [:]).databasePath == "/data/monkeyspaw.db")
        for value in ["", " \t\n"] {
            #expect(DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": value]).databasePath == "/data/monkeyspaw.db")
        }
    }

    private struct CLIResult: Sendable {
        let status: Int32
        let exitedNormally: Bool
        let error: String
    }

    private static func runCLI(_ command: String, dataDirectory: URL) async throws -> CLIResult {
        // Linux test binaries and macOS test bundles both live beneath the product directory.
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var executable: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("monkeyspaw-server")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                executable = candidate
                break
            }
            directory.deleteLastPathComponent()
        }
        let path = try #require(executable)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = path
                process.arguments = [command]
                var environment = ProcessInfo.processInfo.environment
                environment["MONKEYSPAW_DATA_DIR"] = dataDirectory.path
                environment["MONKEYSPAW_HTTP_HOST"] = "127.0.0.1"
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                        if process.isRunning { process.terminate() }
                    }
                    let error = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: CLIResult(
                        status: process.terminationStatus,
                        exitedNormally: process.terminationReason == .exit,
                        error: String(decoding: error, as: UTF8.self)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private actor DatabaseTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor WriterActivity {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() { active -= 1 }
}
