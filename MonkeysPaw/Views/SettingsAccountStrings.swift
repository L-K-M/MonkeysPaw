import MonkeysPawCore

enum SettingsAccountStrings {
    static let tab = "Account"
    static let server = "Server address"
    static let username = "Username"
    static let password = "Password"
    static let deviceName = "Device name"
    static let defaultDeviceName = "Mac"
    static let signIn = "Sign in"
    static let signOut = "Sign out"
    static let refresh = "Refresh account"
    static let devices = "Devices"
    static let revoke = "Revoke device"
    static let revokeCurrent = "Revoke this device and sign out"
    static let signedOut = "Not signed in. Local prompts remain available."
    static let unavailable = "Account is unavailable for the active library."
    static let reservedFolders = "Rename these existing entries in your library folder, then enter your password and sign in again:"
    static let heldFiles = "Files from a previous account"
    static let heldGuidance = "These files stay local and are not uploaded to this account. Select files to keep local or explicitly include in this account."
    static let keepLocal = "Keep local"
    static let include = "Include in this account"

    static func connection(_ connection: AccountConnection, enabled: Bool) -> String {
        let account = "\(connection.username) at \(connection.serverURL.absoluteString)"
        return enabled ? "Signed in as \(account)." : "Sync is not enabled for \(account)."
    }

    static func device(_ device: SyncAPI.Device) -> String {
        var status = ""
        if device.revokedAt != nil { status = " (revoked)" }
        else if device.isCurrent { status = " (this device)" }
        return "\(device.name)\(status)"
    }

    static func held(_ prompt: AccountHeldPrompt, keptLocal: Bool) -> String {
        prompt.path.string + (keptLocal ? " (kept local)" : "")
    }

    static func progress(_ operation: AccountOperation) -> String {
        switch operation {
        case .loading: return "Loading account…"
        case .signingIn: return "Signing in…"
        case .refreshing: return "Refreshing account…"
        case .revokingDevice: return "Revoking device…"
        case .signingOut: return "Signing out…"
        case .includingHeld: return "Including selected files…"
        }
    }

    static func cleanup(_ cleanup: AccountCleanup) -> String? {
        guard !cleanup.isComplete else { return nil }
        var messages: [String] = []
        if cleanup.remoteRevocation == .unconfirmed {
            messages.append("Remote device revocation could not be confirmed. Revoke this device from another signed-in device.")
        }
        if cleanup.failedSecretDeletions > 0 {
            messages.append("A saved device credential could not be removed.")
        }
        if let issue = cleanup.secretIssue { messages.append(AccountIssue.secret(issue).message) }
        if let issue = cleanup.metadataIssue { messages.append(issue.message) }
        if cleanup.recoveryRequired { messages.append(AccountIssue.recoveryRequired.message) }
        return messages.joined(separator: "\n")
    }
}
