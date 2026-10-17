import MonkeysPawCore

enum SettingsInviteStrings {
    static let title = "Join with an invite"
    static let input = "Invite link or token"
    static let server = "Server for a bare token"
    static let stage = "Review invite"
    static let join = "Accept with current account"
    static let register = "Accept and create account"
    static let username = "New account username"
    static let password = "New account password"
    static let device = "Device name"
    static let defaultDevice = "Mac"
    static let unavailable = "Invites are unavailable for this library."
    static let explicitAccept = "Review the server and account before accepting. Opening an invite does not use it."
    static let http = "This server uses unencrypted HTTP. Your password and invite will travel without encryption."
    static let busy = "Working…"
    static let accepted = "Invite accepted."
    static let cleanup = "Some account cleanup could not be completed. Check Account before continuing."

    static func destination(_ value: InviteDestination) -> String {
        var lines = ["Invite server: \(value.serverURL.absoluteString)"]
        if let account = value.currentAccount {
            lines.append("Current account: \(account.username) (\(account.userID.rawValue))")
            lines.append("Account server: \(account.serverURL.absoluteString)")
        } else { lines.append("No account is signed in.") }
        if !value.canJoin {
            lines.append("Sign in to this server in Account to join with an existing account, then review the invite again.")
        }
        return lines.joined(separator: "\n")
    }
}
