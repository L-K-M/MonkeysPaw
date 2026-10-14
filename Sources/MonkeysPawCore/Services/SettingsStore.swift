import Foundation

/// Sorted-key settings.json over a dedicated config-root FileStore (§5.1).
/// Share one instance per root. Its lock owns the cached value, error and all
/// file access. Unknown JSON keys remain internal, outside SettingsDocument.
public final class SettingsStore: @unchecked Sendable {
    private struct Payload: Decodable {
        let version: Int
        let libraryFolderPath: String?
        let firstRun: FirstRunProgress
        let delivery: DeliveryPreferences
        let automaticUpdateChecks: AutomaticUpdateChecks
        let carbonShortcuts: CarbonShortcutChoices
        let readOnlyError: SettingsError?

        private enum CodingKeys: String, CodingKey {
            case version, libraryFolderPath, firstRun, delivery, automaticUpdateChecks, carbonShortcuts
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            libraryFolderPath = try values.decodeIfPresent(String.self, forKey: .libraryFolderPath)
            firstRun = try values.decode(FirstRunProgress.self, forKey: .firstRun)
            delivery = values.contains(.delivery)
                ? try values.decode(DeliveryPreferences.self, forKey: .delivery) : DeliveryPreferences()
            automaticUpdateChecks = values.contains(.automaticUpdateChecks)
                ? try values.decode(AutomaticUpdateChecks.self, forKey: .automaticUpdateChecks) : .enabled
            do {
                carbonShortcuts = values.contains(.carbonShortcuts)
                    ? try values.decode(CarbonShortcutChoices.self, forKey: .carbonShortcuts) : CarbonShortcutChoices()
                readOnlyError = nil
            } catch {
                // Invalid optional choices forbid writes, without hiding the
                // library and onboarding settings decoded above.
                carbonShortcuts = CarbonShortcutChoices()
                readOnlyError = .corruptFile
            }
        }
    }

    private struct Loaded {
        let document: SettingsDocument
        let object: [String: Any]
        let needsRewrite: Bool
        let readOnlyError: SettingsError?
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
            let loaded = try read()
            cached = SettingsSnapshot(document: loaded.document, readOnlyError: loaded.readOnlyError)
        } catch {
            failClosed(error)
        }
    }

    var snapshot: SettingsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Publish only after atomic replacement succeeds. Reread before each
    /// change to reject newer or corrupt settings already on disk. A replacement
    /// between that read and the write can still be overwritten; FileStore has
    /// no compare-and-swap.
    func update(_ change: (SettingsDocument) throws -> SettingsDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = cached.readOnlyError { throw error }

        let loaded: Loaded
        do { loaded = try read() }
        catch { throw failClosed(error) }
        if let error = loaded.readOnlyError {
            cached = SettingsSnapshot(document: loaded.document, readOnlyError: error)
            throw error
        }

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
            let alreadyInstalled = legacyFirstRun == .setupPresented
            let progress = FirstRunProgress(setupPresented: alreadyInstalled, tourCompleted: alreadyInstalled)
            let defaults = try SettingsDocument(libraryFolderPath: nil, firstRun: progress)
            return Loaded(document: defaults, object: [:], needsRewrite: true, readOnlyError: nil)
        }
        catch let error as FileStoreError { throw SettingsError.readFailed(error) }
        catch { throw SettingsError.readFailed(.ioFailure) }

        let (object, sourceVersion) = try loader.load(bytes)
        do {
            let normalized = try JSONSerialization.data(withJSONObject: object)
            let payload = try JSONDecoder().decode(Payload.self, from: normalized)
            guard payload.version == SettingsDocument.currentVersion else { throw SettingsError.corruptFile }
            let document = try SettingsDocument(libraryFolderPath: payload.libraryFolderPath,
                firstRun: payload.firstRun, delivery: payload.delivery,
                automaticUpdateChecks: payload.automaticUpdateChecks, carbonShortcuts: payload.carbonShortcuts)
            return Loaded(document: document, object: object,
                          needsRewrite: sourceVersion != SettingsDocument.currentVersion,
                          readOnlyError: payload.readOnlyError)
        } catch { throw SettingsError.corruptFile }
    }

    private func write(_ document: SettingsDocument, preserving original: [String: Any]) throws {
        var object = original
        var progress = object["firstRun"] as? [String: Any] ?? [:]
        progress["setupPresented"] = document.firstRun.setupPresented
        progress["libraryFolderCompleted"] = document.firstRun.libraryFolderCompleted
        progress["seedsOffered"] = document.firstRun.seedsOffered
        progress["tourCompleted"] = document.firstRun.tourCompleted
        object["firstRun"] = progress
        var delivery = object["delivery"] as? [String: Any] ?? [:]
        delivery["linuxDefaultPasteChord"] = document.delivery.linuxDefaultPasteChord.rawValue
        delivery["clipboardRestore"] = document.delivery.clipboardRestore.rawValue
        object["delivery"] = delivery
        object["automaticUpdateChecks"] = document.automaticUpdateChecks.rawValue
        var shortcuts = object["carbonShortcuts"] as? [String: Any] ?? [:]
        shortcuts["togglePicker"] = document.carbonShortcuts.togglePicker.map { $0.settingsText as Any } ?? NSNull()
        shortcuts["repeatLast"] = document.carbonShortcuts.repeatLast.map { $0.settingsText as Any } ?? NSNull()
        object["carbonShortcuts"] = shortcuts
        object["libraryFolderPath"] = document.libraryFolderPath.map { $0 as Any } ?? NSNull()
        object["version"] = document.version

        do {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try files.write(bytes, at: path)
        } catch let error as FileStoreError { throw SettingsError.writeFailed(error) }
        catch { throw SettingsError.writeFailed(.ioFailure) }
    }

    // A load/read failure is deliberately one-way for this instance: it stays
    // read-only until the app restarts or composition creates a new store.
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

    func load(_ bytes: Data) throws -> (object: [String: Any], sourceVersion: Int) {
        do {
            let sourceVersion = try JSONDecoder().decode(SettingsVersion.self, from: bytes).version
            guard sourceVersion <= currentVersion else { throw SettingsError.futureVersion(sourceVersion) }
            guard sourceVersion >= 0 else { throw SettingsError.unsupportedVersion(sourceVersion) }
            guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw SettingsError.corruptFile
            }

            for olderVersion in sourceVersion..<currentVersion {
                guard let migration = migrations.first(where: { $0.fromVersion == olderVersion }) else {
                    throw SettingsError.unsupportedVersion(olderVersion)
                }
                object = try migration.transform(object)
                object["version"] = olderVersion + 1
            }
            return (object, sourceVersion)
        } catch let error as SettingsError { throw error }
        catch { throw SettingsError.corruptFile }
    }
}
