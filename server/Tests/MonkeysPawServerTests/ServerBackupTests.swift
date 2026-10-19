import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerBackupTests {
    private typealias Fixture = PersistenceTestRepository

    @Test func onlineBackupCompletesDuringAnUncommittedWriteAndRestoresTheCommittedSnapshot() async throws {
        try await withBackupDirectory { directory in
            let backup = directory.appendingPathComponent("backups/snapshot 'quoted'.db")
            let oldID = try await withBackupDatabase(directory) { database in
                let repository = Fixture(database: database)
                try await repository.seed()
                try await repository.insertPrompt(id: Fixture.prompt)
                try await repository.execute(Fixture.revision())
                try await repository.execute(Fixture.change())
                let id = try await MetaRepository(database: database).databaseID()
                try await repository.execute("""
                    INSERT INTO snapshots VALUES (\(bind: id.uuidString), \(bind: "user:\(Fixture.user)"), 1, X'7b7d',
                        '2026-10-12T00:00:00.000Z', '2026-10-12T00:15:00.000Z')
                    """)
                let started = BackupTestLatch()
                let release = BackupTestLatch()
                let writer = Task {
                    do {
                        try await database.write { sql in
                            try await sql.raw("UPDATE prompts SET rev = 2, content = 'uncommitted'").run()
                            try await sql.raw(Fixture.revision(rev: 2)).run()
                            try await sql.raw(Fixture.change(rev: 2, content: "uncommitted")).run()
                            await started.open()
                            await release.wait()
                        }
                    } catch {
                        // Also wake the backup if transaction setup or fixture SQL fails.
                        await started.open()
                        throw error
                    }
                }
                await started.wait()
                do {
                    let result = try await AdminCLITestFixture.run(["backup", backup.path, "--json"], dataDirectory: directory)
                    let metadata = try result.value(BackupMetadata.self)
                    #expect(metadata.path == backup.path && metadata.databaseID == id.uuidString && metadata.previousPath == nil)
                    #expect(try await BackupRepository.validate(backup) == id)
                    await release.open()
                    try await writer.value
                } catch {
                    await release.open()
                    try await writer.value
                    throw error
                }
                #expect(try await repository.string("SELECT content FROM prompts", column: "content") == "uncommitted")
                return id
            }

            let bytes = try Data(contentsOf: backup)
            let restored = try await AdminCLITestFixture.run(["restore", backup.path, "--json"], dataDirectory: directory)
            let metadata = try restored.value(BackupMetadata.self)
            #expect(metadata.databaseID != oldID.uuidString)
            let recovery = URL(fileURLWithPath: try #require(metadata.previousPath))
            #expect(try await BackupRepository.validate(recovery) == oldID)
            #expect(try Data(contentsOf: backup) == bytes)
            try await withBackupDatabase(directory) { (database) async throws -> Void in
                let repository = Fixture(database: database)
                #expect(try await MetaRepository(database: database).databaseID().uuidString == metadata.databaseID)
                #expect(try await repository.count("users") == 2)
                #expect(try await repository.count("groups") == 2)
                #expect(try await repository.string("SELECT content FROM prompts", column: "content") == "original")
                #expect(try await repository.string("SELECT rev FROM prompts", column: "rev") == "1")
                #expect(try await repository.count("changes") == 1)
                #expect(try await repository.count("prompt_revisions") == 1)
                // Restore clears frozen manifests whose payloads retain the previous UUID.
                #expect(try await repository.count("snapshots") == 0)
            }
            let recovering = directory.appendingPathComponent("recovered-previous")
            let previousRestore = try await AdminCLITestFixture.run(["restore", recovery.path], dataDirectory: recovering)
            #expect(previousRestore.status == 0 && previousRestore.error.isEmpty)
            try await withBackupDatabase(recovering) { (database) async throws -> Void in
                #expect(try await Fixture(database: database).string("SELECT rev FROM prompts", column: "rev") == "2")
            }
            let server = try await BackupTestServer.start(directory: directory)
            server.stop()
        }
    }

    @Test func onlineSnapshotsRemainConsistentWhileWritesCommit() async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { database in
                let repository = Fixture(database: database)
                try await repository.seed()
                try await repository.insertPrompt(id: Fixture.prompt)
                try await repository.execute(Fixture.revision())
                let writer = Task {
                    for rev in 2...40 {
                        try await database.write { sql in
                            try await sql.raw("UPDATE prompts SET rev = \(bind: rev), content = \(bind: String(rev))").run()
                            try await sql.raw(Fixture.revision(rev: rev)).run()
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                do {
                    for number in 1...3 {
                        let backup = directory.appendingPathComponent("backups/\(number).db")
                        let result = try await AdminCLITestFixture.run(["backup", backup.path], dataDirectory: directory)
                        #expect(result.status == 0 && result.output == backup.path + "\n" && result.error.isEmpty)
                        let target = directory.appendingPathComponent("snapshot-\(number)")
                        let restore = try await AdminCLITestFixture.run(["restore", backup.path], dataDirectory: target)
                        #expect(restore.status == 0 && restore.error.isEmpty)
                        try await withBackupDatabase(target) { snapshot in
                            let copy = Fixture(database: snapshot)
                            let rev = try await copy.string("SELECT rev FROM prompts", column: "rev")
                            #expect(try await copy.count("prompt_revisions") == Int(rev))
                            let content = try await copy.string("SELECT content FROM prompts", column: "content")
                            #expect(content == (rev == "1" ? "original" : rev))
                        }
                    }
                    try await writer.value
                } catch {
                    writer.cancel()
                    _ = await writer.result
                    throw error
                }
            }
        }
    }

    @Test(arguments: ["file", "directory", "symlink"])
    func occupiedBackupDestinationsAreNeverChanged(kind: String) async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { database in
                try await Fixture(database: database).seed()
                let path = directory.appendingPathComponent("occupied-secret.db")
                switch kind {
                case "file": try Data("older-backup-secret".utf8).write(to: path)
                case "directory": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                default: try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "missing-secret")
                }
                let result = try await AdminCLITestFixture.run(["backup", path.path, "--json"], dataDirectory: directory)
                result.assertFailure(excluding: [path.path, "older-backup-secret", "missing-secret"])
                #expect(result.error.contains(BackupRestoreError.destinationOccupied.description))
                #expect(try DatabaseFiles.occupied(path))
                if kind == "file" { #expect(try Data(contentsOf: path) == Data("older-backup-secret".utf8)) }
                if kind == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == "missing-secret") }
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".monkeyspaw-backup-") })
            }
        }
    }

    @Test func failedCopyValidationPreservesOlderBackupsAndCleansTheTemporary() async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { database in
                let repository = Fixture(database: database)
                try await repository.seed()
                let old = directory.appendingPathComponent("backups/old.db")
                let first = try await AdminCLITestFixture.run(["backup", old.path], dataDirectory: directory)
                #expect(first.status == 0)
                let bytes = try Data(contentsOf: old)
                try await repository.execute("INSERT INTO schema_migrations VALUES ('999_future_secret', 'future')")
                let next = directory.appendingPathComponent("backups/new.db")
                let failed = try await AdminCLITestFixture.run(["backup", next.path], dataDirectory: directory)
                failed.assertFailure(excluding: ["999_future_secret", next.path])
                #expect(try Data(contentsOf: old) == bytes)
                #expect(try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().path) == ["old.db"])
                _ = try await BackupRepository.validate(old)
            }
        }
    }

    @Test func simultaneousBackupsPublishExactlyOneCompleteFile() async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { database in
                try await Fixture(database: database).seed()
                let file = directory.appendingPathComponent("backups/same.db")
                async let first = AdminCLITestFixture.run(["backup", file.path], dataDirectory: directory)
                async let second = AdminCLITestFixture.run(["backup", file.path], dataDirectory: directory)
                let results = try await [first, second]
                #expect(results.filter { $0.status == 0 }.count == 1)
                let failure = try #require(results.first { $0.status != 0 })
                failure.assertFailure()
                #expect(failure.error.contains(BackupRestoreError.destinationOccupied.description))
                _ = try await BackupRepository.validate(file)
                #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["same.db"])
            }
        }
    }

    @Test func aRunningServeOwnsTheLockAndRestoreSucceedsOnlyAfterItStops() async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { try await Fixture(database: $0).seed() }
            let server = try await BackupTestServer.start(directory: directory)
            defer { server.stop() }
            let file = directory.appendingPathComponent("backups/live.db")
            let backup = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: directory)
            #expect(backup.status == 0 && backup.error.isEmpty)
            let original = try Data(contentsOf: file)
            let refused = try await AdminCLITestFixture.run(["restore", file.path, "--json"], dataDirectory: directory)
            refused.assertFailure(excluding: [file.path])
            #expect(refused.error == "Error: Database is in use. Stop the server and other database commands before restoring.\n")
            #expect(try Data(contentsOf: file) == original)
            server.stop()
            let restored = try await AdminCLITestFixture.run(["restore", file.path], dataDirectory: directory)
            #expect(restored.status == 0 && restored.error.isEmpty)
        }
    }

    @Test func exclusiveMaintenancePreventsNewServerAndDatabaseUsers() async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { try await Fixture(database: $0).seed() }
            let lock = try await acquireExclusiveLockAfterShutdown(directory: directory)
            defer { lock.release() }
            for arguments in [["serve"], ["migrate"], ["backup", directory.appendingPathComponent("blocked.db").path]] {
                let result = try await AdminCLITestFixture.run(arguments, dataDirectory: directory)
                result.assertFailure()
                if arguments[0] == "backup" {
                    #expect(result.error == "Error: Database is in use. Stop the server and other database commands before restoring.\n")
                }
            }
            await #expect(throws: BackupRestoreError.databaseInUse) {
                _ = try await ServerDatabase.open(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path]))
            }
        }
    }

    @Test(arguments: ["shared", "exclusive"])
    func restoreReportsDatabaseInUseForAHeldLock(mode: String) async throws {
        try await withBackupDirectory { directory in
            let lock = try DatabaseFileLock(directory: directory, mode: mode == "shared" ? .shared : .exclusive)
            defer { lock.release() }
            let service = ServerBackupService(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path]))
            let file = directory.appendingPathComponent("backup.db")
            await #expect(throws: BackupRestoreError.databaseInUse) {
                _ = try await service.restore(from: file.path)
            }
            let result = try await AdminCLITestFixture.run(["restore", file.path], dataDirectory: directory)
            result.assertFailure(excluding: [file.path])
            #expect(result.error == "Error: Database is in use. Stop the server and other database commands before restoring.\n")
        }
    }

    @Test(arguments: ["-wal", "-shm", "-journal"])
    func restoreRefusesOrphanedJournalsWithoutDiscardingThem(suffix: String) async throws {
        try await withBackupDirectory { directory in
            let source = directory.appendingPathComponent("source")
            let file = directory.appendingPathComponent("backup.db")
            try await withBackupDatabase(source) { database in
                try await Fixture(database: database).seed()
                let backup = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: source)
                try #require(backup.status == 0 && backup.error.isEmpty)
            }
            let target = directory.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let sidecar = target.appendingPathComponent(ServerLimits.databaseFilename + suffix)
            let journal = Data("orphaned journal recovery bytes".utf8)
            try journal.write(to: sidecar)
            let original = try Data(contentsOf: file)
            let result = try await AdminCLITestFixture.run(["restore", file.path], dataDirectory: target)
            result.assertFailure(excluding: [sidecar.path, "orphaned journal recovery bytes"])
            #expect(result.error == "Error: Database file is missing but journal files remain. Preserve them for recovery and move them aside before restoring.\n")
            #expect(try Data(contentsOf: sidecar) == journal)
            #expect(try Data(contentsOf: file) == original)
            #expect(try !DatabaseFiles.occupied(target.appendingPathComponent(ServerLimits.databaseFilename)))
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).allSatisfy { !$0.hasPrefix(".monkeyspaw-restore-") })
        }
    }

    @Test(arguments: ["non-sqlite", "corrupt", "foreign", "foreign-keys", "application-id", "newer-marker", "newer-version", "directory", "symlink"])
    func restoreRefusesInvalidInputsWithoutChangingTheLiveDatabase(kind: String) async throws {
        try await withBackupDirectory { directory in
            let file = directory.appendingPathComponent("invalid-secret.db")
            let id = try await withBackupDatabase(directory) { database in
                try await Fixture(database: database).seed()
                let result = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: directory)
                #expect(result.status == 0)
                return try await MetaRepository(database: database).databaseID()
            }
            switch kind {
            case "non-sqlite": try Data("secret-body non-sqlite".utf8).write(to: file)
            case "corrupt": try Data("SQLite format 3\0secret-body corrupt".utf8).write(to: file)
            case "foreign":
                try FileManager.default.removeItem(at: file)
                try await editBackup(file, "CREATE TABLE foreign_secret (content TEXT)")
            case "application-id": try await editBackup(file, "PRAGMA application_id = 123456")
            case "foreign-keys": try await editBackup(file, "INSERT INTO groups VALUES ('invalid', 'Fixture', 'missing', 'time', NULL)")
            case "newer-marker": try await editBackup(file, "INSERT INTO schema_migrations VALUES ('999_future_secret', 'future')")
            case "newer-version": try await editBackup(file, "PRAGMA user_version = 999")
            case "directory":
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            default:
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "missing-secret")
            }
            let live = directory.appendingPathComponent(ServerLimits.databaseFilename)
            let original = try Data(contentsOf: live)
            let result = try await AdminCLITestFixture.run(["restore", file.path, "--json"], dataDirectory: directory)
            result.assertFailure(excluding: [file.path, "secret-body", "foreign_secret", "999_future_secret", "missing-secret"])
            if kind.hasPrefix("newer") { #expect(result.error.contains(BackupRestoreError.newerSchema.description)) }
            if kind == "foreign" || kind == "application-id" { #expect(result.error.contains(BackupRestoreError.foreignBackup.description)) }
            #expect(try Data(contentsOf: live) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".monkeyspaw-restore-") })
            try await withBackupDatabase(directory) { (database) async throws -> Void in
                #expect(try await MetaRepository(database: database).databaseID() == id)
                #expect(try await Fixture(database: database).count("users") == 2)
            }
        }
    }

    @Test func restoreMigratesAnOlderFoundationDatabaseAndRotatesItsUUIDDurably() async throws {
        try await withBackupDirectory { directory in
            let source = directory.appendingPathComponent("old-server")
            let file = directory.appendingPathComponent("old-schema.db")
            let oldID = try await withBackupDatabase(source, migrations: [.foundation]) { database in
                try await Fixture(database: database).seed()
                let result = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: source)
                #expect(result.status == 0)
                return try await MetaRepository(database: database).databaseID()
            }
            let target = directory.appendingPathComponent("new-server")
            let result = try await AdminCLITestFixture.run(["restore", file.path, "--json"], dataDirectory: target)
            let metadata = try result.value(BackupMetadata.self)
            #expect(metadata.previousPath == nil && metadata.databaseID != oldID.uuidString)
            for _ in 0..<2 {
                try await withBackupDatabase(target) { database in
                    let repository = Fixture(database: database)
                    #expect(try await MetaRepository(database: database).databaseID().uuidString == metadata.databaseID)
                    #expect(try await repository.count("schema_migrations") == ServerMigration.current.count)
                    #expect(try await repository.count("users") == 2)
                    try await repository.execute("UPDATE users SET display_name = NULL")
                    try await repository.execute("SELECT group_id FROM audit_events")
                }
            }
        }
    }

    @Test(arguments: ["rotation", "migration", "wal-directory"])
    func restoreFailuresPreserveThePreviousDatabaseAndTheBackup(kind: String) async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { try await Fixture(database: $0).seed() }
            let source = directory.appendingPathComponent("source")
            let file = directory.appendingPathComponent("rollback.db")
            try await withBackupDatabase(source, migrations: kind == "migration" ? [.foundation] : ServerMigration.current) { database in
                try await Fixture(database: database).seed()
                let result = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: source)
                #expect(result.status == 0)
            }
            if kind == "rotation" {
                try await editBackup(file, """
                    CREATE TRIGGER reject_rotation BEFORE UPDATE OF database_id ON meta
                    BEGIN SELECT RAISE(ABORT, 'secret-body rotation failure'); END
                    """)
            } else if kind == "migration" {
                try await editBackup(file, "ALTER TABLE audit_events ADD COLUMN group_id TEXT")
            } else {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(ServerLimits.databaseFilename + "-wal"),
                                                        withIntermediateDirectories: false)
            }
            let live = directory.appendingPathComponent(ServerLimits.databaseFilename)
            let original = try Data(contentsOf: live)
            let backupBytes = try Data(contentsOf: file)
            let result = try await AdminCLITestFixture.run(["restore", file.path], dataDirectory: directory)
            result.assertFailure(excluding: [file.path, "secret-body", "reject_rotation", "ALTER TABLE"])
            #expect(try Data(contentsOf: live) == original)
            #expect(try Data(contentsOf: file) == backupBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".monkeyspaw-restore-") })
            if kind == "wal-directory" { try FileManager.default.removeItem(at: directory.appendingPathComponent(ServerLimits.databaseFilename + "-wal")) }
            try await withBackupDatabase(directory) { (database) async throws -> Void in
                #expect(try await Fixture(database: database).count("users") == 2)
            }
        }
    }

    @Test func restoreCheckpointsTheCrashedServersWALBeforePreservingThePreviousDatabase() async throws {
        try await withBackupDirectory { directory in
            try await withBackupDatabase(directory) { try await Fixture(database: $0).seed() }
            let file = directory.appendingPathComponent("before-crash.db")
            let initial = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: directory)
            #expect(initial.status == 0)
            let server = try await BackupTestServer.start(directory: directory)
            defer { server.stop() }
            // The serve connection keeps WAL resident after this separate writer closes.
            try await editBackup(directory.appendingPathComponent(ServerLimits.databaseFilename),
                                 "UPDATE users SET display_name = 'committed before crash'")
            let wal = directory.appendingPathComponent(ServerLimits.databaseFilename + "-wal")
            #expect(try Data(contentsOf: wal).count > 0)
            server.crash()
            let result = try await AdminCLITestFixture.run(["restore", file.path, "--json"], dataDirectory: directory)
            let metadata = try result.value(BackupMetadata.self)
            #expect(!FileManager.default.fileExists(atPath: wal.path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(ServerLimits.databaseFilename + "-shm").path))
            let previous = URL(fileURLWithPath: try #require(metadata.previousPath))
            let recovery = directory.appendingPathComponent("verify-crashed-previous")
            let recovered = try await AdminCLITestFixture.run(["restore", previous.path], dataDirectory: recovery)
            #expect(recovered.status == 0 && recovered.error.isEmpty)
            try await withBackupDatabase(recovery) { (database) async throws -> Void in
                #expect(try await Fixture(database: database).string("SELECT display_name FROM users LIMIT 1", column: "display_name") == "committed before crash")
            }
            try await withBackupDatabase(directory) { (database) async throws -> Void in
                #expect(try await Fixture(database: database).string("SELECT display_name FROM users LIMIT 1", column: "display_name") == "Fixture")
            }
        }
    }

    @Test(arguments: ["non-sqlite", "truncated"])
    func restoreReplacesADamagedStandaloneDatabaseAndRetainsItsBytes(kind: String) async throws {
        try await withBackupDirectory { directory in
            let file = directory.appendingPathComponent("healthy-backup.db")
            let oldID = try await withBackupDatabase(directory) { database in
                try await Fixture(database: database).seed()
                let result = try await AdminCLITestFixture.run(["backup", file.path], dataDirectory: directory)
                #expect(result.status == 0)
                return try await MetaRepository(database: database).databaseID()
            }
            let live = directory.appendingPathComponent(ServerLimits.databaseFilename)
            let damaged = kind == "truncated" ? Data(try Data(contentsOf: live).prefix(100)) : Data("damaged database".utf8)
            try damaged.write(to: live)
            let result = try await AdminCLITestFixture.run(["restore", file.path, "--json"], dataDirectory: directory)
            let metadata = try result.value(BackupMetadata.self)
            let previous = URL(fileURLWithPath: try #require(metadata.previousPath))
            #expect(try Data(contentsOf: previous) == damaged)
            #expect(metadata.databaseID != oldID.uuidString)
            try await withBackupDatabase(directory) { (database) async throws -> Void in
                #expect(try await Fixture(database: database).count("users") == 2)
                #expect(try await MetaRepository(database: database).databaseID().uuidString == metadata.databaseID)
            }
        }
    }
}
