import Foundation

/// Fixed, input-free failures. Never persist a driver/transport error description.
enum SyncError: Error, Equatable, Sendable {
    case corruptFile
    case futureVersion(Int)
    case unsupportedVersion(Int)
    case readFailed(FileStoreError)
    case writeFailed(FileStoreError)
    case durabilityUncertain
    case bindingMismatch
    case invalidAccount
    case invalidRoot
    case invalidScope
    case invalidHash
    case invalidState
}

/// Only known diagnostics can enter last_error; arbitrary server text cannot.
enum SyncIssueCode: Equatable, Sendable, Codable {
    case content(PromptIssueCode)
    case path(SyncPathIssueCode)
    case idMismatch
    case notFound
    case forbidden
    case pathClash
    case localVisibility

    var rawValue: String {
        switch self {
        case .content(let code): return code.rawValue
        case .path(let code): return code.rawValue
        case .idMismatch: return "prompt.id_mismatch"
        case .notFound: return "not_found"
        case .forbidden: return "forbidden"
        case .pathClash: return "sync.path_clash"
        case .localVisibility: return "sync.local_visibility"
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if let code = PromptIssueCode(rawValue: value) { self = .content(code); return }
        if let code = SyncPathIssueCode(rawValue: value) { self = .path(code); return }
        switch value {
        case "prompt.id_mismatch": self = .idMismatch
        case "not_found": self = .notFound
        case "forbidden": self = .forbidden
        case "sync.path_clash": self = .pathClash
        case "sync.local_visibility": self = .localVisibility
        default: throw SyncError.invalidState
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SyncOperation: String, Codable, Sendable {
    case put, delete, move
}

/// Path hashes allow even an invalid input path to be fingerprinted safely.
/// Access changes and operation changes must also permit a new attempt.
struct SyncInputFingerprint: Equatable, Sendable, Codable {
    let contentHash: SyncHash
    let pathHash: SyncHash
    let scope: SyncScopeKey
    let accessGeneration: Int64
    let operation: SyncOperation

    init(bytes: Data, path: RelativePath, scope: SyncScopeKey,
         accessGeneration: Int64, operation: SyncOperation) throws {
        guard accessGeneration >= 0 else { throw SyncError.invalidState }
        contentHash = SyncHash(bytes: bytes)
        pathHash = SyncHash(bytes: Data(path.string.utf8))
        self.scope = scope
        self.accessGeneration = accessGeneration
        self.operation = operation
    }

    private enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash", pathHash = "path_hash", scope = "scope_key"
        case accessGeneration = "access_generation", operation
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = try value.decode(SyncHash.self, forKey: .contentHash)
        pathHash = try value.decode(SyncHash.self, forKey: .pathHash)
        scope = try value.decode(SyncScopeKey.self, forKey: .scope)
        accessGeneration = try value.decode(Int64.self, forKey: .accessGeneration)
        operation = try value.decode(SyncOperation.self, forKey: .operation)
        guard accessGeneration >= 0 else { throw SyncError.invalidState }
    }
}

struct SyncPromptError: Equatable, Sendable, Codable {
    let code: SyncIssueCode
    let fingerprint: SyncInputFingerprint
}
