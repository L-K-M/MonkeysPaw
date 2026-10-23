import Foundation

/// Fixed reasons only; the key text never enters errors or diagnostics.
public enum ProviderSyncKeyError: Error, Equatable, Sendable {
    case invalidKey
    case secret(SecretStoreError)
}

/// §26 S3/S12: the dedicated AES-256 key is generated on one device and entered
/// on the others as 43 unpadded base64url characters. It lives in the platform
/// SecretStore under `provider-sync:<user ULID>` and is never uploaded.
public final class ProviderSyncKeyService: @unchecked Sendable {
    private let secrets: SecretStore
    private let entropy: EntropySource

    public init(secrets: SecretStore, entropy: EntropySource) {
        self.secrets = secrets
        self.entropy = entropy
    }

    /// UI receives the provisioning tier, never the stored key.
    public func tier(userID: ULID) throws -> SecretTier? {
        try read(account: .providerSync(userID))?.tier
    }

    /// Generates, stores and returns the key text for one explicit display/copy.
    @discardableResult
    public func generateKey(userID: ULID) throws -> String {
        let bytes: [UInt8]
        do { bytes = try entropy.bytes(count: Limits.providerSyncKeyBytes) }
        catch { throw ProviderSyncKeyError.secret(.writeFailed) }
        return try enterKey(userID: userID, text: Base64URL.encode(bytes))
    }

    /// Accepts the key text; stores it under the persisted ladder like provider keys.
    @discardableResult
    public func enterKey(userID: ULID, text: String) throws -> String {
        guard let bytes = Base64URL.decode(text), bytes.count == Limits.providerSyncKeyBytes else {
            throw ProviderSyncKeyError.invalidKey
        }
        let normalized = Base64URL.encode(bytes)
        do { _ = try secrets.write(SecretValue(normalized), account: .providerSync(userID)) }
        catch let error as SecretStoreError { throw ProviderSyncKeyError.secret(error) }
        catch { throw ProviderSyncKeyError.secret(.writeFailed) }
        return normalized
    }

    /// Idempotent removal of every persisted copy for this account.
    public func removeKey(userID: ULID) throws {
        do { try secrets.delete(account: .providerSync(userID)) }
        catch let error as SecretStoreError { throw ProviderSyncKeyError.secret(error) }
        catch { throw ProviderSyncKeyError.secret(.deleteFailed) }
    }

    /// Persisted raw key bytes for the sync step; nil when unprovisioned.
    func keyBytes(userID: ULID) throws -> Data? {
        try read(account: .providerSync(userID))?.value.withValue { value in
            Base64URL.decode(value).map { Data($0) }
        } ?? nil
    }

    private func read(account: SecretAccount) throws -> StoredSecret? {
        do { return try secrets.read(account: account, source: .persisted) }
        catch let error as SecretStoreError { throw ProviderSyncKeyError.secret(error) }
        catch { throw ProviderSyncKeyError.secret(.readFailed) }
    }
}
