import Foundation

/// Owns one library tree and its app-data history. No cache/watch/index in M2b.
/// Calls are synchronous and serialized within this instance. A composition
/// root must share one service per pair of roots; external edits use stamps.
public final class LibraryService {
    private struct LoadedFile {
        let bytes: Data
        let entry: LibraryEntry
    }

    private let files: FileStore
    private let historyStore: HistoryStore
    private let keyedStores: [PromptKeyedStore]
    private let clock: Clock
    private let entropy: EntropySource
    private let lock = NSLock()

    public init(library: FileStore, data: FileStore, clock: Clock, entropy: EntropySource,
                keyedStores: [PromptKeyedStore] = []) {
        files = library
        let history = HistoryStore(files: data)
        historyStore = history
        self.keyedStores = [history] + keyedStores
        self.clock = clock
        self.entropy = entropy
    }

    /// Exact-case .md files, in relative POSIX path order. Invalid content stays
    /// listed with issues; I/O failures and concurrent changes are explicit.
    public func entries() throws -> [LibraryEntry] {
        try locked {
            try files.listFiles().filter { LibraryPath.isPrompt($0.relativePath) }
                .sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }.map { file in
                    try LibraryPath.validate(file.relativePath)
                    guard let loaded = try readCurrent(at: file.relativePath), loaded.entry.stamp == file.stamp else {
                        throw LibraryError.conflict
                    }
                    return loaded.entry
                }
        }
    }

    public func load(at path: String) throws -> LibraryEntry {
        try locked { try requireCurrent(at: path).entry }
    }

    /// Supply the load/list stamp to reject stale edits, including deletion.
    /// Nil explicitly permits overwriting the version read by this operation.
    @discardableResult
    public func save(_ document: PromptDocument, at path: String,
                     expectedStamp: FileStamp? = nil) throws -> LibraryEntry {
        try locked { try saveDocument(document, at: path, expectedStamp: expectedStamp) }
    }

    /// Later sync push calls this before transmitting an unassigned prompt.
    /// Already assigned files are returned without a write or new snapshot.
    @discardableResult
    public func assignIdentity(to path: String) throws -> LibraryEntry {
        try locked {
            let loaded = try requireCurrent(at: path)
            guard loaded.entry.document.frontMatter.id == nil else { return loaded.entry }
            return try saveDocument(loaded.entry.document, at: path, expectedStamp: loaded.entry.stamp)
        }
    }

    /// Probe Name.md, Name 2.md, Name 3.md, ... without reserving a name.
    /// Use a draft without id for a distinct copy identity. A caller should
    /// recheck a chosen name before save; this helper is not an exclusive create.
    public func availablePath(for path: String) throws -> String {
        try locked {
            try LibraryPath.validate(path)
            if try isAvailable(path) { return path }
            let stem = String(path.dropLast(3))
            for suffix in 2..<(2 + Limits.libraryCopyCandidateCap) {
                let candidate = stem + " \(suffix).md"
                try LibraryPath.validate(candidate)
                if try isAvailable(candidate) { return candidate }
            }
            throw LibraryError.copyLimitReached
        }
    }

    @discardableResult
    public func move(from source: String, to destination: String) throws -> LibraryEntry {
        try locked {
            try LibraryPath.validate(destination)
            let loaded = try requireCurrent(at: source)
            if source.utf8.elementsEqual(destination.utf8) { return loaded.entry }
            guard try files.stamp(at: destination) == nil else { throw FileStoreError.alreadyExists }
            let targetIdentity = PromptIdentity(path: destination, id: loaded.entry.document.frontMatter.id)
            var migrated = [PromptKeyedStore]()
            do {
                try migrate(from: loaded.entry.identity, to: targetIdentity, completed: &migrated)
                guard try files.stamp(at: source) == loaded.entry.stamp else { throw LibraryError.conflict }
                try files.move(from: source, to: destination)
            } catch {
                try rollback(migrated, from: targetIdentity, to: loaded.entry.identity)
                throw error
            }
            return try requireCurrent(at: destination).entry
        }
    }

    /// History survives deletion; restore can resurrect this identity later.
    public func delete(at path: String) throws {
        try locked {
            try LibraryPath.validate(path)
            try files.delete(at: path)
        }
    }

    public func history(for identity: PromptIdentity) throws -> [HistoryRevision] {
        try locked { try historyStore.revisions(for: identity) }
    }

    /// Restore uses the normal save path, including validation, stamp checks,
    /// current-file snapshot and retention. A pre-id revision keeps its key's id.
    @discardableResult
    public func restore(_ revision: HistoryRevision, at path: String,
                        expectedStamp: FileStamp? = nil) throws -> LibraryEntry {
        try locked {
            try LibraryPath.validate(path)
            if let current = try readCurrent(at: path), current.entry.identity != revision.identity {
                throw LibraryError.identityMismatch
            }
            let bytes = try historyStore.read(revision)
            var document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(path))
            if case .assigned(let id) = revision.identity {
                document = try PromptCodec.assigningIdentity(id, to: document)
            }
            return try saveDocument(document, at: path, expectedStamp: expectedStamp)
        }
    }

    private func saveDocument(_ draft: PromptDocument, at path: String,
                              expectedStamp: FileStamp?) throws -> LibraryEntry {
        try LibraryPath.validate(path)
        _ = try PromptCodec.write(draft)
        let current = try readCurrent(at: path)
        if let expectedStamp, expectedStamp != current?.entry.stamp { throw LibraryError.conflict }
        if let current, current.entry.document.isReadOnly {
            throw PromptWriteError.unsupportedFormat(current.entry.document.frontMatter.format)
        }

        let date = clock.now()
        var document = draft
        if let id = current?.entry.document.frontMatter.id {
            if let draftID = draft.frontMatter.id, draftID != id { throw LibraryError.identityMismatch }
            document = try PromptCodec.assigningIdentity(id, to: document)
        } else if document.frontMatter.id == nil {
            let id = try ULID.generate(at: date, entropy: entropy.bytes(count: Limits.ulidEntropyBytes))
            document = try PromptCodec.assigningIdentity(id, to: document)
        }
        let bytes = Data(try PromptCodec.write(document).utf8)
        let sourceIdentity = current?.entry.identity ?? PromptIdentity(path: path, id: nil)
        let targetIdentity = PromptIdentity(path: path, id: document.frontMatter.id)
        var migrated = [PromptKeyedStore]()
        var snapshot: HistoryRevision?
        do {
            try migrate(from: sourceIdentity, to: targetIdentity, completed: &migrated)
            if let current {
                snapshot = try historyStore.snapshot(current.bytes, for: targetIdentity, at: date)
            }
            // Recheck after staging history/migration, before replacing bytes.
            guard try files.stamp(at: path) == current?.entry.stamp else { throw LibraryError.conflict }
            try files.write(bytes, at: path)
        } catch {
            var recovered = true
            if let snapshot {
                do { try historyStore.remove(snapshot) } catch { recovered = false }
            }
            do { try rollback(migrated, from: targetIdentity, to: sourceIdentity) }
            catch { recovered = false }
            guard recovered else { throw LibraryError.recoveryRequired }
            throw error
        }

        do { try historyStore.prune(for: targetIdentity) }
        catch { throw LibraryError.historyMaintenanceFailed }
        return try requireCurrent(at: path).entry
    }

    private func readCurrent(at path: String) throws -> LoadedFile? {
        try LibraryPath.validate(path)
        guard let stamp = try files.stamp(at: path) else { return nil }
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound { throw LibraryError.conflict }
        guard try files.stamp(at: path) == stamp else { throw LibraryError.conflict }
        let document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(path))
        return LoadedFile(bytes: bytes, entry: LibraryEntry(path: path, document: document, stamp: stamp))
    }

    private func requireCurrent(at path: String) throws -> LoadedFile {
        guard let current = try readCurrent(at: path) else { throw FileStoreError.notFound }
        return current
    }

    private func isAvailable(_ path: String) throws -> Bool {
        do { return try files.stamp(at: path) == nil }
        catch FileStoreError.notRegularFile { return false }
    }

    private func migrate(from source: PromptIdentity, to destination: PromptIdentity,
                         completed: inout [PromptKeyedStore]) throws {
        guard source != destination else { return }
        for store in keyedStores {
            if try store.migrateKey(from: source, to: destination) == .migrated { completed.append(store) }
        }
    }

    private func rollback(_ completed: [PromptKeyedStore], from source: PromptIdentity,
                          to destination: PromptIdentity) throws {
        var recovered = true
        for store in completed.reversed() {
            do { try store.migrateKey(from: source, to: destination) }
            catch { recovered = false }
        }
        guard recovered else { throw LibraryError.recoveryRequired }
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        do { return try work() }
        catch let error as FileStoreError { throw error }
        catch let error as LibraryError { throw error }
        catch let error as PromptWriteError { throw error }
        catch let error as ULIDGenerationError { throw error }
        catch { throw LibraryError.operationFailed }
    }
}
