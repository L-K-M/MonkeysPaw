import Foundation

/// Full lowercase SHA-256 of stored canonical bytes, never adoption equality.
struct SyncHash: Hashable, Sendable, Codable {
    let rawValue: String

    init(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SyncError.invalidHash
        }
        rawValue = value
    }

    init(bytes: Data) { rawValue = SHA256.hexDigest(bytes) }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The wire key without mutable group metadata. IDs retain Core's ULID type.
enum SyncScopeKey: Hashable, Sendable, Codable {
    case user(ULID)
    case group(ULID)

    var rawValue: String {
        switch self {
        case .user(let id): return "user:" + id.rawValue
        case .group(let id): return "group:" + id.rawValue
        }
    }

    var pathScope: SyncPathValidator.Scope {
        switch self {
        case .user: return .user
        case .group: return .group
        }
    }

    init(_ value: String) throws {
        guard (try? SyncAPIString(format: .scopeKey).validate(value)) != nil else { throw SyncError.invalidState }
        let parts = value.split(separator: ":")
        let id = try SyncIdentifiers.ulid(String(parts[1]))
        self = parts[0] == "user" ? .user(id) : .group(id)
    }

    init(_ identity: SyncAPI.ScopeIdentity) throws { try self.init(identity.key) }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SyncPromptOrigin: Equatable, Sendable, Codable {
    case conflictOf(ULID)
    case rescued

    private enum CodingKeys: String, CodingKey { case kind, promptID = "prompt_id" }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        switch try value.decode(String.self, forKey: .kind) {
        case "conflict_of": self = .conflictOf(try SyncIdentifiers.ulid(value.decode(String.self, forKey: .promptID)))
        case "rescued":
            guard !value.contains(.promptID) else { throw SyncError.invalidState }
            self = .rescued
        default: throw SyncError.invalidState
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conflictOf(let id):
            try value.encode("conflict_of", forKey: .kind)
            try value.encode(id.rawValue, forKey: .promptID)
        case .rescued: try value.encode("rescued", forKey: .kind)
        }
    }
}

struct SyncGroupState: Equatable, Sendable, Codable {
    let name: String
    /// One NFC directory segment below Groups/, not a rooted prompt path.
    let folder: String
    let role: SyncAPI.Role

    init(name: String, folder: String, role: SyncAPI.Role) throws {
        guard (try? SyncAPIString(minimumLength: 1, maximumLength: 255).validate(name)) != nil else {
            throw SyncError.invalidState
        }
        try SyncIdentifiers.folder(folder)
        self.name = name
        self.folder = folder
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case name, folder, role }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: value.decode(String.self, forKey: .name),
                      folder: value.decode(String.self, forKey: .folder),
                      role: value.decode(SyncAPI.Role.self, forKey: .role))
    }
}

struct SyncPromptState: Equatable, Sendable, Codable {
    let scope: SyncScopeKey
    let path: RelativePath
    /// Zero means a local create has not been acknowledged by the server.
    let rev: Int64
    /// The acknowledged full-byte baseline; every rev-zero create has none.
    let canonicalHash: SyncHash?
    let origin: SyncPromptOrigin?
    let lastError: SyncPromptError?

    init(scope: SyncScopeKey, path: RelativePath, rev: Int64, canonicalHash: SyncHash? = nil,
         origin: SyncPromptOrigin? = nil, lastError: SyncPromptError? = nil) throws {
        guard rev >= 0, rev == 0 ? canonicalHash == nil : canonicalHash != nil,
              origin == nil || scope.pathScope == .user else { throw SyncError.invalidState }
        if rev == 0 {
            // A local candidate may have a repairable wire-path issue; it is
            // never an acknowledged baseline or authorization to apply a pull.
            guard FileStorePath.isValid(path.string, mode: .relative) else { throw SyncError.invalidState }
        } else {
            guard let validated = try? SyncPathValidator.validate(path.string, scope: scope.pathScope),
                  validated.path.utf8.elementsEqual(path.string.utf8) else { throw SyncError.invalidState }
        }
        self.scope = scope
        self.path = path
        self.rev = rev
        self.canonicalHash = canonicalHash
        self.origin = origin
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case scope = "scope_key", path, rev, canonicalHash = "canonical_hash", origin, lastError = "last_error"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: value.decode(SyncScopeKey.self, forKey: .scope),
                      path: RelativePath(value.decode(String.self, forKey: .path)),
                      rev: value.decode(Int64.self, forKey: .rev),
                      canonicalHash: value.decodeIfPresent(SyncHash.self, forKey: .canonicalHash),
                      origin: value.decodeIfPresent(SyncPromptOrigin.self, forKey: .origin),
                      lastError: value.decodeIfPresent(SyncPromptError.self, forKey: .lastError))
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(scope, forKey: .scope)
        try value.encode(path.string, forKey: .path)
        try value.encode(rev, forKey: .rev)
        try value.encode(canonicalHash, forKey: .canonicalHash)
        // Null replaces the old optional value during unknown-field merging.
        try value.encode(origin, forKey: .origin)
        try value.encode(lastError, forKey: .lastError)
    }
}

struct SyncState: Equatable, Sendable, Codable {
    /// The API's explicit snapshot reset request, not an interpreted feed cursor.
    static let snapshotResetCursor = "0"
    let binding: SyncLibraryIdentity
    var databaseID: UUID?
    var cursors: [SyncScopeKey: String]
    var groups: [ULID: SyncGroupState]
    var prompts: [PromptIdentity: SyncPromptState]
    private(set) var favorites: [PromptIdentity: Bool]
    var version: Int { Limits.syncStateVersion }

    init(binding: SyncLibraryIdentity, databaseID: UUID? = nil,
         cursors: [SyncScopeKey: String] = [:], groups: [ULID: SyncGroupState] = [:],
         prompts: [PromptIdentity: SyncPromptState] = [:], favorites: [PromptIdentity: Bool] = [:]) throws {
        self.binding = binding
        self.databaseID = databaseID
        self.cursors = cursors
        self.groups = groups
        self.prompts = prompts
        self.favorites = favorites
        try validate()
    }

    mutating func applyGroupFavorite(_ favorite: Bool?, for id: PromptIdentity) throws {
        guard let favorite else { return }
        guard let prompt = prompts[id], case .group = prompt.scope else { throw SyncError.invalidState }
        favorites[id] = favorite ? true : nil
    }

    func validate() throws {
        func check(_ scope: SyncScopeKey) throws {
            switch scope {
            case .user(let id): guard id == binding.account.userID else { throw SyncError.invalidScope }
            case .group(let id): guard groups[id] != nil else { throw SyncError.invalidScope }
            }
        }
        for (scope, cursor) in cursors {
            try check(scope)
            guard !cursor.isEmpty else { throw SyncError.invalidState }
        }
        var folders = Set<String>()
        for group in groups.values {
            guard folders.insert(SyncPathCaseFold.fold(group.folder)).inserted else { throw SyncError.invalidState }
        }
        for (identity, prompt) in prompts {
            guard (try? identity.storageKey) != nil else { throw SyncError.invalidState }
            if case .local = identity, prompt.rev != 0 { throw SyncError.invalidState }
            try check(prompt.scope)
            if let error = prompt.lastError {
                // A failed move may fingerprint a different destination scope.
                if case .user(let id) = error.fingerprint.scope, id != binding.account.userID {
                    throw SyncError.invalidScope
                }
            }
        }
        for (id, favorite) in favorites {
            guard favorite, let prompt = prompts[id], case .group = prompt.scope else { throw SyncError.invalidState }
        }
    }

    private struct Payload: Codable {
        let version: Int
        let server_url: String
        let user_id: String
        let library_root: SyncLibraryRoot
        let database_id: String?
        let cursors: [String: String]
        let groups: [String: SyncGroupState]
        let prompts: [String: SyncPromptState]
        let favorites: [String: Bool]

        private enum CodingKeys: String, CodingKey {
            case version, server_url, user_id, library_root, database_id, cursors, groups, prompts, favorites
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.container(keyedBy: CodingKeys.self)
            try value.encode(version, forKey: .version)
            try value.encode(server_url, forKey: .server_url)
            try value.encode(user_id, forKey: .user_id)
            try value.encode(library_root, forKey: .library_root)
            // Explicit null clears a previously persisted database UUID.
            try value.encode(database_id, forKey: .database_id)
            try value.encode(cursors, forKey: .cursors)
            try value.encode(groups, forKey: .groups)
            try value.encode(prompts, forKey: .prompts)
            try value.encode(favorites, forKey: .favorites)
        }
    }

    init(from decoder: Decoder) throws {
        let value = try Payload(from: decoder)
        try SyncIdentifiers.version(value.version, current: Limits.syncStateVersion)
        let account = try SyncAccountIdentity(serverURL: value.server_url, userID: SyncIdentifiers.ulid(value.user_id))
        let binding = SyncLibraryIdentity(account: account, root: value.library_root)
        let cursors = try Dictionary(uniqueKeysWithValues: value.cursors.map { (try SyncScopeKey($0.key), $0.value) })
        let groups = try Dictionary(uniqueKeysWithValues: value.groups.map { (try SyncIdentifiers.ulid($0.key), $0.value) })
        let prompts = try Dictionary(uniqueKeysWithValues: value.prompts.map { (try SyncIdentifiers.promptIdentity($0.key), $0.value) })
        let favorites = try Dictionary(uniqueKeysWithValues: value.favorites.map { (try SyncIdentifiers.promptIdentity($0.key), $0.value) })
        try self.init(binding: binding, databaseID: value.database_id.map(SyncIdentifiers.uuid),
                      cursors: cursors, groups: groups, prompts: prompts, favorites: favorites)
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        try Payload(version: version, server_url: binding.account.serverURL.absoluteString,
                    user_id: binding.account.userID.rawValue, library_root: binding.root,
                    database_id: databaseID?.uuidString.lowercased(),
                    cursors: Dictionary(uniqueKeysWithValues: cursors.map { ($0.key.rawValue, $0.value) }),
                    groups: Dictionary(uniqueKeysWithValues: groups.map { ($0.key.rawValue, $0.value) }),
                    prompts: Dictionary(uniqueKeysWithValues: prompts.map { (try $0.key.storageKey, $0.value) }),
                    favorites: Dictionary(uniqueKeysWithValues: favorites.map { (try $0.key.storageKey, $0.value) }))
            .encode(to: encoder)
    }
}

enum SyncIdentifiers {
    static func promptIdentity(_ key: String) throws -> PromptIdentity {
        if key.utf8.count == 64 { return .local(try SyncHash(key).rawValue) }
        return .assigned(try ulid(key))
    }

    static func ulid(_ raw: String) throws -> ULID {
        guard let id = ULID(raw), id.rawValue.utf8.elementsEqual(raw.utf8) else { throw SyncError.invalidState }
        return id
    }

    static func uuid(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { throw SyncError.invalidState }
        return id
    }

    static func version(_ version: Int, current: Int) throws {
        if version > current { throw SyncError.futureVersion(version) }
        guard version == current else { throw SyncError.unsupportedVersion(version) }
    }

    static func folder(_ folder: String) throws {
        guard !folder.utf8.contains(47), !folder.hasPrefix("."), !folder.hasPrefix("_") else {
            throw SyncError.invalidState
        }
        guard let path = try? SyncPathValidator.validate(folder + "/check.md", scope: .group),
              path.path.utf8.elementsEqual((folder + "/check.md").utf8) else { throw SyncError.invalidState }
    }
}
