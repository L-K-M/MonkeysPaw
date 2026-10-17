import Foundation

public enum InviteAcceptance: Sendable { case existingAccount, newAccount }
public enum InviteOperation: Equatable, Sendable { case staging, creating, accepting }

public enum InviteIssue: Error, Equatable, Sendable {
    case invalidLink, serverRequired, accountChanged, wrongServer, unavailableInvite, noInvite
    case account(AccountIssue)
    case refreshIncomplete(AccountIssue)
    case registrationIncomplete(AccountIssue)

    public var message: String {
        switch self {
        case .invalidLink: return "Enter a valid invite link or token."
        case .serverRequired: return "Select the server explicitly before entering a bare invite token."
        case .accountChanged: return "Your account changed. Open the invite again and check the destination."
        case .wrongServer: return "Sign in to the invite's server before joining with an existing account."
        case .unavailableInvite: return "This invite could not be used. It may have expired or already been used."
        case .noInvite: return "Open an invite before accepting, or create a link before copying."
        case .account(let issue): return issue.message
        case .refreshIncomplete(let issue): return "The invite was accepted. Refresh Account to finish. " + issue.message
        case .registrationIncomplete(let issue): return "The account was created. Sign in to finish setup. " + issue.message
        }
    }
}

/// Show the exact deployment and account before the explicit Accept action.
public struct InviteDestination: Equatable, Sendable {
    public let serverURL: URL
    public let currentAccount: AccountConnection?
    public let canJoin: Bool
    public var usesHTTP: Bool { serverURL.scheme == "http" }
}

/// The UI may display this once and copy explicitly. Clear on hide/close.
/// Intentionally has no Codable conformance or diagnostic link representation.
public struct SyncInviteCreation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let link: String
    public let expiresAt: String
    public let target: SyncAPI.InviteTarget
    let account: SyncAccount

    public var description: String { "<created invite redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["invite": description]) }
}

public struct InviteState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public internal(set) var destination: InviteDestination?
    public internal(set) var created: SyncInviteCreation?
    public internal(set) var operation: InviteOperation?
    public internal(set) var hasStagedInvite = false
    public internal(set) var accepted = false
    public internal(set) var error: InviteIssue?
    public internal(set) var cleanup = AccountCleanup(SyncAccountCleanup())
    public internal(set) var inputReset = UUID()
    public var isBusy: Bool { operation != nil }
    public var canAccept: Bool { hasStagedInvite && !isBusy }

    public var description: String { "<invite state redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
