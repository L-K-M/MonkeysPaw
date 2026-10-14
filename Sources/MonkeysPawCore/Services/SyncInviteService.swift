import Foundation

struct SyncStagedInvite: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let link: SyncInviteLink
    let account: SyncAccount?
    let destination: InviteDestination

    var description: String { "<staged invite redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["invite": description]) }
}

struct SyncInviteAcceptance: Sendable {
    let snapshot: SyncAccountSnapshot
    var issue: InviteIssue?
    var cleanup: SyncAccountCleanup
}

/// Account operations retain the sole credential/persistence owner. Invite
/// staging is local only; no preview endpoint or implicit redemption exists.
public final class SyncInviteService: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let account: SyncAccountService
    private let clipboard: Clipboard

    public init(account: SyncAccountService, clipboard: Clipboard) {
        self.account = account
        self.clipboard = clipboard
    }

    func stage(_ input: String, server: String? = nil) throws -> SyncStagedInvite {
        let link: SyncInviteLink
        do { link = try SyncInviteLink(input, server: server) }
        catch SyncInviteLinkError.serverRequired { throw InviteIssue.serverRequired }
        catch { throw InviteIssue.invalidLink }
        let snapshot = account.snapshot
        return SyncStagedInvite(link: link, account: snapshot.account,
            destination: InviteDestination(serverURL: link.server.baseURL,
                currentAccount: snapshot.account.map(AccountConnection.init),
                canJoin: snapshot.enabled && snapshot.account?.identity.serverURL == link.server.baseURL))
    }

    func accept(_ staged: SyncStagedInvite, as mode: InviteAcceptance, username: String,
                password: inout String, deviceName: String) async throws -> SyncInviteAcceptance {
        let supplied = SecretValue(password)
        password = ""
        do {
            switch mode {
            case .existingAccount:
                guard let expected = staged.account else { throw InviteIssue.account(.signedOut) }
                let result = try await account.joinInvite(staged.link, expectedAccount: expected)
                return SyncInviteAcceptance(snapshot: result.snapshot,
                    issue: result.refreshFailure.map { .refreshIncomplete(AccountIssue($0.issue)) }, cleanup: result.snapshot.cleanup)
            case .newAccount:
                var transient = supplied.withValue { $0 }
                let result = try await account.register(invite: staged.link, expectedAccount: staged.account,
                    username: username, password: &transient, deviceName: deviceName)
                return SyncInviteAcceptance(snapshot: result, cleanup: result.cleanup)
            }
        } catch let error as SyncInviteRegistrationFailure {
            return SyncInviteAcceptance(snapshot: account.snapshot,
                issue: .registrationIncomplete(AccountIssue(error.failure.issue)), cleanup: error.failure.cleanup)
        } catch { throw Self.issue(error) }
    }

    func create(groupID: ULID, role: SyncAPI.InviteRole) async throws -> SyncInviteCreation {
        guard let expected = account.snapshot.account else { throw InviteIssue.account(.signedOut) }
        do {
            let issued = try await account.createInvite(groupID: groupID, role: role, expectedAccount: expected)
            guard issued.target == .group(groupID: groupID.rawValue, role: role) else { throw InviteIssue.account(.invalidResponse) }
            let link = try SyncInviteLink(server: SyncServerURL(expected.identity.serverURL.absoluteString), token: issued.token)
            return SyncInviteCreation(link: link.text, expiresAt: issued.expiresAt, target: issued.target, account: expected)
        } catch { throw Self.issue(error) }
    }

    /// Called on Clipboard's owning UI thread, only by the explicit Copy intent.
    func copy(_ created: SyncInviteCreation) throws {
        guard account.snapshot.account == created.account else { throw InviteIssue.accountChanged }
        clipboard.writeText(created.link)
    }

    private static func issue(_ error: Error) -> InviteIssue {
        if let issue = error as? InviteIssue { return issue }
        if let failure = error as? SyncAccountServiceError {
            if case .http(.malformedRequest) = failure.issue { return .unavailableInvite }
            return .account(AccountIssue(failure.issue))
        }
        return .account(.invalidResponse)
    }

    public var description: String { "<sync invite service redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["service": description]) }
}
