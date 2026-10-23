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
    // UI snapshots must not wait behind a native secret prompt under lock.
    private let snapshotLock = NSLock()
    private let observerLock = NSLock()
    private var changeObservers: [UUID: @Sendable () -> Void] = [:]
    private let path = "provider-settings.json"
    private var cached = ProviderSettingsSnapshot(settings: try! ProviderSettings(), readOnlyError: nil)

    public init(files: FileStore, log: LogSink? = nil) {
        self.files = files
        self.log = log
        do { publish(ProviderSettingsSnapshot(settings: try read().settings, readOnlyError: nil)) }
        catch { failClosed(error) }
    }

    var snapshot: ProviderSettingsSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return cached
    }

    private func publish(_ snapshot: ProviderSettingsSnapshot) {
        snapshotLock.lock()
        cached = snapshot
        snapshotLock.unlock()
    }

    /// Revalidate disk metadata before handing credentials to an outbound call.
    func withSettings<T>(_ body: (ProviderSettings) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        publish(ProviderSettingsSnapshot(settings: loaded.settings, readOnlyError: nil))
        return try body(loaded.settings)
    }

    /// §26 S10: successful updates and remote applies notify; the observer is
    /// invoked after the store lock is released.
    @discardableResult public func observe(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observerLock.lock()
        changeObservers[id] = observer
        observerLock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        observerLock.lock()
        changeObservers[id] = nil
        observerLock.unlock()
    }

    private func notifyChanged() {
        observerLock.lock()
        let observers = Array(changeObservers.values)
        observerLock.unlock()
        for observer in observers { observer() }
    }

    /// The raw stored object alongside the validated settings, under the lock.
    /// A missing file exports an empty object; callers substitute the default.
    func withDocument<T>(_ body: ([String: Any], ProviderSettings) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        publish(ProviderSettingsSnapshot(settings: loaded.settings, readOnlyError: nil))
        return try body(loaded.object, loaded.settings)
    }

    /// §26 S7: the mutation runs while local settings are still installed; the
    /// verbatim remote object then commits under the same lock. Secret edits
    /// inside the mutation are compensated through `rollback` on any failure,
    /// so a rejected commit cannot strand the secret store.
    func applySynced(_ object: [String: Any],
                     mutate: (ProviderSettings, ProviderSettings) throws -> Void,
                     rollback: () throws -> Void = {}) throws {
        var committed = false
        lock.lock()
        defer {
            lock.unlock()
            if committed { notifyChanged() }
        }
        let loaded = try loadCurrent()
        let parsed = try settings(from: object)
        do {
            try mutate(loaded.settings, parsed)
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try files.write(bytes, at: path)
        } catch {
            do { try rollback() }
            catch {
                publish(ProviderSettingsSnapshot(settings: loaded.settings, readOnlyError: .secretRollbackFailed))
                log?.write(.error, "Provider secret restoration failed.")
                throw ProviderSettingsError.secretRollbackFailed
            }
            if let error = error as? ProviderSettingsError { throw error }
            log?.write(.warning, "Provider settings write failed.")
            throw ProviderSettingsError.writeFailed(error as? FileStoreError ?? .ioFailure)
        }
        publish(ProviderSettingsSnapshot(settings: parsed, readOnlyError: nil))
        committed = true
    }

    /// Secret operations run inside the same lock as validation and publication.
    /// Compensate a successful secret edit if metadata cannot commit. FileStore
    /// has no compare-and-swap, so external writers can still race read/write.
    func update(_ change: (ProviderSettings) throws -> ProviderSettings,
                rollback: () throws -> Void = {}) throws {
        var committed = false
        lock.lock()
        defer {
            lock.unlock()
            if committed { notifyChanged() }
        }
        let loaded = try loadCurrent()
        do {
            let next = try change(loaded.settings)
            if next != loaded.settings || loaded.needsRewrite {
                try write(next, preserving: loaded.object)
            }
            publish(ProviderSettingsSnapshot(settings: next, readOnlyError: nil))
            committed = next != loaded.settings || loaded.needsRewrite
        } catch {
            do { try rollback() }
            catch {
                publish(ProviderSettingsSnapshot(settings: loaded.settings, readOnlyError: .secretRollbackFailed))
                log?.write(.error, "Provider secret restoration failed.")
                throw ProviderSettingsError.secretRollbackFailed
            }
            throw error
        }
    }

    private func loadCurrent() throws -> Loaded {
        if let error = snapshot.readOnlyError { throw error }
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
            return Loaded(settings: try settings(from: object), object: object, needsRewrite: false)
        } catch { throw ProviderSettingsError.corruptFile }
    }

    /// The same strict decode the file path applies, over any parsed object.
    private func settings(from object: [String: Any]) throws -> ProviderSettings {
        let data = try JSONSerialization.data(withJSONObject: object)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == ProviderSettings.currentVersion else { throw ProviderSettingsError.corruptFile }
        return try ProviderSettings(profiles: payload.profiles.map { try $0.profile() },
                                    selectedProfileID: payload.selectedProfileID)
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
        publish(ProviderSettingsSnapshot(settings: try! ProviderSettings(), readOnlyError: sanitized))
        log?.write(.warning, "Provider settings read failed; settings are read-only.")
        return sanitized
    }
}
