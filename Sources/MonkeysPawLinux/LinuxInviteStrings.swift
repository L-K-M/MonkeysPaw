#if os(Linux)
import MonkeysPawCore

enum LinuxInviteStrings {
    static let title = "Join with an invite"
    static let input = "Invite link or token"
    static let server = "Server for a bare token"
    static let stage = "Review invite"
    static let join = "Accept with current account"
    static let register = "Accept and create account"
    static let username = "New account username"
    static let password = "New account password"
    static let device = "Device name"
    static let defaultDevice = "Linux desktop"
    static let unavailable = "Invites are unavailable for this library."
    static let explicitAccept = "Review the server and account before accepting. Opening an invite does not use it."
    static let http = "This server uses unencrypted HTTP. Your password and invite will travel without encryption."
    static let busy = "Working…"
    static let accepted = "Invite accepted."
    static let cleanup = "Some account cleanup could not be completed. Check Account before continuing."

    static func destination(_ value: InviteDestination) -> String {
        let account = value.currentAccount.map {
            "Current account: \($0.username) (\($0.userID.rawValue))\nAccount server: \($0.serverURL.absoluteString)"
        } ?? "No account is signed in."
        let guidance = value.canJoin ? "" : "\nSign in to this server in Account to join with an existing account, then review the invite again."
        return "Invite server: \(value.serverURL.absoluteString)\n" + account + guidance
    }
}
#endif
