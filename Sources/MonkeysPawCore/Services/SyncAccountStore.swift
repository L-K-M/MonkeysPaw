import Foundation

private struct SyncConnectionDocument: Codable {
    let version: Int
    let account: SyncAccount?

    init(account: SyncAccount?) {
        version = Limits.syncAccountVersion
        self.account = account
    }

    private enum CodingKeys: String, CodingKey { case version, account }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        version = try value.decode(Int.self, forKey: .version)
        try SyncIdentifiers.version(version, current: Limits.syncAccountVersion)
        // Explicit null is the persisted signed-out state, not missing metadata.
        guard value.contains(.account) else { throw SyncError.corruptFile }
        account = try value.decodeIfPresent(SyncAccount.self, forKey: .account)
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(version, forKey: .version)
        try value.encode(account, forKey: .account)
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

    var cachedAccount: SyncAccount? { connection.snapshot.value?.account }
    var cachedBindings: [SyncLibraryBinding] { ownership.snapshot.value?.libraries ?? [] }
    var readOnlyError: SyncError? { connection.snapshot.error ?? ownership.snapshot.error }

    func loadAccount() throws -> SyncAccount? {
        _ = try ownership.load()
        return try connection.load()?.account
    }

    func setAccount(_ account: SyncAccount?) throws {
        _ = try ownership.load()
        try connection.update { _ in SyncConnectionDocument(account: account) }
    }

    func binding(for root: SyncLibraryRoot) throws -> SyncLibraryBinding? {
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
