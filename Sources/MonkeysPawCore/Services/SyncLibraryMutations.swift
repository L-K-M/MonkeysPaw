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
    enum Kind: String, Codable { case apply, adopt, relocate, repairDuplicate, rescue, trash, mode }
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
    /// Checked source for an alternate adoption spelling or a byte-exact local
    /// relocation. Keyed state migrates before the checked source retires.
    var adoptingSource: SyncLibraryFile? = nil

    var description: String { "<sync library edit>" }
    var customMirror: Mirror { Mirror(self, children: ["edit": description]) }

    func validate() throws {
        try FileStorePath.validate(path)
        try expected?.validate()
        try adoptingSource?.validate()
        if let source = adoptingSource {
            let pathMatches = kind == .relocate ? true
                : try SyncNaming.pathKey(RelativePath(source.path)) == SyncNaming.pathKey(RelativePath(path))
            let alias = kind == .adopt && expected?.stamp == source.stamp && expected?.bytes == source.bytes
            guard (kind == .adopt || kind == .relocate), (expected == nil || alias), RelativePath(source.path) != RelativePath(path),
                  pathMatches,
                  retainedBytes == source.bytes, retainedSourcePath.map({ RelativePath($0) }) == RelativePath(source.path) else {
                throw SyncError.invalidState
            }
        }
        if kind == .relocate {
            guard let source = adoptingSource, bytes == source.bytes else { throw SyncError.invalidState }
        }
        if let expected, RelativePath(expected.path) != RelativePath(path) { throw SyncError.invalidState }
        if let retainedSourcePath { try FileStorePath.validate(retainedSourcePath) }
        if kind == .mode {
            guard let expected, bytes == expected.bytes, hash == expected.hash,
                  transition == nil, adoptingSource == nil, retainedBytes == nil, retainedSourcePath == nil,
                  copyID == nil, heldIssue == nil, copyOrigin == nil else { throw SyncError.invalidState }
            return // Modes also cover nonprompt and forensic regular files.
        }
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
        guard transition.source == (adoptingSource ?? expected)?.identityKey || assignedExternally else {
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

    func directoryIdentities() throws -> [RelativePath: FileStamp] {
        try library.withSyncLock { _ in try Self.directoryIdentities(operations) }
    }

    private static func directoryIdentities(_ operations: SyncFileOperations) throws -> [RelativePath: FileStamp] {
        var result: [RelativePath: FileStamp] = [:]
        var parents: [RelativePath?] = [nil]
        do {
            while let parent = parents.popLast() {
                for child in try operations.directories(at: parent) {
                    try FileStorePath.validate(child.string)
                    guard Self.parent(of: child) == parent, result[child] == nil else { throw SyncError.invalidState }
                    guard let identity = try operations.directoryIdentity(at: child) else { throw LibraryError.conflict }
                    result[child] = identity
                    parents.append(child)
                }
            }
        } catch let error as SyncFileOperationError where error.effect == .unchanged
            && (error.code == .notFound || error.code == .changed) {
            throw LibraryError.conflict
        }
        return result
    }

    /// A rename preserves the complete subtree, including unknown files. Fresh
    /// joined-path checks precede native mutation; occupied aliases never merge.
    func apply(_ edit: SyncDirectoryEdit) throws -> SyncLibraryMutationOutcome {
        try edit.validate()
        return try library.withSyncLock { files in
            let directories: [RelativePath: FileStamp]
            do { directories = try Self.directoryIdentities(operations) }
            catch LibraryError.conflict { return .replanAsConflict }
            if edit.kind == .reserve {
                return try vacantDirectory(edit.source, files: files, directories: directories) ? .applied : .replanAsConflict
            }
            if edit.kind == .removeEmpty {
                guard let identity = directories[edit.source] else {
                    guard try files.stamp(at: edit.source.string) == nil else { return .replanAsConflict }
                    try flushSurvivingParents(of: edit.source)
                    return .applied
                }
                guard identity == edit.identity else { return .replanAsConflict }
                do { try operations.removeEmptyDirectory(at: edit.source, expecting: identity) }
                catch let error as SyncFileOperationError where error.code == .changed || error.code == .occupied {
                    return .replanAsConflict
                }
                return .applied
            }
            guard let destination = edit.destination else { throw SyncError.invalidState }
            let positions = [edit.source] + (edit.intermediate.map { [$0] } ?? []) + [destination]
            let matches = positions.filter { directories[$0] == edit.identity }
            guard matches.count == 1, let current = matches.first else { return .replanAsConflict }
            // Refuse any second incarnation, even if it is an empty directory.
            guard positions.allSatisfy({ $0 == current || directories[$0] == nil }) else { return .replanAsConflict }
            let index = positions.firstIndex(of: current)!
            if index < positions.count - 1 {
                for target in positions[(index + 1)...] {
                    let key = try SyncNaming.pathKey(target)
                    let occupants = try files.listFiles().map { RelativePath($0.relativePath) }
                        + Array(directories.keys)
                    guard try !occupants.contains(where: {
                        guard $0 != current else { return false }
                        return try SyncNaming.pathKey($0) == key
                    }) else { return .replanAsConflict }
                }
                // Validate against the longest final wrapper, not the shorter
                // temporary name. No valid remote path is shortened here.
                for child in try files.listFiles().map({ RelativePath($0.relativePath) }) + Array(directories.keys)
                    where child.string.utf8.starts(with: (current.string + "/").utf8) {
                    let suffix = String(decoding: child.string.utf8.dropFirst(current.string.utf8.count), as: UTF8.self)
                    for target in positions[(index + 1)...] { try FileStorePath.validate(target.string + suffix) }
                }
                var source = current
                for target in positions[(index + 1)...] {
                    do { try operations.renameDirectory(from: source, to: target) }
                    catch let error as SyncFileOperationError where error.effect == .unchanged
                        && (error.code == .changed || error.code == .occupied) { return .replanAsConflict }
                    guard try operations.directoryIdentity(at: target) == edit.identity else { return .replanAsConflict }
                    source = target
                }
            }
            try operations.flushDirectory(at: destination)
            try flushSurvivingParents(of: edit.source)
            return .applied
        }
    }

    func verify(_ edit: SyncDirectoryEdit) throws -> SyncLibraryMutationOutcome {
        try edit.validate()
        return try library.withSyncLock { files in
            let directories: [RelativePath: FileStamp]
            do { directories = try Self.directoryIdentities(operations) }
            catch LibraryError.conflict { return .replanAsConflict }
            if edit.kind == .reserve {
                return try vacantDirectory(edit.source, files: files, directories: directories) ? .applied : .replanAsConflict
            }
            if edit.kind == .removeEmpty {
                return try directories[edit.source] == nil && files.stamp(at: edit.source.string) == nil ? .applied : .replanAsConflict
            }
            guard let destination = edit.destination, directories[destination] == edit.identity,
                  directories[edit.source] == nil,
                  edit.intermediate.map({ directories[$0] == nil }) ?? true else { return .replanAsConflict }
            return .applied
        }
    }

    private func vacantDirectory(_ path: RelativePath, files: FileStore, directories: [RelativePath: FileStamp]) throws -> Bool {
        let key = try SyncNaming.pathKey(path)
        let paths = try files.listFiles().map { RelativePath($0.relativePath) } + Array(directories.keys)
        guard try !paths.contains(where: { try SyncNaming.pathKey($0) == key }) else { return false }
        // A link is omitted by listing but must still fail the direct probe.
        return try files.stamp(at: path.string) == nil
    }

    private static func parent(of path: RelativePath) -> RelativePath? {
        guard let slash = path.string.utf8.lastIndex(of: 47) else { return nil }
        return RelativePath(String(decoding: path.string.utf8[..<slash], as: UTF8.self))
    }

    private func flushSurvivingParents(of path: RelativePath) throws {
        var parent = Self.parent(of: path)
        while let directory = parent {
            if try operations.directoryIdentity(at: directory) != nil { try operations.flushDirectory(at: directory) }
            parent = Self.parent(of: directory)
        }
        try operations.flushDirectory(at: nil)
    }

    func publication(_ bytes: Data, at path: RelativePath, expecting expected: SyncLibraryFile?,
                     transition: SyncIdentityTransition, mode: SyncFileMode = .normal,
                     kind: SyncLibraryEdit.Kind = .apply, markerIssue: SyncIssueCode? = nil,
                     adoptingSource: SyncLibraryFile? = nil, id: UUID = UUID()) throws -> SyncLibraryEdit {
        let source = adoptingSource ?? expected
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

    func mode(_ mode: SyncFileMode, for file: SyncLibraryFile, id: UUID = UUID()) throws -> SyncLibraryEdit {
        let edit = SyncLibraryEdit(id: id, kind: .mode, path: file.path, expected: file, bytes: file.bytes,
            hash: file.hash, transition: nil, mode: mode, retainedBytes: nil, retainedSourcePath: nil,
            copyID: nil, heldIssue: nil)
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
    func stateCommitted(_ id: UUID) throws { try library.markSyncApplyStateCommitted(id) }
    func finish(_ id: UUID) { library.endSyncApply(id) }
    func replacePermit(_ previous: UUID, with next: UUID, nextState: SyncState) throws {
        try library.replaceSyncApply(previous, with: next, nextState: nextState)
    }
    func blockForRecovery() { library.blockSyncApplyForRecovery() }
    func finishEmptyRecovery() { library.finishEmptySyncRecovery() }
    func resume(_ id: UUID, nextState: SyncState) { library.resumeSyncApply(id, nextState: nextState) }
    var pendingPermit: SyncLibraryWriteGate.Permit? { library.pendingSyncApplyPermit }
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

    func prepareMigrations(for edit: SyncDirectoryEdit) throws -> [SyncKeyedMigration] {
        try edit.validate()
        return try edit.identityTransitions().flatMap { transition in
            guard let source = transition.source else { throw SyncError.invalidState }
            return try library.syncKeyedStores().flatMap {
                try $0.prepareSyncMigration(from: SyncIdentifiers.promptIdentity(source),
                    to: SyncIdentifiers.promptIdentity(transition.destination), rebindingHeadTo: nil, originalBytes: nil)
            }
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

    func canReplan(_ step: SyncDirectoryStep) throws -> Bool {
        if step.completed || step.edit.kind != .rename { return true }
        let directories: [RelativePath: FileStamp]
        do { directories = try directoryIdentities() }
        catch LibraryError.conflict { return false }
        guard directories[step.edit.source] == step.edit.identity else { return false }
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
                    try flushSurvivingParents(of: RelativePath(edit.path))
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
                } else if edit.kind == .mode {
                    try operations.setMode(edit.mode, at: RelativePath(edit.path))
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
        if edit.kind == .mode {
            return current.identityKey == edit.expected?.identityKey && current.hash == edit.hash && current.bytes == edit.bytes
        }
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
