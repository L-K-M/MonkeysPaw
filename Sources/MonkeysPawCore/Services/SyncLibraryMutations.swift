import Foundation

/// A byte-exact baseline, including incarnation, that can survive a restart.
struct SyncLibraryFile: Codable, CustomStringConvertible, CustomReflectable {
    let path: String
    let stamp: FileStamp
    let identityKey: String
    let bytes: Data
    let hash: SyncHash

    var identity: PromptIdentity { get throws { try SyncIdentifiers.promptIdentity(identityKey) } }
    var description: String { "<sync library file>" }
    var customMirror: Mirror { Mirror(self, children: ["file": description]) }

    init(path: String, stamp: FileStamp, bytes: Data) throws {
        try FileStorePath.validate(path)
        self.path = path
        self.stamp = stamp
        self.bytes = bytes
        hash = SyncHash(bytes: bytes)
        let document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(path))
        identityKey = try PromptIdentity(path: path, id: document.frontMatter.id).storageKey
    }

    func validate() throws {
        let checked = try SyncLibraryFile(path: path, stamp: stamp, bytes: bytes)
        guard checked.hash == hash, checked.identityKey == identityKey else { throw SyncError.invalidState }
    }
}

/// Sync may adopt a different assigned ID; ordinary editor saves still cannot.
struct SyncIdentityTransition: Codable {
    let source: String?
    let destination: String

    init(from source: PromptIdentity?, to destination: PromptIdentity) throws {
        self.source = try source?.storageKey
        self.destination = try destination.storageKey
    }
}

struct SyncLibraryEdit: Codable, CustomStringConvertible, CustomReflectable {
    enum Kind: String, Codable { case apply, adopt, repairDuplicate, rescue, trash }
    let id: UUID
    let kind: Kind
    let path: String
    let expected: SyncLibraryFile?
    let bytes: Data?
    let hash: SyncHash?
    let transition: SyncIdentityTransition?
    let mode: SyncFileMode
    /// Rescue raw bytes are retained even when the published copy receives an ID.
    let retainedBytes: Data?
    let retainedSourcePath: String?
    let copyID: String?
    let heldIssue: SyncIssueCode?
    /// Also retained when raw forensic bytes cannot carry a front-matter marker.
    var copyOrigin: SyncPromptOrigin? = nil
    /// A byte-distinct spelling of the same adoption path on a case-sensitive
    /// filesystem. Its keyed state migrates when the exact server bytes publish.
    var adoptingSource: SyncLibraryFile? = nil

    var description: String { "<sync library edit>" }
    var customMirror: Mirror { Mirror(self, children: ["edit": description]) }

    func validate() throws {
        try FileStorePath.validate(path)
        try expected?.validate()
        try adoptingSource?.validate()
        if let source = adoptingSource {
            guard kind == .adopt, expected == nil, RelativePath(source.path) != RelativePath(path),
                  try SyncNaming.pathKey(RelativePath(source.path)) == SyncNaming.pathKey(RelativePath(path)),
                  retainedBytes == source.bytes, retainedSourcePath.map({ RelativePath($0) }) == RelativePath(source.path) else {
                throw SyncError.invalidState
            }
        }
        if let expected, RelativePath(expected.path) != RelativePath(path) { throw SyncError.invalidState }
        if let retainedSourcePath { try FileStorePath.validate(retainedSourcePath) }
        if kind == .trash {
            guard expected != nil, bytes == nil, hash == nil, transition == nil,
                  retainedBytes == expected?.bytes,
                  retainedSourcePath.map({ RelativePath($0) }) == expected.map({ RelativePath($0.path) }),
                  copyID == nil, heldIssue == nil, copyOrigin == nil else { throw SyncError.invalidState }
            return
        }
        guard let bytes, hash == SyncHash(bytes: bytes), let transition else { throw SyncError.invalidState }
        // An external editor/git import may already have assigned the ID while
        // this exact path's local key still owns its history/usage/values.
        let localKey = try PromptIdentity(path: path, id: nil).storageKey
        let assignedExternally = kind == .adopt && adoptingSource == nil && expected != nil
            && expected?.identityKey == transition.destination
            && transition.source == localKey
        guard transition.source == (expected ?? adoptingSource)?.identityKey || assignedExternally else {
            throw SyncError.invalidState
        }
        let document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(path))
        let destination = try SyncIdentifiers.promptIdentity(transition.destination)
        guard destination == PromptIdentity(path: path, id: document.frontMatter.id) else { throw SyncError.invalidState }
        if kind == .rescue {
            guard path.utf8.starts(with: "Conflicts/".utf8), expected == nil,
                  let retainedBytes, let retainedSourcePath,
                  let wire = try? SyncPathValidator.validate(path, scope: .user),
                  wire.path.utf8.elementsEqual(path.utf8) else { throw SyncError.invalidState }
            if heldIssue != nil {
                let nonPrompt = !LibraryPath.isPrompt(retainedSourcePath)
                guard bytes == retainedBytes, copyID == nil,
                      !document.canRender || (nonPrompt && heldIssue == .localVisibility)
                        || (heldIssue == .content(.invalidMetadataType) && SyncConflictMetadata.hasInvalidOrigin(in: document)) else {
                    throw SyncError.invalidState
                }
                return
            }
            let original = PromptCodec.parseFile(retainedBytes, filename: LibraryPath.filename(retainedSourcePath))
            guard let copyID, document.frontMatter.id?.rawValue == copyID,
                  original.frontMatter.id?.rawValue != copyID else { throw SyncError.invalidState }
        } else {
            try LibraryPath.validate(path)
            guard copyOrigin == nil, copyID == nil, retainedBytes == (expected ?? adoptingSource)?.bytes,
                  retainedSourcePath.map({ RelativePath($0) }) == (expected ?? adoptingSource).map({ RelativePath($0.path) }),
                  heldIssue == nil || (heldIssue == .content(.invalidMetadataType)
                    && SyncConflictMetadata.hasInvalidOrigin(in: document)) else { throw SyncError.invalidState }
        }
        if kind == .repairDuplicate {
            guard let expected, case .assigned = try expected.identity,
                  case .assigned = destination, expected.identityKey != transition.destination else {
                throw SyncError.invalidState
            }
        }
        guard !document.isReadOnly, !document.issues.contains(where: { $0.severity == .error }) else {
            throw SyncError.invalidState
        }
        if heldIssue == .content(.invalidMetadataType), kind != .rescue { return }
        do {
            let origin = try SyncConflictMetadata.origin(in: document)
            if let copyOrigin, origin != copyOrigin { throw SyncError.invalidState }
        }
        catch { throw SyncError.invalidState }
    }
}

enum SyncLibraryMutationOutcome { case applied, replanAsConflict }

struct SyncLibraryMutationResult: CustomStringConvertible, CustomReflectable {
    let outcome: SyncLibraryMutationOutcome
    let displacedBytes: Data?
    var effect: SyncFileMutationEffect = .unchanged
    var description: String { "<sync library mutation result>" }
    var customMirror: Mirror { Mirror(self, children: ["result": description]) }
}

/// Only checked library read/hash/publication uses LibraryService's lock.
/// Planning, journal/state I/O and keyed-store durability run outside it. The
/// recovery gate blocks cooperating editor writes throughout a pending apply.
final class SyncLibraryMutations {
    enum Attempt { case first, replay }
    private let library: LibraryService
    private let operations: SyncFileOperations

    init(library: LibraryService, operations: SyncFileOperations) {
        self.library = library
        self.operations = operations
    }

    func read(at path: RelativePath) throws -> SyncLibraryFile? {
        try library.withSyncLock { files in try Self.read(files, at: path.string) }
    }

    /// Include files outside browser enumeration. A racing/unreadable listing
    /// aborts the scan, rather than supplying partial evidence for deletions.
    func listedFiles() throws -> [SyncLibraryFile] {
        try library.withSyncLock { files in
            try files.listFiles().sorted { RelativePath($0.relativePath) < RelativePath($1.relativePath) }.map {
                guard let file = try Self.read(files, at: $0.relativePath), file.stamp == $0.stamp else {
                    throw LibraryError.conflict
                }
                return file
            }
        }
    }

    func publication(_ bytes: Data, at path: RelativePath, expecting expected: SyncLibraryFile?,
                     transition: SyncIdentityTransition, mode: SyncFileMode = .normal,
                     kind: SyncLibraryEdit.Kind = .apply, markerIssue: SyncIssueCode? = nil,
                     adoptingSource: SyncLibraryFile? = nil, id: UUID = UUID()) throws -> SyncLibraryEdit {
        let source = expected ?? adoptingSource
        var edit = SyncLibraryEdit(id: id, kind: kind, path: path.string, expected: expected, bytes: bytes,
            hash: SyncHash(bytes: bytes), transition: transition, mode: mode, retainedBytes: source?.bytes,
            retainedSourcePath: source?.path, copyID: nil, heldIssue: markerIssue)
        edit.adoptingSource = adoptingSource
        try edit.validate()
        return edit
    }

    func trash(_ file: SyncLibraryFile, id: UUID = UUID()) throws -> SyncLibraryEdit {
        let edit = SyncLibraryEdit(id: id, kind: .trash, path: file.path, expected: file, bytes: nil,
            hash: nil, transition: nil, mode: .normal, retainedBytes: file.bytes,
            retainedSourcePath: file.path, copyID: nil, heldIssue: nil)
        try edit.validate()
        return edit
    }

    /// The planner chooses destination and fresh ID once, before journaling.
    /// Unsupported/forensic files stay byte-exact and held, with no injected text.
    func rescue(_ file: SyncLibraryFile, at destination: RelativePath, freshID: ULID,
                origin: SyncPromptOrigin = .rescued, id: UUID = UUID()) throws -> SyncLibraryEdit {
        let document = PromptCodec.parseFile(file.bytes, filename: LibraryPath.filename(file.path))
        var issue = document.issues.first(where: { $0.severity == .error }).map { SyncIssueCode.content($0.code) }
        if document.isReadOnly { issue = .content(.unsupportedFormat) }
        if issue == nil, SyncConflictMetadata.hasInvalidOrigin(in: document) { issue = .content(.invalidMetadataType) }
        if !LibraryPath.isPrompt(file.path) { issue = .localVisibility }
        var bytes = file.bytes
        var copyID: String?
        if issue == nil {
            guard document.frontMatter.id != freshID else { throw SyncError.invalidState }
            bytes = PromptUTF8.encode(try ImportMapper.replacingIdentity(freshID, in: document,
                filename: LibraryPath.filename(destination.string)).document.source)
            bytes = try SyncConflictMetadata.settingOrigin(origin, in: bytes, filename: LibraryPath.filename(destination.string))
            copyID = freshID.rawValue
        }
        let target = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(destination.string))
        var edit = SyncLibraryEdit(id: id, kind: .rescue, path: destination.string, expected: nil, bytes: bytes,
            hash: SyncHash(bytes: bytes), transition: try SyncIdentityTransition(from: nil,
                to: PromptIdentity(path: destination.string, id: target.frontMatter.id)), mode: .normal,
            retainedBytes: file.bytes, retainedSourcePath: file.path, copyID: copyID, heldIssue: issue)
        edit.copyOrigin = origin
        try edit.validate()
        return edit
    }

    func begin(_ id: UUID, nextState: SyncState) throws { try library.beginSyncApply(id, nextState: nextState) }
    func finish(_ id: UUID) { library.endSyncApply(id) }
    func replacePermit(_ previous: UUID, with next: UUID, nextState: SyncState) throws {
        try library.replaceSyncApply(previous, with: next, nextState: nextState)
    }
    func blockForRecovery() { library.blockSyncApplyForRecovery() }
    func finishEmptyRecovery() { library.finishEmptySyncRecovery() }
    func resume(_ id: UUID, nextState: SyncState) { library.resumeSyncApply(id, nextState: nextState) }
    var pendingPermit: (id: UUID, nextState: SyncState)? { library.pendingSyncApplyPermit }
    var hasUnreadableJournal: Bool { library.hasUnreadableSyncJournal }

    func prepareMigrations(for edit: SyncLibraryEdit) throws -> [SyncKeyedMigration] {
        // A duplicate's old key belongs to the lexically first file.
        guard edit.kind != .repairDuplicate else { return [] }
        guard let transition = edit.transition, let source = transition.source,
              source != transition.destination else { return [] }
        let from = try SyncIdentifiers.promptIdentity(source)
        let to = try SyncIdentifiers.promptIdentity(transition.destination)
        return try library.syncKeyedStores().flatMap {
            try $0.prepareSyncMigration(from: from, to: to,
                rebindingHeadTo: edit.kind == .adopt ? edit.bytes : nil,
                originalBytes: (edit.expected ?? edit.adoptingSource)?.bytes)
        }
    }

    func migrate(_ migration: SyncKeyedMigration, operations: SyncFileOperations) throws {
        guard let store = try library.syncKeyedStores().first(where: { $0.syncKind == migration.store }) else {
            throw SyncError.invalidState
        }
        try store.applySyncMigration(migration, operations: operations)
    }

    func canReplan(_ step: SyncApplyStep) throws -> Bool {
        if step.completed || step.migrations.isEmpty { return true }
        // A published identity rewrite must finish its migration. An edit
        // rejected before publication may replace its untouched preparation.
        let current = try read(at: RelativePath(step.edit.path))
        if current?.identityKey == step.edit.transition?.destination,
           (step.edit.expected ?? step.edit.adoptingSource)?.identityKey != step.edit.transition?.destination { return false }
        let stores = try library.syncKeyedStores()
        for migration in step.migrations {
            guard let store = stores.first(where: { $0.syncKind == migration.store }),
                  try store.isSyncMigrationUnstarted(migration) else { return false }
        }
        return true
    }

    func apply(_ edit: SyncLibraryEdit, attempt: Attempt) throws -> SyncLibraryMutationResult {
        try edit.validate()
        return try library.withSyncLock { files in
            let current: SyncLibraryFile?
            do { current = try Self.read(files, at: edit.path) }
            catch LibraryError.conflict { return SyncLibraryMutationResult(outcome: .replanAsConflict, displacedBytes: nil) }
            if case .replay = attempt, Self.isPublished(edit, current: current) {
                if edit.kind == .trash {
                    try SyncDurability.flushParents(of: edit.path, operations: operations)
                } else {
                    // A post-rename/mode flush may have failed. Reestablish mode
                    // and checked durability instead of treating it as unchanged.
                    try operations.setMode(edit.mode, at: RelativePath(edit.path))
                    try SyncDurability.flushFileAndParents(edit.path, operations: operations)
                }
                return try SyncLibraryMutationResult(outcome: verify(edit, files: files), displacedBytes: nil, effect: .applied)
            }
            guard Self.matches(edit.expected, current: current) else {
                return SyncLibraryMutationResult(outcome: .replanAsConflict, displacedBytes: nil)
            }
            if let source = edit.adoptingSource {
                do {
                    guard try Self.matches(source, current: Self.read(files, at: source.path)) else {
                        return SyncLibraryMutationResult(outcome: .replanAsConflict, displacedBytes: nil)
                    }
                } catch LibraryError.conflict {
                    return SyncLibraryMutationResult(outcome: .replanAsConflict, displacedBytes: nil)
                }
            }
            let expectation: SyncFileExpectation = current.map { .matching(stamp: $0.stamp, bytes: $0.bytes) } ?? .absent
            var displaced: Data?
            do {
                if edit.kind == .trash {
                    try operations.trash(at: RelativePath(edit.path), expecting: expectation)
                } else {
                    // Validation parses only for safety/identity; these exact
                    // server bytes never pass through PromptCodec.write.
                    displaced = try operations.publish(edit.bytes!, at: RelativePath(edit.path),
                        expecting: expectation, mode: edit.mode).displacedBytes
                }
            } catch let error as SyncFileOperationError {
                if error.code == .changed || (error.effect == .unchanged && error.code == .occupied) {
                    return SyncLibraryMutationResult(outcome: .replanAsConflict, displacedBytes: error.displacedBytes,
                                                     effect: error.effect)
                }
                throw error
            }
            return try SyncLibraryMutationResult(outcome: verify(edit, files: files), displacedBytes: displaced, effect: .applied)
        }
    }

    func verify(_ edit: SyncLibraryEdit) throws -> SyncLibraryMutationOutcome {
        try library.withSyncLock { files in try verify(edit, files: files) }
    }

    private func verify(_ edit: SyncLibraryEdit, files: FileStore) throws -> SyncLibraryMutationOutcome {
        do { return Self.isPublished(edit, current: try Self.read(files, at: edit.path)) ? .applied : .replanAsConflict }
        catch LibraryError.conflict { return .replanAsConflict }
    }

    private static func matches(_ expected: SyncLibraryFile?, current: SyncLibraryFile?) -> Bool {
        guard let expected else { return current == nil }
        guard let current else { return false }
        return current.stamp == expected.stamp && current.identityKey == expected.identityKey
            && current.hash == expected.hash && current.bytes == expected.bytes
    }

    private static func isPublished(_ edit: SyncLibraryEdit, current: SyncLibraryFile?) -> Bool {
        if edit.kind == .trash { return current == nil }
        guard let current else { return false }
        return current.identityKey == edit.transition?.destination && current.hash == edit.hash && current.bytes == edit.bytes
    }

    private static func read(_ files: FileStore, at path: String) throws -> SyncLibraryFile? {
        try FileStorePath.validate(path)
        guard let stamp = try files.stamp(at: path) else { return nil }
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound { throw LibraryError.conflict }
        guard try files.stamp(at: path) == stamp else { throw LibraryError.conflict }
        return try SyncLibraryFile(path: path, stamp: stamp, bytes: bytes)
    }
}
