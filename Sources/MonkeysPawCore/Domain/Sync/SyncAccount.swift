import Foundation

/// A canonical deployment base supplied by the URL-policy layer (Y3).
/// This syntax check is not an HTTP transport authorization policy.
struct SyncAccountIdentity: Hashable, Sendable, Codable {
    let serverURL: URL
    let userID: ULID

    init(serverURL: String, userID: ULID) throws {
        guard !serverURL.isEmpty, !serverURL.contains("\\"),
              !serverURL.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              var url = URLComponents(string: serverURL),
              let scheme = url.scheme, ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, host == host.lowercased(), !host.hasSuffix("."),
              !host.contains("%"), url.url?.host?.unicodeScalars.allSatisfy({ $0.isASCII }) == true,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65_535).contains($0) }) ?? true,
              url.port != (scheme == "https" ? 443 : 80) else { throw SyncError.invalidAccount }
        let path = url.path
        guard path.isEmpty || (path.utf8.first == 47 && !path.hasSuffix("/")),
              !path.contains("\\"), !path.contains("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.utf8.split(separator: 47).contains(where: { $0.elementsEqual([46]) || $0.elementsEqual([46, 46]) }),
              !url.percentEncodedPath.lowercased().contains("%2f"),
              !path.hasSuffix("/api/v1") else { throw SyncError.invalidAccount }
        url.scheme = scheme
        url.host = host
        guard let normalized = url.url, normalized.absoluteString.utf8.elementsEqual(serverURL.utf8) else {
            throw SyncError.invalidAccount
        }
        self.serverURL = normalized
        self.userID = userID
    }

    private enum CodingKeys: String, CodingKey { case serverURL = "server_url", userID = "user_id" }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(serverURL: value.decode(String.self, forKey: .serverURL),
                      userID: SyncIdentifiers.ulid(value.decode(String.self, forKey: .userID)))
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(serverURL.absoluteString, forKey: .serverURL)
        try value.encode(userID.rawValue, forKey: .userID)
    }
}

/// Exact lexical identity. Composition supplies the selected root's absolute
/// path; Core does not resolve symlinks or consult the filesystem.
struct SyncLibraryRoot: Hashable, Sendable, Codable {
    private let spelling: RelativePath
    var path: String { spelling.string }

    init(_ path: String) throws {
        guard FileStorePath.isValid(path, mode: .absolute) else { throw SyncError.invalidRoot }
        spelling = RelativePath(path)
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}

struct SyncLibraryIdentity: Hashable, Sendable {
    let account: SyncAccountIdentity
    let root: SyncLibraryRoot
}

/// No credential or invitation bytes. connectionID names the device secret;
/// deviceID is the distinct server-issued ULID.
struct SyncAccount: Equatable, Sendable, Codable {
    let identity: SyncAccountIdentity
    let username: String
    let deviceID: ULID
    let deviceName: String
    let connectionID: UUID

    var secretAccount: SecretAccount {
        .device(connectionID)
    }

    init(identity: SyncAccountIdentity, username: String, deviceID: ULID,
         deviceName: String, connectionID: UUID) throws {
        guard (try? SyncAPISchema.username.validate(.string(username))) != nil,
              (try? SyncAPIString(minimumLength: 1, maximumLength: 255).validate(deviceName)) != nil else {
            throw SyncError.invalidState
        }
        self.identity = identity
        self.username = username
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.connectionID = connectionID
    }

    private struct Payload: Codable {
        let server_url: String
        let user_id: String
        let username: String
        let device_id: String
        let device_name: String
        let connection_id: String
    }

    init(from decoder: Decoder) throws {
        let value = try Payload(from: decoder)
        try self.init(identity: SyncAccountIdentity(serverURL: value.server_url,
                                                   userID: SyncIdentifiers.ulid(value.user_id)),
                      username: value.username, deviceID: SyncIdentifiers.ulid(value.device_id),
                      deviceName: value.device_name, connectionID: SyncIdentifiers.uuid(value.connection_id))
    }

    func encode(to encoder: Encoder) throws {
        try Payload(server_url: identity.serverURL.absoluteString, user_id: identity.userID.rawValue,
                    username: username, device_id: deviceID.rawValue, device_name: deviceName,
                    connection_id: connectionID.uuidString.lowercased()).encode(to: encoder)
    }
}

struct SyncManagedFolder: Equatable, Sendable, Codable {
    let owner: SyncAccountIdentity
    let folder: String

    init(owner: SyncAccountIdentity, folder: String) throws {
        try SyncIdentifiers.folder(folder)
        self.owner = owner
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey { case owner, folder }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(owner: value.decode(SyncAccountIdentity.self, forKey: .owner),
                      folder: value.decode(String.self, forKey: .folder))
    }
}

/// Holds invalid/forensic bytes too. A content edit does not release a hold.
/// Scanner/rescue code migrates path/identity; only an inclusion intent removes it.
struct SyncHeldPrompt: Equatable, Sendable, Codable {
    let identity: PromptIdentity
    let path: RelativePath
    let sourceAccount: SyncAccountIdentity
    let contentHash: SyncHash

    init(identity: PromptIdentity, path: RelativePath, sourceAccount: SyncAccountIdentity,
         contentHash: SyncHash) throws {
        guard (try? identity.storageKey) != nil,
              FileStorePath.isValid(path.string, mode: .relative) else { throw SyncError.invalidState }
        self.identity = identity
        self.path = path
        self.sourceAccount = sourceAccount
        self.contentHash = contentHash
    }

    private enum CodingKeys: String, CodingKey {
        case identity, path, sourceAccount = "source_account", contentHash = "content_hash"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        let key = try value.decode(String.self, forKey: .identity)
        try self.init(identity: SyncIdentifiers.promptIdentity(key), path: RelativePath(value.decode(String.self, forKey: .path)),
                      sourceAccount: value.decode(SyncAccountIdentity.self, forKey: .sourceAccount),
                      contentHash: value.decode(SyncHash.self, forKey: .contentHash))
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(identity.storageKey, forKey: .identity)
        try value.encode(path.string, forKey: .path)
        try value.encode(sourceAccount, forKey: .sourceAccount)
        try value.encode(contentHash, forKey: .contentHash)
    }
}

struct SyncLibraryBinding: Equatable, Sendable, Codable {
    let root: SyncLibraryRoot
    var owner: SyncAccountIdentity
    var managedFolders: [ULID: SyncManagedFolder]
    var holds: [SyncHeldPrompt]

    init(root: SyncLibraryRoot, owner: SyncAccountIdentity,
         managedFolders: [ULID: SyncManagedFolder] = [:], holds: [SyncHeldPrompt] = []) throws {
        self.root = root
        self.owner = owner
        self.managedFolders = managedFolders
        self.holds = holds
        try validate()
    }

    /// Y7 must evaluate holds before any upload decision, using the raw-byte hash.
    /// Hash matching holds an unedited rename. Y11 must assign ULIDs to idless
    /// held files during the account transition through ordinary identity
    /// assignment and migrate their holds, so rename plus edit stays held by ID.
    func isHeld(identity: PromptIdentity, path: RelativePath, contentHash: SyncHash) -> Bool {
        holds.contains { $0.identity == identity || $0.path == path || $0.contentHash == contentHash }
    }

    func validate() throws {
        guard Set(holds.map(\.path)).count == holds.count else { throw SyncError.invalidState }
        let folders = managedFolders.values.map { SyncPathCaseFold.fold($0.folder) }
        guard Set(folders).count == folders.count else { throw SyncError.invalidState }
    }

    private struct Payload: Codable {
        let library_root: SyncLibraryRoot
        let owner: SyncAccountIdentity
        let managed_folders: [String: SyncManagedFolder]
        let holds: [SyncHeldPrompt]
    }

    init(from decoder: Decoder) throws {
        let value = try Payload(from: decoder)
        let folders = try Dictionary(uniqueKeysWithValues: value.managed_folders.map { (try SyncIdentifiers.ulid($0.key), $0.value) })
        try self.init(root: value.library_root, owner: value.owner, managedFolders: folders, holds: value.holds)
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        try Payload(library_root: root, owner: owner,
                    managed_folders: Dictionary(uniqueKeysWithValues: managedFolders.map { ($0.key.rawValue, $0.value) }),
                    holds: holds).encode(to: encoder)
    }
}
