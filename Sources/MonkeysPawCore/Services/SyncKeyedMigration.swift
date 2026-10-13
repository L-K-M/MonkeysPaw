import Foundation

enum SyncKeyedStoreKind: String, Codable, Hashable { case history, usage, values }

protocol SyncKeyedStore {
    var syncKind: SyncKeyedStoreKind { get }
    func bindSyncWriteGate(_ gate: SyncLibraryWriteGate)
    func prepareSyncMigration(from: PromptIdentity, to: PromptIdentity,
                              rebindingHeadTo: Data?, originalBytes: Data?) throws -> [SyncKeyedMigration]
    func applySyncMigration(_ migration: SyncKeyedMigration, operations: SyncFileOperations) throws
    func isSyncMigrationUnstarted(_ migration: SyncKeyedMigration) throws -> Bool
}

/// Separate from the library lock: keyed writers check this flag under their
/// own store lock. Writes already in progress finish before preparation can
/// snapshot that store; new writes are refused until the journal is settled.
final class SyncLibraryWriteGate {
    private let lock = NSLock()
    private var owner: UUID?

    func requireEditable() throws {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil else { throw LibraryError.recoveryRequired }
    }

    func begin(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil || owner == id else { throw LibraryError.recoveryRequired }
        owner = id
    }

    func finish(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if owner == id { owner = nil }
    }

    func replace(_ previous: UUID, with next: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard owner == previous else { throw LibraryError.recoveryRequired }
        owner = next
    }
}

/// Shared app-data stores may outlive several library graphs. Do not replace
/// an older graph's active gate or retain a retired graph through its gate.
struct SyncKeyedWriteGates {
    private final class Reference {
        weak var gate: SyncLibraryWriteGate?
        init(_ gate: SyncLibraryWriteGate) { self.gate = gate }
    }
    private var references: [Reference] = []

    mutating func bind(_ gate: SyncLibraryWriteGate) {
        references.removeAll { $0.gate == nil }
        if !references.contains(where: { $0.gate === gate }) { references.append(Reference(gate)) }
    }

    mutating func requireEditable() throws {
        references.removeAll { $0.gate == nil }
        for reference in references { try reference.gate?.requireEditable() }
    }
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
            if store == .usage {
                do {
                    _ = try SyncIdentifiers.promptIdentity(String(move.source.dropFirst(prefix.count)))
                    _ = try SyncIdentifiers.promptIdentity(String(move.destination.dropFirst(prefix.count)))
                    _ = try UsageStore.decodeEvents(move.bytes)
                    _ = try UsageStore.decodeEvents(move.destinationBytes)
                } catch { throw SyncError.invalidState }
            }
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
        guard FileStorePath.isValid(source, mode: .relative), FileStorePath.isValid(destination, mode: .relative),
              RelativePath(source) != RelativePath(destination), hash == SyncHash(bytes: bytes),
              destinationHash == SyncHash(bytes: destinationBytes) else { throw SyncError.invalidState }
    }

    func apply(files: FileStore, operations: SyncFileOperations) throws {
        try validate()
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

    func isUnstarted(files: FileStore) throws -> Bool {
        try validate()
        return try SyncDurability.readIfPresent(source, files: files) == bytes
            && SyncDurability.readIfPresent(destination, files: files) == nil
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
