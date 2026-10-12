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
        let entries: [Entry]
        let object: [String: Any]
    }

    private static let currentVersion = 1
    private let files: FileStore
    private let loader = SettingsLoader(currentVersion: currentVersion, migrations: [])
    private let lock = NSLock()
    private let path = "provider-state.json"
    private var readOnlyError: SettingsError?
    private var observedKeys = [ProviderProfileID: ProviderCacheKey]()

    public init(files: FileStore) {
        self.files = files
        do { _ = try read() }
        catch { readOnlyError = sanitized(error) }
    }

    func format(for connection: ProviderConnection) throws -> OpenAIResponseFormat {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        let key = try key(for: connection)
        observedKeys[key.profileID] = key
        guard let entry = loaded.entries.first(where: { $0.id == key.profileID }) else { return .jsonSchema }
        if try entry.key() == key { return entry.format }

        // Invalidate on identity changes, including a later return to the old
        // model. Preserve future metadata associated with the stable profile ID.
        try write(.jsonSchema, for: key, preserving: loaded.object)
        return .jsonSchema
    }

    /// Called only after a probed lower format produces a validated response.
    func recordSuccess(_ format: OpenAIResponseFormat, for connection: ProviderConnection) throws {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        let key = try key(for: connection)
        // An older in-flight action must not restore a different observed model.
        guard observedKeys[key.profileID] == key else { return }
        if let entry = loaded.entries.first(where: { $0.id == key.profileID }) {
            guard try entry.key() == key else { return }
            // Out-of-order successes must not forget an already learned rejection.
            if entry.format == .none || entry.format == format { return }
        }
        try write(format, for: key, preserving: loaded.object)
    }

    private func key(for connection: ProviderConnection) throws -> ProviderCacheKey {
        do {
            return ProviderCacheKey(profileID: connection.profileID, kind: connection.kind,
                baseURL: try ProviderSettings.normalizeBaseURL(connection.baseURL.absoluteString, kind: connection.kind),
                modelID: connection.modelID)
        } catch { throw SettingsError.corruptFile }
    }

    private func loadCurrent() throws -> Loaded {
        if let readOnlyError { throw readOnlyError }
        do { return try read() }
        catch {
            let error = sanitized(error)
            readOnlyError = error
            throw error
        }
    }

    private func read() throws -> Loaded {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound { return Loaded(entries: [], object: [:]) }
        catch let error as FileStoreError { throw SettingsError.readFailed(error) }
        catch { throw SettingsError.readFailed(.ioFailure) }

        let object = try loader.load(bytes).object
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: JSONSerialization.data(withJSONObject: object))
            guard payload.version == Self.currentVersion,
                  Set(payload.profiles.map(\.id)).count == payload.profiles.count else { throw SettingsError.corruptFile }
            for entry in payload.profiles { _ = try entry.key() }
            return Loaded(entries: payload.profiles, object: object)
        } catch { throw SettingsError.corruptFile }
    }

    private func write(_ format: OpenAIResponseFormat, for key: ProviderCacheKey,
                       preserving original: [String: Any]) throws {
        var object = original
        var profiles = original["profiles"] as? [[String: Any]] ?? []
        let index = profiles.firstIndex {
            ($0["id"] as? String).flatMap(UUID.init(uuidString:)).map(ProviderProfileID.init) == key.profileID
        }
        var entry = index.map { profiles[$0] } ?? [:]
        entry["id"] = key.profileID.rawValue
        entry["kind"] = key.kind.rawValue
        entry["baseURL"] = key.baseURL.absoluteString
        entry["modelID"] = key.modelID
        entry["format"] = format.rawValue
        if let index { profiles[index] = entry }
        else { profiles.append(entry) }
        object["version"] = Self.currentVersion
        object["profiles"] = profiles
        do {
            try files.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: path)
        } catch let error as FileStoreError { throw SettingsError.writeFailed(error) }
        catch { throw SettingsError.writeFailed(.ioFailure) }
    }

    private func sanitized(_ error: Error) -> SettingsError { error as? SettingsError ?? .readFailed(.ioFailure) }

    public var description: String { "<provider capability state>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
