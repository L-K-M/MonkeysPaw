import Foundation

public enum PromptIdentity: Hashable, Sendable, CustomStringConvertible {
    /// Lowercase SHA-256 of the relative path's exact UTF-8 bytes. Device-local.
    case local(String)
    case assigned(ULID)

    public var description: String { "<prompt identity>" }

    init(path: String, id: ULID?) {
        self = id.map(Self.assigned) ?? .local(SHA256.hexDigest(Data(path.utf8)))
    }

    var storageKey: String {
        get throws {
            switch self {
            case .assigned(let id): return id.rawValue
            case .local(let hash):
                guard hash.utf8.count == 64,
                      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw LibraryError.invalidIdentity
                }
                return hash
            }
        }
    }
}
