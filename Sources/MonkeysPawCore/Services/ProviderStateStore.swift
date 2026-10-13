import Foundation

/// Share one store per config root, beside ProviderSettingsStore. The lock owns
/// all file access and observed identities; no credential or provider body enters it.
public final class ProviderStateStore: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private struct Payload: Decodable {
        let version: Int
        let profiles: [Entry]
    }

    private struct Entry: Decodable {
        let id: ProviderProfileID
        let kind: ProviderKind
        let baseURL: String
        let modelID: String
        let format: OpenAIResponseFormat

        func key() throws -> ProviderCacheKey {
            guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw SettingsError.corruptFile
            }
            return ProviderCacheKey(profileID: id, kind: kind,
                baseURL: try ProviderSettings.normalizeBaseURL(baseURL, kind: kind), modelID: modelID)
        }
    }

    private struct Loaded {
        // Nil entries mean readable corruption; keep parsed metadata for repair.
        let entries: [Entry]?
        let object: [String: Any]
    }

    private static let currentVersion = 1
    private let files: FileStore
    private let lock = NSLock()
    private let path = "provider-state.json"
    private var observedKeys = [ProviderProfileID: ProviderCacheKey]()
    private var pendingResets = [ProviderProfileID: ProviderCacheKey]()

    public init(files: FileStore) {
        self.files = files
    }

    func format(for connection: ProviderConnection) throws -> OpenAIResponseFormat {
        lock.lock()
        defer { lock.unlock() }
        let key = try key(for: connection)
        if let previous = observedKeys.updateValue(key, forKey: key.profileID), previous != key {
            pendingResets[key.profileID] = previous
        }
        let loaded: Loaded
        do { loaded = try read() }
        catch {
            StandardErrorLog().write(.warning, "Provider capability cache read failed.")
            return .jsonSchema
        }
        guard let entry = loaded.entries?.first(where: { $0.id == key.profileID }) else { return .jsonSchema }
        let cachedKey = try entry.key()
        if cachedKey == key, pendingResets[key.profileID] == nil { return entry.format }

        // Invalidate on identity changes, including a later return to the old
        // model. Preserve future metadata associated with the stable profile ID.
        pendingResets[key.profileID] = cachedKey
        do {
            try write(.jsonSchema, for: key, preserving: loaded)
            pendingResets.removeValue(forKey: key.profileID)
        } catch { StandardErrorLog().write(.warning, "Provider capability cache reset failed.") }
        return .jsonSchema
    }

    /// Called only after a probed lower format produces a validated response.
    func recordSuccess(_ format: OpenAIResponseFormat, for connection: ProviderConnection) throws {
        lock.lock()
        defer { lock.unlock() }
        // An unreadable file cannot safely be replaced; retry on the next action.
        let loaded = try read()
        let key = try key(for: connection)
        // An older in-flight action must not restore a different observed model.
        guard observedKeys[key.profileID] == key else { return }
        if let entry = loaded.entries?.first(where: { $0.id == key.profileID }) {
            let cachedKey = try entry.key()
            let resetPending = cachedKey != key && pendingResets[key.profileID] == cachedKey
            guard cachedKey == key || resetPending else { return }
            // Out-of-order successes must not forget an already learned rejection.
            if !resetPending, entry.format == .none || entry.format == format { return }
        }
        try write(format, for: key, preserving: loaded)
        pendingResets.removeValue(forKey: key.profileID)
    }

    private func key(for connection: ProviderConnection) throws -> ProviderCacheKey {
        do {
            return ProviderCacheKey(profileID: connection.profileID, kind: connection.kind,
                baseURL: try ProviderSettings.normalizeBaseURL(connection.baseURL.absoluteString, kind: connection.kind),
                modelID: connection.modelID)
        } catch { throw SettingsError.corruptFile }
    }

    private func read() throws -> Loaded {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound { return Loaded(entries: [], object: [:]) }
        catch let error as FileStoreError { throw SettingsError.readFailed(error) }
        catch { throw SettingsError.readFailed(.ioFailure) }

        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: bytes)
            guard payload.version == Self.currentVersion,
                  Set(payload.profiles.map(\.id)).count == payload.profiles.count else { throw SettingsError.corruptFile }
            for entry in payload.profiles { _ = try entry.key() }
            return Loaded(entries: payload.profiles, object: object)
        } catch { return Loaded(entries: nil, object: object) }
    }

    private func write(_ format: OpenAIResponseFormat, for key: ProviderCacheKey,
                       preserving loaded: Loaded) throws {
        var object = loaded.object
        let originalProfiles = (object["profiles"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        var profiles = loaded.entries == nil ? [] : originalProfiles
        let index = originalProfiles.firstIndex {
            ($0["id"] as? String).flatMap(UUID.init(uuidString:)).map(ProviderProfileID.init) == key.profileID
        }
        var entry = index.map { originalProfiles[$0] } ?? [:]
        entry["id"] = key.profileID.rawValue
        entry["kind"] = key.kind.rawValue
        entry["baseURL"] = key.baseURL.absoluteString
        entry["modelID"] = key.modelID
        entry["format"] = format.rawValue
        if let index, loaded.entries != nil { profiles[index] = entry }
        else { profiles.append(entry) }
        object["version"] = Self.currentVersion
        object["profiles"] = profiles
        do {
            try files.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: path)
        } catch let error as FileStoreError { throw SettingsError.writeFailed(error) }
        catch { throw SettingsError.writeFailed(.ioFailure) }
    }

    public var description: String { "<provider capability state>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
