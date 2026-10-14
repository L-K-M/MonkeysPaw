import Foundation

/// Metadata for native Account views. No local secret reference or credential.
public struct AccountConnection: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let serverURL: URL
    public let userID: ULID
    public let username: String
    public let deviceID: ULID
    public let deviceName: String

    init(_ account: SyncAccount) {
        serverURL = account.identity.serverURL
        userID = account.identity.userID
        username = account.username
        deviceID = account.deviceID
        deviceName = account.deviceName
    }

    public var description: String { "<account connection redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["connection": description]) }
}

public struct AccountHeldPrompt: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let identity: PromptIdentity
    public let path: RelativePath
    public let sourceServerURL: URL
    public let sourceUserID: ULID

    init(_ hold: SyncHeldPrompt) {
        identity = hold.identity
        path = hold.path
        sourceServerURL = hold.sourceAccount.serverURL
        sourceUserID = hold.sourceAccount.userID
    }

    public var description: String { "<held account prompt redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["prompt": description]) }
}

public enum AccountOperation: Equatable, Sendable {
    case loading, signingIn, refreshing, revokingDevice, signingOut, includingHeld
}

/// Inclusion grants upload consent; keeping local never changes durable holds.
public enum AccountHeldDecision: Sendable { case include, keepLocal }

/// Fixed reasons only. HTTP payloads and underlying error text are discarded.
public enum AccountIssue: Equatable, Sendable {
    case busy, signedOut, needsSignIn, invalidInput, invalidAccount, invalidSelection
    case reservedFolders, recoveryRequired, invalidMetadata, storageRead, storageWrite, durabilityUncertain
    case secret(SecretStoreError)
    case offline, timeout, cancelled, rateLimited, forbidden, serverFailure, invalidResponse

    public var message: String {
        switch self {
        case .busy: return "Wait for the current account operation to finish."
        case .signedOut, .needsSignIn: return "Sign in again."
        case .invalidInput: return "Check the server address, username, password and device name."
        case .invalidAccount: return "The server could not verify this account and device. Sign in again."
        case .invalidSelection: return "Refresh Account and select the files or device again."
        case .reservedFolders: return "Rename the existing Groups or Conflicts entries, then sign in again."
        case .recoveryRequired: return "Local sync recovery must finish before this operation can continue."
        case .invalidMetadata: return "Saved sync metadata could not be validated."
        case .storageRead: return "Saved sync metadata could not be read."
        case .storageWrite: return "Sync metadata could not be saved."
        case .durabilityUncertain: return "Sync metadata could not be confirmed on disk. Recovery is required."
        case .secret(.locked): return "Unlock the secret store and try again."
        case .secret(.readOnly): return "The environment secret tier is read-only."
        case .secret: return "The device credential could not be accessed in the secret store."
        case .offline: return "The server could not be reached. Local prompts remain available."
        case .timeout: return "The server did not respond in time."
        case .cancelled: return "The account operation was cancelled."
        case .rateLimited: return "The server is limiting requests. Try again later."
        case .forbidden: return "The server did not allow this operation."
        case .serverFailure: return "The server could not complete this operation."
        case .invalidResponse: return "The server returned an invalid response."
        }
    }

    init(_ issue: SyncAccountIssue) {
        switch issue {
        case .busy: self = .busy
        case .signedOut: self = .signedOut
        case .credentialsRequired, .tokenBindingMismatch: self = .needsSignIn
        case .invalidInput: self = .invalidInput
        case .invalidAccount: self = .invalidAccount
        case .recoveryRequired: self = .recoveryRequired
        case .reservedFolders: self = .reservedFolders
        case .secret(let error): self = .secret(error)
        case .metadata(let error): self.init(error)
        case .http(let error):
            switch error {
            case .unauthorized, .credentialServerMismatch: self = .needsSignIn
            case .forbidden: self = .forbidden
            case .rateLimited: self = .rateLimited
            case .serverFailure: self = .serverFailure
            case .invalidRequest, .malformedRequest, .validation: self = .invalidInput
            case .transport(.networkFailure): self = .offline
            case .transport(.deadlineExceeded): self = .timeout
            case .transport(.cancelled): self = .cancelled
            case .transport(.insecureURL), .transport(.credentialsInURL), .transport(.invalidURL),
                 .transport(.invalidRequest), .transport(.serverMismatch): self = .invalidInput
            default: self = .invalidResponse
            }
        }
    }

    init(_ error: SyncError) {
        switch error {
        case .readFailed: self = .storageRead
        case .writeFailed: self = .storageWrite
        case .durabilityUncertain: self = .durabilityUncertain
        default: self = .invalidMetadata
        }
    }
}

public enum AccountRemoteRevocation: Equatable, Sendable { case notNeeded, revoked, unconfirmed }

public struct AccountCleanup: Equatable, Sendable {
    public let remoteRevocation: AccountRemoteRevocation
    public let failedSecretDeletions: Int
    public let secretIssue: SecretStoreError?
    public let metadataIssue: AccountIssue?
    public let recoveryRequired: Bool

    public var isComplete: Bool {
        remoteRevocation != .unconfirmed && failedSecretDeletions == 0
            && metadataIssue == nil && !recoveryRequired
    }

    init(_ cleanup: SyncAccountCleanup = SyncAccountCleanup()) {
        switch cleanup.remote {
        case .notNeeded: remoteRevocation = .notNeeded
        case .revoked: remoteRevocation = .revoked
        case .unconfirmed: remoteRevocation = .unconfirmed
        }
        failedSecretDeletions = cleanup.secretFailures.count
        secretIssue = cleanup.secretIssue
        metadataIssue = cleanup.metadataIssue.map(AccountIssue.init)
        recoveryRequired = cleanup.recoveryRequired
    }
}

public struct AccountState: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public internal(set) var connection: AccountConnection?
    public internal(set) var devices: [SyncAPI.Device] = []
    public internal(set) var groups: [SyncAPI.GroupMembership] = []
    public internal(set) var secretTier: SecretTier?
    public internal(set) var enabled = false
    public internal(set) var operation: AccountOperation? = .loading
    public internal(set) var error: AccountIssue?
    public internal(set) var cleanup = AccountCleanup()
    public internal(set) var reservedFolders: [RelativePath] = []
    public internal(set) var heldPrompts: [AccountHeldPrompt] = []
    public internal(set) var keptLocal: Set<PromptIdentity> = []
    /// Native secure fields clear on submission, completion and dismissal.
    public internal(set) var passwordInputReset = UUID()

    public var isBusy: Bool { operation != nil }
    public var needsHeldDecision: Bool {
        enabled && heldPrompts.contains { !keptLocal.contains($0.identity) }
    }

    public var secretStorageMessage: String {
        switch secretTier {
        case nil: return "No device credential is available."
        case .keychain: return "The device credential is saved in Keychain."
        case .secretService: return "The device credential is saved in Secret Service."
        case .environment: return "The device credential is provided by the environment (read-only)."
        case .file: return "The device credential is saved in an unencrypted file."
        }
    }

    public var description: String { "<account state redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
