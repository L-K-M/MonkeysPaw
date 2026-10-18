#if os(Linux)
import Foundation
import MonkeysPawCore

enum LinuxSyncStatusStrings {
    static let syncNow = "Sync now"
    static let account = "Open Account…"
    static let errors = "Show sync errors"
    static let conflicts = "Show conflicts"
    static let hideErrors = "Hide sync errors"
    static let noFileErrors = "No file errors to show."
    static let unavailable = "Sync unavailable. Local sync recovery is required."

    static func summary(_ state: SyncStatusState) -> String {
        var parts = [state.footer.text]
        if state.counts.conflicts > 0 { parts.append("Conflicts: \(state.counts.conflicts)") }
        if state.counts.fileErrors > 0 { parts.append("File errors: \(state.counts.fileErrors)") }
        return parts.joined(separator: " · ")
    }

    static func lastSuccess(_ date: Date?) -> String {
        guard let date else { return "Last successful sync: never" }
        return "Last successful sync: " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    static func action(_ action: SyncStatusAction) -> String {
        switch action {
        case .account: return account
        case .syncNow: return syncNow
        case .conflicts: return conflicts
        case .errors: return errors
        case .none: return ""
        }
    }
}
#endif
