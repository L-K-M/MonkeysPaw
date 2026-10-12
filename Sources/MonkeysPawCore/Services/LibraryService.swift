import Foundation

/// Owns one library tree and its app-data history. No cache/watch/index in M2b.
/// Calls are synchronous and serialized within this instance. A composition
/// root must share one service per pair of roots; external edits use stamps.
public final class LibraryService: PromptFavoriteEditing {
    private enum SaveMode {
        case replace(expectedStamp: FileStamp?)
        case createOnly
    }

    private struct LoadedFile {
        let bytes: Data
        let entry: LibraryEntry
    }

    private struct CommittedHistoryFailure: Error {
        let entry: LibraryEntry
    }

    private struct CommittedExternalReplacement: Error {
        let currentStamp: FileStamp
    }

    private let files: FileStore
    private let historyStore: HistoryStore
    private let keyedStores: [PromptKeyedStore]
    private let clock: WallClock
    private let entropy: EntropySource
    private let lock = NSLock()

    public init(library: FileStore, data: FileStore, clock: WallClock, entropy: EntropySource,
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
        try locked { try libraryEntries() }
    }

    public func load(at path: String) throws -> LibraryEntry {
        try locked { try requireCurrent(at: path).entry }
    }

    func loadForEditing(at path: String) throws -> LoadedPrompt {
        try locked {
            let loaded = try requireCurrent(at: path)
            return LoadedPrompt(bytes: loaded.bytes, entry: loaded.entry)
        }
    }

    /// Keep the editor's preflight and save under the library lock. A nil stamp
    /// explicitly permits overwrite/recreation, as in the synchronous API.
    func saveForEditing(_ document: PromptDocument, at path: String,
                        expectedStamp: FileStamp?) throws -> PromptSaveOutcome {
        try locked {
            let current = try readCurrent(at: path)
            if let expectedStamp {
                guard let current else { return .deleted }
                guard expectedStamp == current.entry.stamp else { return .conflict(currentStamp: current.entry.stamp) }
            }
            if let current, let reason = LoadedPrompt.readOnlyReason(for: current.entry.document) {
                return .readOnly(reason)
            }
            return try editingCommit {
                try saveDocument(document, at: path, mode: .replace(expectedStamp: expectedStamp))
            }
        }
    }

    func createCopyForEditing(_ document: PromptDocument, near path: String) throws -> PromptSaveOutcome {
        try locked {
            let copy = try PromptCodec.removingIdentity(from: document)
            return try editingCommit { try createDocument(copy, near: path) }
        }
    }

    /// Supply the load/list stamp to reject stale edits, including deletion.
    /// Nil explicitly permits overwriting the version read by this operation.
    @discardableResult
    public func save(_ document: PromptDocument, at path: String,
                     expectedStamp: FileStamp? = nil) throws -> LibraryEntry {
        try locked { try saveDocument(document, at: path, mode: .replace(expectedStamp: expectedStamp)) }
    }

    /// Uses the held entry's stamp, including first-save identity migration and
    /// history. Never reload a stale entry and then overwrite the external edit.
    public func toggleFavorite(of entry: LibraryEntry) -> PromptFavoriteOutcome {
        do {
            let saved = try locked {
                let draft = try PromptCodec.settingFavorite(!entry.document.frontMatter.favorite,
                    in: entry.document, filename: LibraryPath.filename(entry.relativePath))
                return try saveDocument(draft, at: entry.relativePath,
                                        mode: .replace(expectedStamp: entry.stamp))
            }
            return .saved(saved)
        } catch let error as FileStoreError { return .fileStoreFailure(error) }
        catch let error as LibraryError { return .libraryFailure(error) }
        catch let error as PromptWriteError { return .writeFailure(error) }
        catch { return .libraryFailure(.operationFailed) }
    }

    /// A real first save, including identity assignment, that atomically refuses
    /// any occupied destination with LibraryError.destinationOccupied.
    @discardableResult
    public func create(_ document: PromptDocument, at path: String) throws -> LibraryEntry {
        try locked { try saveDocument(document, at: path, mode: .createOnly) }
    }

    /// Create from a picker query with the usual filename and first-save rules.
    /// Raced destinations survive; alternate-name or publication exhaustion
    /// returns LibraryError.copyLimitReached. Other failures are not retried.
    public func createPrompt(titled title: String, body: String) throws -> LibraryEntry {
        try locked {
            let path = PromptCreation.relativePath(title: title, now: clock.now())
            let document = try PromptCodec.newDocument(title: title, body: body)
            return try createDocument(document, near: path)
        }
    }

    private func createDocument(_ document: PromptDocument, near path: String) throws -> LibraryEntry {
        var startingSuffix = 1
        for _ in 0..<Limits.libraryCreateAttemptCap {
            let candidate = try availablePath(for: path, startingSuffix: startingSuffix)
            do {
                return try saveDocument(document, at: candidate.path, mode: .createOnly)
            } catch LibraryError.destinationOccupied {
                // Move forward even if the external file disappears before the next probe.
                startingSuffix = candidate.suffix + 1
            }
        }
        throw LibraryError.copyLimitReached
    }

    /// Later sync push calls this before transmitting an unassigned prompt.
    /// A supplied stamp rejects stale edits before assignment or return.
    /// Already assigned files are returned without a write or new snapshot.
    @discardableResult
    public func assignIdentity(to path: String,
                               expectedStamp: FileStamp? = nil) throws -> LibraryEntry {
        try locked {
            let loaded = try requireCurrent(at: path)
            if let expectedStamp, expectedStamp != loaded.entry.stamp { throw LibraryError.conflict }
            guard loaded.entry.document.frontMatter.id == nil else { return loaded.entry }
            return try saveDocument(loaded.entry.document, at: path, mode: .replace(expectedStamp: loaded.entry.stamp))
        }
    }

    /// Probe Name.md, Name 2.md, Name 3.md, ... without reserving a name.
    /// Use a draft without id for a distinct copy identity. A caller should
    /// use create(_:at:) to claim it without replacement; this probe reserves nothing.
    public func availablePath(for path: String) throws -> String {
        try locked { try availablePath(for: path, startingSuffix: 1).path }
    }

    private func availablePath(for path: String, startingSuffix: Int) throws -> (path: String, suffix: Int) {
        try LibraryPath.validate(path)
        if startingSuffix == 1, try isAvailable(path) { return (path, 1) }
        // A leading combining mark can share a grapheme with the slash.
        let scalars = path.unicodeScalars
        let filenameStart = scalars.lastIndex(of: "/").map { scalars.index(after: $0) } ?? scalars.startIndex
        let directory = String(path[..<filenameStart])
        let stem = path[filenameStart...].dropLast(3)
        for suffix in max(2, startingSuffix)..<(2 + Limits.libraryCopyCandidateCap) {
            let candidate = directory + Self.copyFilename(stem: stem, suffix: suffix)
            try LibraryPath.validate(candidate)
            if try isAvailable(candidate) { return (candidate, suffix) }
        }
        throw LibraryError.copyLimitReached
    }

    private static func copyFilename(stem: Substring, suffix: Int) -> String {
        let ending = " \(suffix).md"
        var remainingBytes = Limits.promptFilenameMaxBytes - ending.utf8.count
        // Count whole characters to preserve graphemes and their UTF-8 scalars.
        let prefix = stem.prefix { character in
            let byteCount = String(character).utf8.count
            guard byteCount <= remainingBytes else { return false }
            remainingBytes -= byteCount
            return true
        }
        return String(prefix) + ending
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
    public func delete(at path: String, expectedStamp: FileStamp? = nil) throws {
        try locked {
            try LibraryPath.validate(path)
            if let expectedStamp {
                guard let currentStamp = try files.stamp(at: path) else { throw FileStoreError.notFound }
                guard expectedStamp == currentStamp else { throw LibraryError.conflict }
            }
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
            switch revision.identity {
            case .local:
                guard PromptIdentity(path: path, id: nil) == revision.identity else {
                    throw LibraryError.identityMismatch
                }
            case .assigned:
                // Assigned ids need a full scan to resolve their live paths.
                // Keep utf8.elementsEqual for byte-exact comparison: String
                // equality accepts canonically equivalent but byte-distinct paths.
                let liveElsewhere = try libraryEntries().contains(where: {
                    $0.identity == revision.identity && !$0.relativePath.utf8.elementsEqual(path.utf8)
                })
                guard !liveElsewhere else { throw LibraryError.identityMismatch }
            }
            if let current = try readCurrent(at: path), current.entry.identity != revision.identity {
                throw LibraryError.identityMismatch
            }
            let bytes = try historyStore.read(revision)
            var document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(path))
            if case .assigned(let id) = revision.identity {
                document = try PromptCodec.assigningIdentity(id, to: document)
            }
            return try saveDocument(document, at: path, mode: .replace(expectedStamp: expectedStamp))
        }
    }

    private func libraryEntries() throws -> [LibraryEntry] {
        try files.listFiles().filter { LibraryPath.isPrompt($0.relativePath) }
            .sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }.map { file in
                try LibraryPath.validate(file.relativePath)
                guard let loaded = try readCurrent(at: file.relativePath), loaded.entry.stamp == file.stamp else {
                    throw LibraryError.conflict
                }
                return loaded.entry
            }
    }

    private func saveDocument(_ draft: PromptDocument, at path: String, mode: SaveMode) throws -> LibraryEntry {
        try LibraryPath.validate(path)
        _ = try PromptCodec.write(draft)
        let current: LoadedFile?
        switch mode {
        case .replace(let expectedStamp):
            current = try readCurrent(at: path)
            if let expectedStamp, expectedStamp != current?.entry.stamp { throw LibraryError.conflict }
        case .createOnly:
            // Publication, rather than a read/probe, decides whether this path is occupied.
            current = nil
        }
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
            switch mode {
            case .replace:
                // Recheck after staging history/migration, before replacing bytes.
                guard try files.stamp(at: path) == current?.entry.stamp else { throw LibraryError.conflict }
                try files.write(bytes, at: path)
            case .createOnly:
                do { try files.create(bytes, at: path) }
                catch FileStoreError.alreadyExists { throw LibraryError.destinationOccupied }
            }
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

        // Capture our committed version before retention can fail or an
        // external writer can replace it during app-data maintenance.
        let committed = try requireCurrent(at: path)
        guard committed.bytes == bytes else {
            throw CommittedExternalReplacement(currentStamp: committed.entry.stamp)
        }
        do { try historyStore.prune(for: targetIdentity) }
        catch { throw CommittedHistoryFailure(entry: committed.entry) }
        return committed.entry
    }

    private func editingCommit(_ work: () throws -> LibraryEntry) throws -> PromptSaveOutcome {
        do { return .saved(try work()) }
        catch let error as CommittedHistoryFailure { return .savedButHistoryMaintenanceFailed(error.entry) }
        catch let error as CommittedExternalReplacement { return .conflict(currentStamp: error.currentStamp) }
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
        catch is CommittedHistoryFailure { throw LibraryError.historyMaintenanceFailed }
        catch is CommittedExternalReplacement { throw LibraryError.conflict }
        catch let error as FileStoreError { throw error }
        catch let error as LibraryError { throw error }
        catch let error as PromptWriteError { throw error }
        catch let error as ULIDGenerationError { throw error }
        catch { throw LibraryError.operationFailed }
    }
}
