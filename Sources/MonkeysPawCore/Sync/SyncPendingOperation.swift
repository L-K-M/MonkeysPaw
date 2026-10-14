import Foundation

/// One immutable, account/root-bound request. In-flight edits cannot change the
/// sent baseline used to recognize a lost acknowledgement after restart.
struct SyncPendingOperation: Codable, CustomStringConvertible, CustomReflectable {
    let binding: SyncLibraryIdentity
    let intent: SyncConflictIntent
    let libraryPath: RelativePath
    let file: SyncLibraryFile?
    let recorded: SyncPromptState?

    var description: String { "<pending sync push>" }
    var customMirror: Mirror { Mirror(self, children: ["push": description]) }

    init(binding: SyncLibraryIdentity, intent: SyncConflictIntent, libraryPath: RelativePath,
         file: SyncLibraryFile?, recorded: SyncPromptState?) throws {
        try FileStorePath.validate(libraryPath.string)
        try file?.validate()
        guard intent.baseRev == (recorded?.rev ?? 0),
              intent.operation != .move || intent.sentBytes != nil,
              intent.operation == .delete ? file == nil : file?.path == libraryPath.string,
              file == nil || file?.identityKey == intent.id.rawValue,
              intent.fingerprint.contentHash == SyncHash(bytes: file?.bytes ?? Data()) else {
            throw SyncError.invalidState
        }
        if case .user(let owner) = intent.scope, owner != binding.account.userID { throw SyncError.bindingMismatch }
        self.binding = binding
        self.intent = intent
        self.libraryPath = libraryPath
        self.file = file
        self.recorded = recorded
    }

    private enum CodingKeys: String, CodingKey {
        case version, account, root, id, operation, baseRev, scope, path, sentBytes, sentHash
        case fingerprint, libraryPath, file, recorded
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try SyncIdentifiers.version(value.decode(Int.self, forKey: .version), current: Limits.syncPushJournalVersion)
        let binding = try SyncLibraryIdentity(account: value.decode(SyncAccountIdentity.self, forKey: .account),
                                             root: value.decode(SyncLibraryRoot.self, forKey: .root))
        let file = try value.decodeIfPresent(SyncLibraryFile.self, forKey: .file)
        let fingerprint = try value.decode(SyncInputFingerprint.self, forKey: .fingerprint)
        let intent = try SyncConflictIntent(id: SyncIdentifiers.ulid(value.decode(String.self, forKey: .id)),
            operation: value.decode(SyncOperation.self, forKey: .operation),
            baseRev: value.decode(Int64.self, forKey: .baseRev), scope: value.decode(SyncScopeKey.self, forKey: .scope),
            path: RelativePath(value.decode(String.self, forKey: .path)),
            sentBytes: value.decodeIfPresent(Data.self, forKey: .sentBytes), inputBytes: file?.bytes ?? Data(),
            accessGeneration: fingerprint.accessGeneration)
        guard intent.fingerprint == fingerprint,
              intent.sentHash == (try value.decodeIfPresent(SyncHash.self, forKey: .sentHash)) else {
            throw SyncError.invalidState
        }
        try self.init(binding: binding, intent: intent,
            libraryPath: RelativePath(value.decode(String.self, forKey: .libraryPath)), file: file,
            recorded: value.decodeIfPresent(SyncPromptState.self, forKey: .recorded))
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(Limits.syncPushJournalVersion, forKey: .version)
        try value.encode(binding.account, forKey: .account)
        try value.encode(binding.root, forKey: .root)
        try value.encode(intent.id.rawValue, forKey: .id)
        try value.encode(intent.operation, forKey: .operation)
        try value.encode(intent.baseRev, forKey: .baseRev)
        try value.encode(intent.scope, forKey: .scope)
        try value.encode(intent.path.string, forKey: .path)
        try value.encode(intent.sentBytes, forKey: .sentBytes)
        try value.encode(intent.sentHash, forKey: .sentHash)
        try value.encode(intent.fingerprint, forKey: .fingerprint)
        try value.encode(libraryPath.string, forKey: .libraryPath)
        try value.encode(file, forKey: .file)
        try value.encode(recorded, forKey: .recorded)
    }
}

/// Private 0600 publication and checked file/directory flush precede HTTP.
/// A failed write or deletion blocks further pushes until recovery/restart.
final class SyncPendingOperationStore {
    private let files: FileStore
    private let operations: SyncFileOperations
    private let persistence: SyncPersistence<SyncPendingOperation>

    init(files: FileStore, operations: SyncFileOperations) {
        self.files = files
        self.operations = operations
        persistence = SyncPersistence(files: files, operations: operations,
            path: "sync/push.json", version: Limits.syncPushJournalVersion)
    }

    func load(for binding: SyncLibraryIdentity) throws -> SyncPendingOperation? {
        let pending = try persistence.load()
        guard pending == nil || pending?.binding == binding else { throw SyncError.bindingMismatch }
        return pending
    }

    var snapshot: SyncStoreSnapshot<SyncPendingOperation> { persistence.snapshot }

    func save(_ pending: SyncPendingOperation) throws {
        try persistence.update { old in
            guard old == nil else { throw SyncError.invalidState }
            return pending
        }
    }

    func clear() throws { try persistence.reset(nil) }

    /// A hold cancels further sending, but cannot erase possibly-sent bytes.
    /// Retain exact facts durably before releasing the single active slot.
    func retainHeld(_ request: SyncPendingOperation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        guard bytes.count <= Limits.syncRecordMaxBytes else { throw SyncError.invalidState }
        let path = "sync/retained/push-" + SyncHash(bytes: bytes).rawValue + ".json"
        do {
            if try files.stamp(at: path) == nil { try files.writePrivate(bytes, at: path) }
            else if try files.read(at: path) != bytes { throw SyncError.invalidState }
            try SyncDurability.flushFileAndParents(path, operations: operations)
        } catch let error as SyncError { throw error }
        catch let error as SyncFileOperationError { throw error }
        catch let error as FileStoreError { throw SyncError.writeFailed(error) }
        catch { throw SyncError.writeFailed(.ioFailure) }
    }
}
