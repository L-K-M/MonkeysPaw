import Foundation

public enum ProviderKind: String, Codable, Hashable, Sendable {
    case anthropic
    case openaiCompatible

    public var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openaiCompatible: return "https://api.openai.com/v1"
        }
    }

    /// §7.1 / §19 B31: keep the planned Anthropic model; manual IDs are allowed.
    public var defaultModelID: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openaiCompatible: return ""
        }
    }
}

public struct ProviderProfileID: Hashable, Codable, Sendable {
    private let value: UUID
    public var rawValue: String { value.uuidString.lowercased() }

    public init(_ value: UUID = UUID()) { self.value = value }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = UUID(uuidString: raw) else { throw ProviderSettingsError.invalidProfile }
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// §19 B23: one Linux override per stable profile, never a global provider key.
    public var environmentVariable: String {
        "MONKEYSPAW_PROVIDER_" + rawValue.replacingOccurrences(of: "-", with: "").uppercased() + "_API_KEY"
    }
}

public struct ProviderProfile: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: ProviderProfileID
    public let displayName: String
    public let kind: ProviderKind
    public let baseURL: URL
    public let modelID: String
    public let secretReference: SecretAccount?

    public init(id: ProviderProfileID, displayName: String, kind: ProviderKind, baseURL: String,
                modelID: String, secretReference: SecretAccount? = nil) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              secretReference == nil || secretReference == .provider(id) else {
            throw ProviderSettingsError.invalidProfile
        }
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = try ProviderSettings.normalizeBaseURL(baseURL, kind: kind)
        self.modelID = modelID
        self.secretReference = secretReference
    }

    public var completionURL: URL {
        baseURL.appendingPathComponent(kind == .anthropic ? "v1/messages" : "chat/completions")
    }

    public var modelsURL: URL {
        baseURL.appendingPathComponent(kind == .anthropic ? "v1/models" : "models")
    }

    public var cacheKey: ProviderCacheKey {
        ProviderCacheKey(profileID: id, kind: kind, baseURL: baseURL, modelID: modelID)
    }

    /// Scheme and effective port are part of the credential destination too.
    var credentialOrigin: String {
        ProviderSettings.credentialOrigin(baseURL)
    }

    public var description: String { "<provider profile>" }
    public var debugDescription: String { description }
}

/// Capability state belongs to a complete normalized endpoint, profile and model.
public struct ProviderCacheKey: Hashable, Sendable {
    public let profileID: ProviderProfileID
    public let kind: ProviderKind
    public let baseURL: URL
    public let modelID: String
}

public enum ProviderKeyEdit: Equatable, Sendable {
    case keep
    case replace(SecretValue)
    case clear

    /// A whitespace-only key field is Keep; Clear is a separate intent.
    public static func typed(_ value: String) -> ProviderKeyEdit {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .keep : .replace(SecretValue(value))
    }
}

/// Staged input is never persisted or Codable. Test can use it without Save.
public struct ProviderDraft: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let id: ProviderProfileID
    public var displayName: String
    public var kind: ProviderKind
    public var baseURL: String
    public var modelID: String
    public var key: ProviderKeyEdit

    public init(id: ProviderProfileID = ProviderProfileID(), displayName: String = "Anthropic",
                kind: ProviderKind = .anthropic, baseURL: String? = nil, modelID: String? = nil,
                key: ProviderKeyEdit = .keep) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.modelID = modelID ?? kind.defaultModelID
        self.key = key
    }

    public init(profile: ProviderProfile) {
        self.init(id: profile.id, displayName: profile.displayName, kind: profile.kind,
                  baseURL: profile.baseURL.absoluteString, modelID: profile.modelID)
    }

    public var description: String { "<provider draft redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["draft": description]) }
}

public struct ModelDescriptor: Equatable, Sendable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// Resolved only in Services. Presentation never receives a stored key field.
/// Model listing accepts an empty model ID before the user has chosen one.
public struct ProviderConnection: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let profileID: ProviderProfileID
    public let kind: ProviderKind
    public let baseURL: URL
    public let modelID: String
    public let key: SecretValue?

    init(profileID: ProviderProfileID, kind: ProviderKind, baseURL: URL, modelID: String, key: SecretValue?) {
        self.profileID = profileID
        self.kind = kind
        self.baseURL = baseURL
        self.modelID = modelID
        self.key = key
    }

    public var completionURL: URL {
        baseURL.appendingPathComponent(kind == .anthropic ? "v1/messages" : "chat/completions")
    }

    public var modelsURL: URL {
        baseURL.appendingPathComponent(kind == .anthropic ? "v1/models" : "models")
    }

    public var description: String { "<provider connection redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["connection": description]) }
}

public enum ProviderSettingsError: Error, Equatable, Sendable {
    case futureVersion(Int)
    case unsupportedVersion(Int)
    case corruptFile
    case readFailed(FileStoreError)
    case writeFailed(FileStoreError)
    case invalidBaseURL
    case insecureBaseURL
    case credentialsInURL
    case queryOrFragmentInURL
    case invalidProfile
    case invalidKey
    case duplicateProfile
    case profileNotFound
    case keyRequiredForChangedDestination
    case secret(SecretStoreError)
    /// Settings did not commit, and restoration of the persisted secret failed.
    case secretRollbackFailed
}
