import Foundation
import MonkeysPawCore

enum SettingsUpdateStrings {
    static let title = "Updates"
    static let automatic = "Check for updates automatically"
    static let currentVersion = "Current version"
    static let unavailableVersion = "unavailable"
    static let lastCheck = "Last successful check"
    static let checkNow = "Check Now"
    static let viewRelease = "View Release"
    static let disclosure = "Automatically checks stable releases on GitHub at most once a day. GitHub receives your IP address and app version; no prompts, field values or account details. Check Now works while automatic checks are off. View release opens your browser; install updates yourself."
    static let openingFailed = "The release page could not be opened. Check your default browser and try again."

    static func version(_ version: ReleaseVersion?) -> String {
        "Current version: " + (version?.description ?? "unavailable")
    }

    static func lastChecked(_ date: Date?) -> String {
        lastCheck + ": " + checkDate(date)
    }

    static func checkDate(_ date: Date?) -> String { date.map(timestamp) ?? "never" }

    static func result(_ snapshot: UpdateSnapshot?) -> String {
        guard let snapshot else { return "Reading update status…" }
        if snapshot.isChecking { return "Checking for updates…" }
        switch snapshot.result {
        case .notChecked: return "Not checked yet."
        case .upToDate: return "You are up to date."
        case .noRelease: return "No stable release is available."
        case .updateAvailable(let version): return "Update available: \(version)."
        case .unavailable(let failure):
            switch failure {
            case .unversionedBuild: return "Update checks are unavailable in an unversioned development build."
            case .invalidCurrentVersion: return "The installed version is invalid; update checks are unavailable."
            case .malformedResponse: return "GitHub returned an invalid release response. Try again later."
            case .rateLimited(let limit): return "GitHub rate limit (HTTP \(limit.statusCode)). Try after \(timestamp(limit.until))."
            case .offline: return "The update check could not connect. Check your connection and try again."
            case .transport: return "The update request failed. Check your connection and try again."
            case .httpStatus(let code): return "GitHub returned HTTP \(code). Try again later."
            }
        }
    }

    static func stateError(_ error: UpdateStateError) -> String {
        switch error {
        case .corruptFile, .futureVersion:
            return "Update history is unsupported or corrupt. Automatic checks are blocked; Check Now can still report a result."
        case .readFailed:
            return "Update history could not be read. Check its permissions; automatic checks are blocked."
        case .writeFailed:
            return "Update history could not be saved. Check permissions and available disk space; automatic checks are blocked."
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
