import Foundation

enum SyncGroupCommand: Equatable {
    case refresh(ULID?)
    case create(String)
    case rename(ULID, String)
    case delete(ULID)
    case setRole(ULID, ULID, SyncAPI.Role)
    case removeMember(ULID, ULID)
    case createInvite(ULID, SyncAPI.InviteRole)

    var groupID: ULID? {
        switch self {
        case .refresh(let id): return id
        case .create: return nil
        case .rename(let id, _), .delete(let id), .setRole(let id, _, _),
             .removeMember(let id, _), .createInvite(let id, _): return id
        }
    }

    var isMutation: Bool {
        if case .refresh = self { return false }
        return true
    }
}

struct SyncGroupResult {
    var snapshot: SyncAccountSnapshot
    var selectedGroupID: ULID?
    var members: [SyncAPI.Member] = []
    var createdInvite: SyncInviteCreation?
    var changeConfirmed = false
    var issue: GroupManagementIssue?

    var state: GroupManagementState {
        var state = GroupManagementState()
        state.connection = snapshot.account.map(AccountConnection.init)
        state.accountKind = snapshot.me?.user.accountKind
        state.enabled = snapshot.enabled
        state.groups = snapshot.me?.groups ?? []
        state.selectedGroupID = selectedGroupID
        state.members = members
        state.createdInvite = createdInvite
        state.changeConfirmed = changeConfirmed
        state.error = issue
        state.operation = nil
        return state
    }
}

/// Uses the account graph's sole session/admission owner and the existing
/// invite parser/Clipboard boundary. No driver or second sync graph is built.
public final class SyncGroupService: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let account: SyncAccountService
    private let invites: SyncInviteService

    public init(account: SyncAccountService, clipboard: Clipboard) {
        self.account = account
        invites = SyncInviteService(account: account, clipboard: clipboard)
    }

    var snapshot: SyncAccountSnapshot { account.snapshot }

    func execute(_ command: SyncGroupCommand, expectedAccount: SyncAccount?) async -> SyncGroupResult {
        // Refresh may adopt a newly signed-in connection. Mutations remain bound
        // to the connection on which the user selected their controls.
        let expected: SyncAccount?
        if case .refresh = command { expected = snapshot.account }
        else { expected = expectedAccount }
        guard let expected else {
            return SyncGroupResult(snapshot: snapshot, issue: .account(.signedOut))
        }
        do { return try await account.manageGroups(command, expectedAccount: expected) }
        catch let issue as GroupManagementIssue { return SyncGroupResult(snapshot: snapshot, issue: issue) }
        catch let failure as SyncAccountServiceError { return SyncGroupResult(snapshot: snapshot, issue: GroupManagementIssue(failure)) }
        catch { return SyncGroupResult(snapshot: snapshot, issue: .account(.invalidResponse)) }
    }

    /// Explicit Copy stays on Clipboard's owning UI thread and rechecks binding.
    func copy(_ created: SyncInviteCreation) throws { try invites.copy(created) }

    public var description: String { "<sync group service redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["service": description]) }
}
