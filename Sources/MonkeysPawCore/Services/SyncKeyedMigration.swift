import Foundation

enum SyncKeyedStoreKind: String, Codable, Hashable { case history, usage, values }

protocol SyncKeyedStore {
    var syncKind: SyncKeyedStoreKind { get }
    func prepareSyncMigration(from: PromptIdentity, to: PromptIdentity,
                              rebindingHeadTo: Data?, originalBytes: Data?) throws -> [SyncKeyedMigration]
    func applySyncMigration(_ migration: SyncKeyedMigration, operations: SyncFileOperations) throws
}

struct SyncKeyedMigration: Codable, CustomStringConvertible, CustomReflectable {
    enum Change: Codable {
        case file(SyncKeyedFileMove)
        case values(source: String, destination: String, fields: [String: String])
    }
    let store: SyncKeyedStoreKind
    let change: Change
    var description: String { "<sync keyed migration>" }
    var customMirror: Mirror { Mirror(self, children: ["migration": description]) }

    func validate() throws {
        switch change {
        case .file(let move):
            guard store != .values else { throw SyncError.invalidState }
            try move.validate()
            let prefix = store.rawValue + "/"
            guard move.source.hasPrefix(prefix), move.destination.hasPrefix(prefix) else { throw SyncError.invalidState }
        case .values(let source, let destination, _):
            guard store == .values, source != destination else { throw SyncError.invalidState }
            _ = try SyncIdentifiers.promptIdentity(source)
            _ = try SyncIdentifiers.promptIdentity(destination)
        }
    }
}

/// Copy durably before deleting the old key. Neither a completed copy nor a
/// partial multi-file history migration depends on an in-memory rollback list.
struct SyncKeyedFileMove: Codable {
    let source: String
    let destination: String
    let bytes: Data
    let destinationBytes: Data
    let hash: SyncHash
    let destinationHash: SyncHash

    init(source: String, destination: String, bytes: Data, destinationBytes: Data? = nil) {
        self.source = source
        self.destination = destination
        self.bytes = bytes
        self.destinationBytes = destinationBytes ?? bytes
        hash = SyncHash(bytes: bytes)
        destinationHash = SyncHash(bytes: self.destinationBytes)
    }

    func validate() throws {
        try FileStorePath.validate(source)
        try FileStorePath.validate(destination)
        guard RelativePath(source) != RelativePath(destination), hash == SyncHash(bytes: bytes),
              destinationHash == SyncHash(bytes: destinationBytes) else { throw SyncError.invalidState }
    }

    func apply(files: FileStore, operations: SyncFileOperations) throws {
        let old = try SyncDurability.readIfPresent(source, files: files)
        let new = try SyncDurability.readIfPresent(destination, files: files)
        guard old == nil || old == bytes, new == nil || new == destinationBytes,
              old != nil || new != nil else { throw LibraryError.keyedStateConflict }
        if new == nil { try files.writePrivate(destinationBytes, at: destination) }
        // Reflush even when replay recognizes bytes from an uncertain write.
        try SyncDurability.flushFileAndParents(destination, operations: operations)
        if old != nil {
            guard try SyncDurability.readIfPresent(source, files: files) == bytes else {
                throw LibraryError.keyedStateConflict
            }
            // Native directories survive deleting their last child. Flush them
            // before deletion too so the memory capability models that fact.
            try SyncDurability.flushParents(of: source, operations: operations)
            try files.delete(at: source)
        }
        try SyncDurability.flushParents(of: source, operations: operations)
    }
}

enum SyncDurability {
    static func readIfPresent(_ path: String, files: FileStore) throws -> Data? {
        do { return try files.read(at: path) }
        catch FileStoreError.notFound { return nil }
    }

    static func flushFileAndParents(_ path: String, operations: SyncFileOperations) throws {
        try operations.flushFile(at: RelativePath(path))
        try flushParents(of: path, operations: operations)
    }

    static func flushParents(of path: String, operations: SyncFileOperations) throws {
        var bytes = Array(path.utf8)
        while let slash = bytes.lastIndex(of: 47) {
            bytes.removeSubrange(slash...)
            try operations.flushDirectory(at: RelativePath(String(decoding: bytes, as: UTF8.self)))
        }
        try operations.flushDirectory(at: nil)
    }
}
