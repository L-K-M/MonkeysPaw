import Foundation

/// UI reports the tier, never the stored value. The Linux file tier is unencrypted.
public enum SecretTier: String, Equatable, Sendable {
    case keychain
    case secretService
    case environment
    case file
}

/// Namespaces also leave room for device tokens without sharing provider accounts.
public struct SecretAccount: Hashable, Codable, Sendable {
    public let namespace: String
    public let name: String
    public var rawValue: String { "\(namespace):\(name)" }

    public init(namespace: String, name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !namespace.isEmpty, !name.isEmpty,
              namespace.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SecretStoreError.invalidAccount
        }
        self.init(validatedNamespace: namespace, validatedName: name)
    }

    private init(validatedNamespace: String, validatedName: String) {
        namespace = validatedNamespace
        name = validatedName
    }

    // Typed UUIDs already satisfy the grammar; their factories cannot throw.
    // Raw strings and decoded references still use the validating initializer.
    public static func provider(_ id: ProviderProfileID) -> SecretAccount {
        SecretAccount(validatedNamespace: "provider", validatedName: id.rawValue)
    }

    public static func device(_ connectionID: UUID) -> SecretAccount {
        SecretAccount(validatedNamespace: "device", validatedName: connectionID.uuidString.lowercased())
    }

    /// §26 S3: the per-account provider-settings sync key's account.
    public static func providerSync(_ userID: ULID) -> SecretAccount {
        SecretAccount(validatedNamespace: "provider-sync", validatedName: userID.rawValue)
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw SecretStoreError.invalidAccount }
        try self.init(namespace: String(parts[0]), name: String(parts[1]))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Deliberately not Codable. Drivers and request builders explicitly unwrap it.
public struct SecretValue: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(value)
    }

    public var description: String { "<secret redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

public struct StoredSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: SecretValue
    public let tier: SecretTier

    public init(value: SecretValue, tier: SecretTier) {
        self.value = value
        self.tier = tier
    }

    public var description: String { "<stored secret redacted>" }
    public var debugDescription: String { description }
}

public enum SecretReadSource: Sendable {
    /// Environment override, then the persisted ladder.
    case effective
    /// Bypass the environment, for rollback and deletion of persisted values.
    case persisted
}

/// No underlying driver error text, paths, account input or secret values.
public enum SecretStoreError: String, Error, Equatable, Sendable {
    case invalidAccount
    case unavailable
    case locked
    case readOnly
    case readFailed
    case writeFailed
    case deleteFailed
}
