import Foundation

struct SyncStoreSnapshot<Value> {
    let value: Value?
    let error: SyncError?
}

/// One instance per app-data document. Its lock owns I/O, cache and the fail-closed
/// latch. Edit closures must not re-enter. FileStore has no filesystem-wide CAS.
final class SyncPersistence<Document: Codable> {
    private struct Version: Decodable { let version: Int }
    private struct Loaded {
        let document: Document?
        let object: [String: Any]
    }

    private let files: FileStore
    private let operations: SyncFileOperations
    private let path: String
    private let version: Int
    private let lock = NSLock()
    private var cached = SyncStoreSnapshot<Document>(value: nil, error: nil)
    private var hasDocument = false

    init(files: FileStore, operations: SyncFileOperations, path: String, version: Int) {
        self.files = files
        self.operations = operations
        self.path = path
        self.version = version
        do { _ = try load() } catch { /* load already latched a sanitized error */ }
    }

    var snapshot: SyncStoreSnapshot<Document> {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func load() throws -> Document? {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        cached = SyncStoreSnapshot(value: loaded.document, error: nil)
        hasDocument = loaded.document != nil
        return loaded.document
    }

    func update(_ change: (Document?) throws -> Document) throws {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try loadCurrent()
        let next = try change(loaded.document)
        try write(next, preserving: loaded.object)
        cached = SyncStoreSnapshot(value: next, error: nil)
        hasDocument = true
    }

    /// Explicit recovery/reset only. It does not read an unreadable old file or
    /// touch the library. The caller must settle journals and ownership first.
    func reset(_ next: Document?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let next { try write(next, preserving: [:]) }
        else {
            var deleted = true
            do { try files.delete(at: path) }
            catch FileStoreError.notFound { deleted = false }
            catch let error as FileStoreError { throw SyncError.writeFailed(error) }
            catch { throw SyncError.writeFailed(.ioFailure) }
            if deleted { try flush(file: false) }
        }
        cached = SyncStoreSnapshot(value: next, error: nil)
        hasDocument = next != nil
    }

    private func loadCurrent() throws -> Loaded {
        if let error = cached.error { throw error }
        do { return try read() }
        catch {
            let safe = error as? SyncError ?? .corruptFile
            cached = SyncStoreSnapshot(value: nil, error: safe)
            throw safe
        }
    }

    private func read() throws -> Loaded {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound where !hasDocument { return Loaded(document: nil, object: [:]) }
        catch let error as FileStoreError { throw SyncError.readFailed(error) }
        catch { throw SyncError.readFailed(.ioFailure) }
        guard bytes.count <= Limits.syncRecordMaxBytes else { throw SyncError.corruptFile }

        do {
            let sourceVersion = try JSONDecoder().decode(Version.self, from: bytes).version
            try SyncIdentifiers.version(sourceVersion, current: version)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw SyncError.corruptFile
            }
            return Loaded(document: try JSONDecoder().decode(Document.self, from: bytes), object: object)
        } catch let error as SyncError {
            switch error {
            case .futureVersion, .unsupportedVersion: throw error
            default: throw SyncError.corruptFile
            }
        } catch { throw SyncError.corruptFile }
    }

    private func write(_ next: Document, preserving original: [String: Any]) throws {
        let bytes: Data
        do {
            let encoded = try JSONEncoder().encode(next)
            guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw SyncError.invalidState
            }
            bytes = try JSONSerialization.data(withJSONObject: merge(object, original: original), options: [.sortedKeys])
            guard bytes.count <= Limits.syncRecordMaxBytes else { throw SyncError.invalidState }
            // Encoding also checks mutable state's invariants before any I/O.
            _ = try JSONDecoder().decode(Document.self, from: bytes)
        } catch { throw SyncError.invalidState }

        do { try files.writePrivate(bytes, at: path) }
        catch let error as FileStoreError { throw SyncError.writeFailed(error) }
        catch { throw SyncError.writeFailed(.ioFailure) }
        try flush(file: true)
    }

    private func flush(file: Bool) throws {
        do {
            if file { try operations.flushFile(at: RelativePath(path)) }
            try operations.flushDirectory(at: RelativePath("sync"))
            try operations.flushDirectory(at: nil)
        } catch {
            // The atomic write/delete may have committed already. Keep the old
            // value for diagnostics, but never authorize another edit/acknowledgment.
            cached = SyncStoreSnapshot(value: cached.value, error: .durabilityUncertain)
            throw SyncError.durabilityUncertain
        }
    }

    /// Dynamic map entries are authoritative: preserve unknown fields *inside*
    /// retained records, without resurrecting removed groups/prompts/favourites.
    /// Arrays follow byte-exact library root/path identity rather than position.
    private func merge(_ next: [String: Any], original: [String: Any]) -> [String: Any] {
        let maps: Set<String> = ["cursors", "groups", "prompts", "favorites", "managed_folders"]
        let arrays = ["libraries": "library_root", "holds": "path"]
        var result = original
        for (key, value) in next {
            if let object = value as? [String: Any] {
                let previous = original[key] as? [String: Any] ?? [:]
                if maps.contains(key) {
                    var entries = object
                    for (id, item) in object {
                        if let record = item as? [String: Any] {
                            entries[id] = merge(record, original: previous[id] as? [String: Any] ?? [:])
                        }
                    }
                    result[key] = entries
                } else {
                    var retained = previous
                    if key == "origin", object["kind"] as? String == "rescued" {
                        retained.removeValue(forKey: "prompt_id")
                    }
                    result[key] = merge(object, original: retained)
                }
            } else if let identityKey = arrays[key], let records = value as? [[String: Any]] {
                let old = original[key] as? [[String: Any]] ?? []
                result[key] = records.map { record in
                    let previous = old.first {
                        guard let lhs = $0[identityKey] as? String, let rhs = record[identityKey] as? String else { return false }
                        return lhs.utf8.elementsEqual(rhs.utf8)
                    } ?? [:]
                    return merge(record, original: previous)
                }
            } else { result[key] = value }
        }
        return result
    }
}
