import Foundation

enum SyncAccountActivation: String, Codable, Sendable { case inactive, enabled }

struct SyncConnectionDocument: Codable {
    let version: Int
    let account: SyncAccount?
    let activation: SyncAccountActivation
    let cleanupConnections: [UUID]

    init(account: SyncAccount?, activation: SyncAccountActivation = .enabled, cleanupConnections: [UUID] = []) {
        version = Limits.syncAccountVersion
        self.account = account
        self.activation = account == nil ? .inactive : activation
        self.cleanupConnections = cleanupConnections
    }

    private enum CodingKeys: String, CodingKey { case version, account, activation, cleanupConnections = "cleanup_connections" }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        version = try value.decode(Int.self, forKey: .version)
        try SyncIdentifiers.version(version, current: Limits.syncAccountVersion)
        // Explicit null is the persisted signed-out state, not missing metadata.
        guard value.contains(.account) else { throw SyncError.corruptFile }
        account = try value.decodeIfPresent(SyncAccount.self, forKey: .account)
        activation = try value.decodeIfPresent(SyncAccountActivation.self, forKey: .activation)
            ?? (account == nil ? .inactive : .enabled)
        let ids = try value.decodeIfPresent([String].self, forKey: .cleanupConnections) ?? []
        cleanupConnections = try ids.map(SyncIdentifiers.uuid)
        guard Set(cleanupConnections).count == cleanupConnections.count,
              account != nil || activation == .inactive,
              activation != .enabled || account.map({ !cleanupConnections.contains($0.connectionID) }) == true else {
            throw SyncError.invalidState
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(version, forKey: .version)
        try value.encode(account, forKey: .account)
        try value.encode(activation, forKey: .activation)
        try value.encode(cleanupConnections.map { $0.uuidString.lowercased() }, forKey: .cleanupConnections)
    }
}

private struct SyncBindingDocument: Codable {
    let version: Int
    let libraries: [SyncLibraryBinding]

    init(libraries: [SyncLibraryBinding]) throws {
        guard Set(libraries.map(\.root)).count == libraries.count else { throw SyncError.invalidState }
        for library in libraries { try library.validate() }
        version = Limits.syncBindingVersion
        self.libraries = libraries
    }

    private enum CodingKeys: String, CodingKey { case version, libraries }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try SyncIdentifiers.version(value.decode(Int.self, forKey: .version), current: Limits.syncBindingVersion)
        try self.init(libraries: value.decode([SyncLibraryBinding].self, forKey: .libraries))
    }
}

/// Connection and library ownership are separate private app-data records.
/// Clearing a connection preserves all roots' ownership and holds. These writes
/// are not one transaction; Y11 owns journaled transitions/secret compensation.
public final class SyncAccountStore: @unchecked Sendable {
    private let connection: SyncPersistence<SyncConnectionDocument>
    private let ownership: SyncPersistence<SyncBindingDocument>

    public init(files: FileStore, operations: SyncFileOperations) {
        connection = SyncPersistence(files: files, operations: operations,
                                     path: "sync/account.json", version: Limits.syncAccountVersion)
        ownership = SyncPersistence(files: files, operations: operations,
                                    path: "sync/binding.json", version: Limits.syncBindingVersion)
    }

    /// Cached diagnostics may be stale until load; readOnlyError blocks use for
    /// sync decisions. Each snapshot is locked, not a cross-document transaction.
    var cachedAccount: SyncAccount? { connection.snapshot.value?.account }
    var cachedBindings: [SyncLibraryBinding] { ownership.snapshot.value?.libraries ?? [] }
    var readOnlyError: SyncError? { connection.snapshot.error ?? ownership.snapshot.error }

    func loadAccount() throws -> SyncAccount? {
        try loadConnection().account
    }

    func loadConnection() throws -> SyncConnectionDocument {
        _ = try ownership.load()
        return try connection.load() ?? SyncConnectionDocument(account: nil)
    }

    /// An explicit login may reflush uncertain metadata on the same live graph.
    /// This does not release the library's journal recovery gate.
    func recoverConnection() throws -> SyncConnectionDocument {
        _ = try ownership.recover()
        return try connection.recover() ?? SyncConnectionDocument(account: nil)
    }

    /// Sign-out must still locate credentials when independent ownership is
    /// corrupt. This grants no permission to sync, reset ownership or edit files.
    func connectionForSignOut() throws -> SyncConnectionDocument {
        try connection.load() ?? SyncConnectionDocument(account: nil)
    }

    func setAccount(_ account: SyncAccount?, activation: SyncAccountActivation = .enabled,
                    retiring ids: [UUID] = []) throws {
        _ = try ownership.load()
        try connection.update { current in
            let cleanup = Set((current?.cleanupConnections ?? []) + ids)
            return SyncConnectionDocument(account: account, activation: activation,
                cleanupConnections: cleanup.sorted { $0.uuidString < $1.uuidString })
        }
    }

    /// Persist this before destructive transitions or remote logout. A surviving
    /// environment token cannot turn an inactive connection back on at startup.
    func disableAutomaticResume() throws {
        try connection.update { current in
            SyncConnectionDocument(account: current?.account, activation: .inactive,
                                   cleanupConnections: current?.cleanupConnections ?? [])
        }
    }

    /// Explicit compensation/sign-out can recover uncertain connection metadata;
    /// independent library ownership and a pending apply journal stay untouched.
    func saveInactive(_ account: SyncAccount?, retiring ids: [UUID]) throws {
        let cached = connection.snapshot.value
        _ = try connection.recover()
        try connection.update { current in
            let cleanup = Set((current?.cleanupConnections ?? cached?.cleanupConnections ?? []) + ids)
            return SyncConnectionDocument(account: account, activation: .inactive,
                cleanupConnections: cleanup.sorted { $0.uuidString < $1.uuidString })
        }
    }

    func finishSecretCleanup(_ id: UUID) throws {
        try connection.update { current in
            SyncConnectionDocument(account: current?.account, activation: current?.activation ?? .inactive,
                cleanupConnections: (current?.cleanupConnections ?? []).filter { $0 != id })
        }
    }

    func binding(for root: SyncLibraryRoot) throws -> SyncLibraryBinding? {
        // Ownership reads ignore connection health so recovery can still find
        // holds after sign-out or corrupt metadata. Account reads/edits and
        // ownership edits require both records to be healthy.
        try ownership.load()?.libraries.first { $0.root == root }
    }

    func updateBinding(for root: SyncLibraryRoot,
                       _ change: (SyncLibraryBinding?) throws -> SyncLibraryBinding) throws {
        _ = try connection.load()
        try ownership.update { current in
            var libraries = current?.libraries ?? []
            let index = libraries.firstIndex { $0.root == root }
            let next = try change(index.map { libraries[$0] })
            guard next.root == root else { throw SyncError.bindingMismatch }
            if let index { libraries[index] = next }
            else { libraries.append(next) }
            return try SyncBindingDocument(libraries: libraries)
        }
    }

    /// Explicit metadata reset leaves the independent ownership file intact.
    func resetAccount() throws { try connection.reset(SyncConnectionDocument(account: nil)) }
    /// Destructive ownership recovery requires an explicit intent of its own.
    func resetBindings() throws { try ownership.reset(SyncBindingDocument(libraries: [])) }
}
