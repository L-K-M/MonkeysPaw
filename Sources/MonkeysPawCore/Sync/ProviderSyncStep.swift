import Foundation

/// §26 S9: outcomes are typed and reported on the pass; they never block
/// prompt synchronization. Transport and unauthorized errors propagate like
/// any pass failure. Local persistence failures also propagate: a failed or
/// skipped step leaves the record untouched so a later pass resumes.
public enum ProviderSyncOutcome: String, Equatable, Sendable {
    case synced, unchanged, keyRequired, decryptFailed, applyFailed
}

/// §26 S8: the per-account baseline `<data>/sync/provider-settings.json`.
/// A server/user mismatch resets rev to 0.
struct ProviderSyncRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let serverURL: String
    let userID: String
    let rev: Int64
    let payloadHash: String

    init(serverURL: String, userID: String, rev: Int64, payloadHash: String) {
        version = Self.currentVersion
        self.serverURL = serverURL
        self.userID = userID
        self.rev = rev
        self.payloadHash = payloadHash
    }

    private enum CodingKeys: String, CodingKey {
        case version, serverURL = "server_url", userID = "user_id", rev
        case payloadHash = "payload_hash"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        let source = try value.decode(Int.self, forKey: .version)
        try SyncIdentifiers.version(source, current: Self.currentVersion)
        try self.init(serverURL: value.decode(String.self, forKey: .serverURL),
                      userID: value.decode(String.self, forKey: .userID),
                      rev: value.decode(Int64.self, forKey: .rev),
                      payloadHash: value.decode(String.self, forKey: .payloadHash))
    }
}

/// Composition supplies the step's inputs; the step itself stays internal.
public struct ProviderSyncInput {
    public let providers: ProviderSettingsService
    public let keys: ProviderSyncKeyService

    public init(providers: ProviderSettingsService, keys: ProviderSyncKeyService) {
        self.providers = providers
        self.keys = keys
    }
}

/// The pull-then-push provider-settings step inside one coordinator pass.
final class ProviderSyncStep: @unchecked Sendable {
    private let providers: ProviderSettingsService
    private let keys: ProviderSyncKeyService
    private let records: SyncPersistence<ProviderSyncRecord>
    private let entropy: EntropySource

    init(files: FileStore, operations: SyncFileOperations, providers: ProviderSettingsService,
         keys: ProviderSyncKeyService, entropy: EntropySource) {
        self.providers = providers
        self.keys = keys
        self.entropy = entropy
        records = SyncPersistence(files: files, operations: operations,
            path: "sync/provider-settings.json", version: Limits.providerSyncRecordVersion)
    }

    func run(client: SyncHTTPClient, identity: SyncAccountIdentity, permit: SyncWorkPermit) async throws -> ProviderSyncOutcome {
        // Without a key nothing can be decrypted or sealed, so the account is
        // reported key-required before the endpoint is ever contacted: accounts
        // that never provision a key keep working against servers that predate
        // the provider-settings routes.
        guard let key = try keys.keyBytes(userID: identity.userID) else { return .keyRequired }
        let remote = try await client.providerSettings()
        try permit.check()

        var baseline = try records.load()
        if baseline?.serverURL != identity.serverURL.absoluteString || baseline?.userID != identity.userID.rawValue {
            baseline = nil
        }
        var known = baseline ?? ProviderSyncRecord(serverURL: identity.serverURL.absoluteString,
            userID: identity.userID.rawValue, rev: 0, payloadHash: "")

        // The pulled document is S6's "last decrypted remote document".
        var remoteSecrets: [String: String] = [:]
        var decryptFailed = false
        if let document = remote.document {
            var decrypted: (payload: ProviderSyncPayload, plaintext: Data)?
            do {
                let plaintext = try ProviderSyncCipher.open(document, key: key, userID: identity.userID)
                decrypted = (try ProviderSyncPayload(plaintext: plaintext), plaintext)
            } catch {
                // Every failure up to and including parsing is decrypt-side:
                // oversized plaintexts and future-version seals included. An
                // undecryptable document cannot gate the push: under literal
                // last-writer-wins the local document overwrites it this pass,
                // so key rotation self-heals instead of stalling forever.
                decryptFailed = true
            }
            if let decrypted {
                remoteSecrets = decrypted.payload.secrets
                if remote.rev > known.rev {
                    do {
                        try providers.applySynced(settings: decrypted.payload.settings,
                                                  secrets: decrypted.payload.secrets)
                        known = ProviderSyncRecord(serverURL: known.serverURL, userID: known.userID,
                            rev: remote.rev, payloadHash: SHA256.hexDigest(decrypted.plaintext))
                    } catch { return .applyFailed }
                }
            }
        }

        let plaintext: Data
        do { plaintext = try providers.exportSyncPayload(remoteSecrets: remoteSecrets).encode() }
        catch { return .applyFailed }
        let hash = SHA256.hexDigest(plaintext)

        if !decryptFailed, remote.rev == known.rev && hash == known.payloadHash {
            if baseline != known { try records.update { _ in known } }
            return .unchanged
        }
        let document = try ProviderSyncCipher.seal(key: key, userID: identity.userID, plaintext: plaintext) {
            Data(try entropy.bytes(count: AES256GCM.nonceBytes))
        }
        let response = try await client.putProviderSettings(SyncAPI.PutProviderSettingsRequest(document: document))
        try records.update { _ in
            ProviderSyncRecord(serverURL: known.serverURL, userID: known.userID,
                               rev: response.rev, payloadHash: hash)
        }
        return decryptFailed ? .decryptFailed : .synced
    }
}
