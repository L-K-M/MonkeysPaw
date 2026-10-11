import Foundation

/// Sorted-key settings.json over a dedicated config-root FileStore (§5.1).
/// Share one instance per root. Its lock owns the cached value, error and all
/// file access. Unknown JSON keys remain internal, outside SettingsDocument.
public final class SettingsStore: @unchecked Sendable {
    private struct Payload: Decodable {
        let version: Int
        let libraryFolderPath: String?
        let firstRun: FirstRunProgress
    }

    private struct Loaded {
        let document: SettingsDocument
        let object: [String: Any]
        let needsRewrite: Bool
    }

    private let files: FileStore
    private let legacyFirstRun: LegacyFirstRun
    private let loader: SettingsLoader
    private let lock = NSLock()
    private let path = "settings.json"
    private var cached = SettingsSnapshot(document: SettingsDocument(), readOnlyError: nil)

    public convenience init(files: FileStore, legacyFirstRun: LegacyFirstRun = .setupNotPresented) {
        self.init(files: files, legacyFirstRun: legacyFirstRun, migrations: [])
    }

    // The internal seam proves migration chains using synthetic unshipped shapes.
    init(files: FileStore, legacyFirstRun: LegacyFirstRun = .setupNotPresented,
         migrations: [SettingsMigration]) {
        self.files = files
        self.legacyFirstRun = legacyFirstRun
        loader = SettingsLoader(currentVersion: SettingsDocument.currentVersion, migrations: migrations)
        do {
            cached = SettingsSnapshot(document: try read().document, readOnlyError: nil)
        } catch {
            failClosed(error)
        }
    }

    var snapshot: SettingsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Publish only after atomic replacement succeeds. Reread before changing
    /// anything so a file replaced by a newer app during this run is protected.
    func update(_ change: (SettingsDocument) throws -> SettingsDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = cached.readOnlyError { throw error }

        let loaded: Loaded
        do { loaded = try read() }
        catch { throw failClosed(error) }

        let next = try change(loaded.document)
        if next != loaded.document || loaded.needsRewrite {
            try write(next, preserving: loaded.object)
        }
        cached = SettingsSnapshot(document: next, readOnlyError: nil)
    }

    private func read() throws -> Loaded {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound {
            let progress = FirstRunProgress(setupPresented: legacyFirstRun == .setupPresented)
            let defaults = try SettingsDocument(libraryFolderPath: nil, firstRun: progress)
            return Loaded(document: defaults, object: [:], needsRewrite: true)
        }
        catch let error as FileStoreError { throw SettingsError.readFailed(error) }
        catch { throw SettingsError.readFailed(.ioFailure) }

        let object = try loader.load(bytes)
        do {
            let normalized = try JSONSerialization.data(withJSONObject: object)
            let payload = try JSONDecoder().decode(Payload.self, from: normalized)
            guard payload.version == SettingsDocument.currentVersion else { throw SettingsError.corruptFile }
            let document = try SettingsDocument(libraryFolderPath: payload.libraryFolderPath,
                                                firstRun: payload.firstRun)
            let originalVersion = try JSONDecoder().decode(SettingsVersion.self, from: bytes).version
            return Loaded(document: document, object: object,
                          needsRewrite: originalVersion != SettingsDocument.currentVersion)
        } catch { throw SettingsError.corruptFile }
    }

    private func write(_ document: SettingsDocument, preserving original: [String: Any]) throws {
        var object = original
        var progress = object["firstRun"] as? [String: Any] ?? [:]
        progress["setupPresented"] = document.firstRun.setupPresented
        progress["libraryFolderCompleted"] = document.firstRun.libraryFolderCompleted
        progress["seedsOffered"] = document.firstRun.seedsOffered
        object["firstRun"] = progress
        object["libraryFolderPath"] = document.libraryFolderPath.map { $0 as Any } ?? NSNull()
        object["version"] = document.version

        do {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try files.write(bytes, at: path)
        } catch let error as FileStoreError { throw SettingsError.writeFailed(error) }
        catch { throw SettingsError.writeFailed(.ioFailure) }
    }

    @discardableResult
    private func failClosed(_ error: Error) -> SettingsError {
        let sanitized = error as? SettingsError ?? .readFailed(.ioFailure)
        cached = SettingsSnapshot(document: SettingsDocument(), readOnlyError: sanitized)
        return sanitized
    }
}

private struct SettingsVersion: Decodable {
    let version: Int
}

/// Each migration advances exactly one version; no pre-v1 schema was shipped.
/// Future additions belong here rather than in separate loader special cases.
struct SettingsMigration {
    let fromVersion: Int
    let transform: ([String: Any]) throws -> [String: Any]
}

struct SettingsLoader {
    let currentVersion: Int
    let migrations: [SettingsMigration]

    func load(_ bytes: Data) throws -> [String: Any] {
        do {
            let version = try JSONDecoder().decode(SettingsVersion.self, from: bytes).version
            guard version <= currentVersion else { throw SettingsError.futureVersion(version) }
            guard version >= 0 else { throw SettingsError.unsupportedVersion(version) }
            guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw SettingsError.corruptFile
            }

            for olderVersion in version..<currentVersion {
                guard let migration = migrations.first(where: { $0.fromVersion == olderVersion }) else {
                    throw SettingsError.unsupportedVersion(olderVersion)
                }
                object = try migration.transform(object)
                object["version"] = olderVersion + 1
            }
            return object
        } catch let error as SettingsError { throw error }
        catch { throw SettingsError.corruptFile }
    }
}
