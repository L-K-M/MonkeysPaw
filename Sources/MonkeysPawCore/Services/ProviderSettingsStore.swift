import Foundation

/// A config-root FileStore, alongside SettingsStore, owns provider-settings.json.
/// Share one instance per root. The lock serializes metadata and the service's
/// secret mutation/rollback. Unknown JSON stays internal and follows profile IDs.
/// Callbacks run under a non-recursive lock and must not re-enter this store.
public final class ProviderSettingsStore: @unchecked Sendable {
    private struct Payload: Decodable {
        let version: Int
        let profiles: [ProfilePayload]
        let selectedProfileID: ProviderProfileID?
    }

    private struct ProfilePayload: Decodable {
        let id: ProviderProfileID
        let displayName: String
        let kind: ProviderKind
        let baseURL: String
        let modelID: String
        let secretReference: SecretAccount?

        func profile() throws -> ProviderProfile {
            try ProviderProfile(id: id, displayName: displayName, kind: kind, baseURL: baseURL,
                                modelID: modelID, secretReference: secretReference)
        }
    }

    private struct Loaded {
        let settings: ProviderSettings
        let object: [String: Any]
        let needsRewrite: Bool
    }

    private let files: FileStore
    private let log: LogSink?
    private let loader = SettingsLoader(currentVersion: ProviderSettings.currentVersion, migrations: [])
    private let lock = NSLock()
    private let path = "provider-settings.json"
    private var cached = ProviderSettingsSnapshot(settings: try! ProviderSettings(), readOnlyError: nil)

    public init(files: FileStore, log: LogSink? = nil) {
        self.files = files
        self.log = log
        do { cached = ProviderSettingsSnapshot(settings: try read().settings, readOnlyError: nil) }
        catch { failClosed(error) }
    }

    var snapshot: ProviderSettingsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Revalidate disk metadata before handing credentials to an outbound call.
    func withSettings<T>(_ body: (ProviderSettings) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        cached = ProviderSettingsSnapshot(settings: loaded.settings, readOnlyError: nil)
        return try body(loaded.settings)
    }

    /// Secret operations run inside the same lock as validation and publication.
    /// Compensate a successful secret edit if metadata cannot commit. FileStore
    /// has no compare-and-swap, so external writers can still race read/write.
    func update(_ change: (ProviderSettings) throws -> ProviderSettings,
                rollback: () throws -> Void = {}) throws {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        do {
            let next = try change(loaded.settings)
            if next != loaded.settings || loaded.needsRewrite {
                try write(next, preserving: loaded.object)
            }
            cached = ProviderSettingsSnapshot(settings: next, readOnlyError: nil)
        } catch {
            do { try rollback() }
            catch {
                cached = ProviderSettingsSnapshot(settings: loaded.settings, readOnlyError: .secretRollbackFailed)
                log?.write(.error, "Provider secret restoration failed.")
                throw ProviderSettingsError.secretRollbackFailed
            }
            throw error
        }
    }

    private func loadCurrent() throws -> Loaded {
        if let error = cached.readOnlyError { throw error }
        do { return try read() }
        catch { throw failClosed(error) }
    }

    private func read() throws -> Loaded {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound {
            return Loaded(settings: try ProviderSettings(), object: [:], needsRewrite: true)
        }
        catch let error as FileStoreError { throw ProviderSettingsError.readFailed(error) }
        catch { throw ProviderSettingsError.readFailed(.ioFailure) }

        let object: [String: Any]
        do { object = try loader.load(bytes).object }
        catch SettingsError.futureVersion(let version) { throw ProviderSettingsError.futureVersion(version) }
        catch SettingsError.unsupportedVersion(let version) { throw ProviderSettingsError.unsupportedVersion(version) }
        catch { throw ProviderSettingsError.corruptFile }

        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == ProviderSettings.currentVersion else { throw ProviderSettingsError.corruptFile }
            let settings = try ProviderSettings(profiles: payload.profiles.map { try $0.profile() },
                                                selectedProfileID: payload.selectedProfileID)
            return Loaded(settings: settings, object: object, needsRewrite: false)
        } catch { throw ProviderSettingsError.corruptFile }
    }

    private func write(_ settings: ProviderSettings, preserving original: [String: Any]) throws {
        var object = original
        let originals = original["profiles"] as? [[String: Any]] ?? []
        var profiles = [[String: Any]]()
        for profile in settings.profiles {
            var value = originals.first(where: {
                ($0["id"] as? String).flatMap(UUID.init(uuidString:)).map(ProviderProfileID.init) == profile.id
            }) ?? [:]
            value["id"] = profile.id.rawValue
            value["displayName"] = profile.displayName
            value["kind"] = profile.kind.rawValue
            value["baseURL"] = profile.baseURL.absoluteString
            value["modelID"] = profile.modelID
            value["secretReference"] = profile.secretReference?.rawValue as Any? ?? NSNull()
            profiles.append(value)
        }
        object["version"] = settings.version
        object["profiles"] = profiles
        object["selectedProfileID"] = settings.selectedProfileID?.rawValue as Any? ?? NSNull()
        do {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try files.write(bytes, at: path)
        } catch let error as FileStoreError {
            log?.write(.warning, "Provider settings write failed.")
            throw ProviderSettingsError.writeFailed(error)
        } catch {
            log?.write(.warning, "Provider settings write failed.")
            throw ProviderSettingsError.writeFailed(.ioFailure)
        }
    }

    /// One-way, as in SettingsStore: never overwrite unreadable/unknown state.
    @discardableResult
    private func failClosed(_ error: Error) -> ProviderSettingsError {
        let sanitized = error as? ProviderSettingsError ?? .readFailed(.ioFailure)
        cached = ProviderSettingsSnapshot(settings: try! ProviderSettings(), readOnlyError: sanitized)
        log?.write(.warning, "Provider settings read failed; settings are read-only.")
        return sanitized
    }
}
