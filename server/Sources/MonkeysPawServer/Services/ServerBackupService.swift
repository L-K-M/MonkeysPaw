import Foundation

/// Operator-only maintenance; all SQL and connection work remains in persistence.
public struct ServerBackupService: Sendable {
    private let configuration: DatabaseConfiguration

    public init(configuration: DatabaseConfiguration) {
        self.configuration = configuration
    }

    public func backup(to path: String) async throws -> DatabaseBackupResult {
        do {
            let destination = try DatabaseFiles.url(path)
            guard try !DatabaseFiles.occupied(destination) else { throw BackupRestoreError.destinationOccupied }
            try DatabaseFiles.checkHeader(URL(fileURLWithPath: configuration.databasePath))
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = parent.appendingPathComponent(".monkeyspaw-backup-\(UUID().uuidString)")
            try DatabaseFiles.createEmpty(temporary)
            defer {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? FileManager.default.removeItem(atPath: temporary.path + suffix)
                }
            }
            let database = try await ServerDatabase.open(configuration: configuration)
            do {
                try await BackupRepository(database: database).vacuum(into: temporary)
                await database.shutdown()
            } catch {
                await database.shutdown()
                throw error
            }
            let id = try await BackupRepository.validate(temporary)
            try Task.checkCancellation()
            try DatabaseFiles.sync(temporary)
            try DatabaseFiles.publish(temporary, to: destination)
            return .init(path: destination.path, databaseID: id.uuidString, previousPath: nil)
        } catch {
            throw (error as? BackupRestoreError) ?? .failed
        }
    }

    public func restore(from path: String) async throws -> DatabaseBackupResult {
        do {
            let lock = try DatabaseFileLock(directory: configuration.dataDirectory, mode: .exclusive)
            defer { lock.release() }
            let input = try DatabaseFiles.url(path)
            let live = URL(fileURLWithPath: configuration.databasePath)
            guard input != live else { throw BackupRestoreError.invalidBackup }
            let directory = configuration.dataDirectory.appendingPathComponent(".monkeyspaw-restore-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let staged = directory.appendingPathComponent(ServerLimits.databaseFilename)
            try DatabaseFiles.createEmpty(staged)
            try await BackupRepository.stage(input, into: staged)
            let stagedConfiguration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
            let id = try await ServerDatabase.withMigratedDatabase(configuration: stagedConfiguration) { database in
                let repository = BackupRepository(database: database)
                let id = try await repository.rotateIdentity()
                try await repository.checkpoint()
                return id
            }
            guard try await BackupRepository.validate(staged) == id else { throw BackupRestoreError.failed }
            try DatabaseFiles.sync(staged)
            try Task.checkCancellation()

            var previous: URL?
            let hasPrevious = try DatabaseFiles.occupied(live)
            if hasPrevious {
                try await BackupRepository.preparePrevious(live)
            }
            // Orphaned journals may hold recovery pages; never discard them or pair them with the replacement.
            for suffix in ["-wal", "-shm", "-journal"] {
                guard try !DatabaseFiles.occupied(URL(fileURLWithPath: live.path + suffix)) else {
                    throw hasPrevious ? BackupRestoreError.failed : .orphanedJournals
                }
            }
            if hasPrevious {
                let recovery = configuration.dataDirectory.appendingPathComponent("monkeyspaw.pre-restore-\(UUID().uuidString).db")
                try DatabaseFiles.preserve(live, at: recovery)
                previous = recovery
            }
            try DatabaseFiles.replace(live, with: staged)
            return .init(path: live.path, databaseID: id.uuidString, previousPath: previous?.path)
        } catch {
            throw (error as? BackupRestoreError) ?? .failed
        }
    }
}

public struct DatabaseBackupResult: Sendable, Encodable {
    public let path: String
    public let databaseID: String
    public let previousPath: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case databaseID = "database_id"
        case previousPath = "previous_path"
    }
}

public enum BackupRestoreError: Error, CustomStringConvertible {
    case databaseInUse, destinationOccupied, invalidBackup, foreignBackup, newerSchema, orphanedJournals, failed

    public var description: String {
        switch self {
        case .databaseInUse: return "Database is in use. Stop the server and other database commands before restoring."
        case .destinationOccupied: return "Backup destination is occupied. Choose a new path."
        case .invalidBackup: return "Backup must be a regular, valid SQLite database."
        case .foreignBackup: return "Backup is not a Monkey's Paw database."
        case .newerSchema: return "Backup schema is not supported by this server version."
        case .orphanedJournals: return "Database file is missing but journal files remain. Preserve them for recovery and move them aside before restoring."
        case .failed: return "Database backup or restore failed."
        }
    }
}
