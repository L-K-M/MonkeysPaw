import Foundation

/// Remembered field text at app-data values.json (§5.1). Version 1 is sorted-key
/// JSON: {"values":{<identity-key>:{<field>:<value>}},"version":1}.
/// Empty delivered strings are remembered verbatim, repeating the last choice.
/// Every operation, including read/merge/private replacement, holds one lock.
/// Share one instance per app-data root, including identity migration callers.
/// Read/modify operations fail closed on corrupt, unsupported or over-cap state.
/// Explicit removeAll() discards existing state without requiring it to decode.
public final class ValuesStore: PromptKeyedStore, @unchecked Sendable {
    private struct Payload: Codable {
        var values: [String: [String: String]]
        let version: Int
    }

    private let files: FileStore
    private let lock = NSLock()
    private let path = "values.json"

    public init(files: FileStore) { self.files = files }

    public func rememberedValues(for identity: PromptIdentity) throws -> [String: String] {
        try locked {
            let key = try identity.storageKey
            return try read().values[key] ?? [:]
        }
    }

    /// Merge supplied fields; preserve other identities and fields. Empty maps
    /// are a no-op with no filesystem access. Values themselves may be empty.
    public func record(identity: PromptIdentity, values: [String: String]) throws {
        guard !values.isEmpty else { return }
        try locked {
            let key = try identity.storageKey
            var payload = try read()
            payload.values[key, default: [:]].merge(values) { _, delivered in delivered }
            try write(payload)
        }
    }

    /// Remove the whole identity map, including fields no longer in a prompt.
    /// Missing identities are a no-op; rejected state remains untouched.
    public func remove(identity: PromptIdentity) throws {
        try locked {
            let key = try identity.storageKey
            var payload = try read()
            guard payload.values.removeValue(forKey: key) != nil else { return }
            try write(payload)
        }
    }

    /// values.json format version written by every replacement and accepted on read.
    private static let formatVersion = 1

    /// Explicit recovery also works when existing state cannot be read or decoded.
    /// The private writer retains the driver's rooted path and file checks.
    public func removeAll() throws {
        try locked { try write(Payload(values: [:], version: Self.formatVersion)) }
    }

    @discardableResult
    public func migrateKey(from source: PromptIdentity, to destination: PromptIdentity) throws -> PromptKeyMigration {
        try locked {
            let sourceKey = try source.storageKey
            let destinationKey = try destination.storageKey
            var payload = try read()
            guard source != destination, let values = payload.values[sourceKey] else { return .unchanged }
            guard payload.values[destinationKey] == nil else { throw LibraryError.keyedStateConflict }
            payload.values[sourceKey] = nil
            payload.values[destinationKey] = values
            try write(payload)
            return .migrated
        }
    }

    private func read() throws -> Payload {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound { return Payload(values: [:], version: Self.formatVersion) }
        guard bytes.count <= Limits.valuesFileCapBytes else { throw LibraryError.operationFailed }
        let payload = try JSONDecoder().decode(Payload.self, from: bytes)
        guard payload.version == Self.formatVersion else { throw LibraryError.operationFailed }
        return payload
    }

    private func write(_ payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(payload)
        guard bytes.count <= Limits.valuesFileCapBytes else { throw LibraryError.operationFailed }
        try files.writePrivate(bytes, at: path)
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        do { return try work() }
        catch let error as FileStoreError { throw error }
        catch let error as LibraryError { throw error }
        catch { throw LibraryError.operationFailed }
    }
}
