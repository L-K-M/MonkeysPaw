import Foundation

public enum GroupManagementOperation: Equatable, Sendable {
    case loading, refreshing, creating, renaming, deleting, settingRole, removingMember, creatingInvite
}

/// Fixed messages only; a 403 does not identify which transactional rule failed.
public enum GroupManagementIssue: Error, Equatable, Sendable {
    case invalidSelection, invalidUserID, invalidName, accountChanged, forbidden, notFound
    case account(AccountIssue)
    case refreshIncomplete(AccountIssue)
    case membersUnavailable(AccountIssue)

    public var message: String {
        switch self {
        case .invalidSelection: return "Refresh groups and select a group again."
        case .invalidUserID: return "Enter the existing user's ID."
        case .invalidName: return "Enter a group name of 1 to 255 Unicode scalars."
        case .accountChanged: return "Your account changed. Refresh groups before trying again."
        case .forbidden:
            return "The server did not allow this change. Only owners or admins can manage groups; a group must keep an owner, and admins cannot add themselves or raise their own role."
        case .notFound: return "The group or member is no longer available. Refresh groups."
        case .account(let issue): return issue.message
        case .refreshIncomplete(let issue):
            return "The server confirmed the change, but Account could not be refreshed. Refresh groups before making another change. " + issue.message
        case .membersUnavailable(let issue): return "The member list could not be refreshed. " + issue.message
        }
    }

    init(_ failure: SyncAccountServiceError) {
        switch failure.issue {
        case .http(.forbidden): self = .forbidden
        case .http(.notFound): self = .notFound
        default: self = .account(AccountIssue(failure.issue))
        }
    }
}

public struct GroupManagementState: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public internal(set) var connection: AccountConnection?
    public internal(set) var accountKind: SyncAPI.AccountKind?
    public internal(set) var enabled = false
    public internal(set) var groups: [SyncAPI.GroupMembership] = []
    public internal(set) var selectedGroupID: ULID?
    public internal(set) var members: [SyncAPI.Member] = []
    public internal(set) var createdInvite: SyncInviteCreation?
    public internal(set) var operation: GroupManagementOperation? = .loading
    public internal(set) var error: GroupManagementIssue?
    public internal(set) var changeConfirmed = false
    /// Clear native name/member/role drafts when the account or access changes.
    public internal(set) var inputReset = UUID()

    public var isBusy: Bool { operation != nil }
    public var selectedGroup: SyncAPI.GroupMembership? {
        groups.first { $0.groupID == selectedGroupID?.rawValue }
    }
    public var canCreate: Bool { enabled && accountKind != nil && !isBusy }
    public var canManage: Bool {
        canCreate && selectedGroup != nil && (selectedGroup?.role == .owner || accountKind == .admin)
    }
    public var canCopyInvite: Bool { enabled && !isBusy && createdInvite != nil && canManage }

    /// Admin authority never grants membership or raises the admin's own role.
    /// Last-owner protection still belongs to the server's write transaction.
    public func canSetRole(userID: String, role: SyncAPI.Role) -> Bool {
        guard canManage else { return false }
        guard accountKind == .admin, userID == connection?.userID.rawValue else { return true }
        guard let current = members.first(where: { $0.userID == userID })?.role else { return false }
        switch current {
        case .owner: return true
        case .editor: return role != .owner
        case .viewer: return role == .viewer
        }
    }

    public var description: String { "<group management state redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
