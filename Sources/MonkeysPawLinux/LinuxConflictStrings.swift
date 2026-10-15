#if os(Linux)
import MonkeysPawCore

enum LinuxConflictStrings {
    static let title = "Resolve conflict"
    static let serverVersion = "Server version"
    static let myVersion = "My version"
    static let keepServer = "Keep server"
    static let keepMine = "Keep mine"
    static let keepBoth = "Keep both"
    static let refresh = "Refresh comparison"
    static let loading = "Loading comparison…"
    static let resolving = "Resolving conflict…"
    static let choose = "Choose which version to keep. Keep both retains your private copy and clears its conflict marker."
    static let chooseAgain = "Your copy was reloaded. Review the comparison and choose again."
    static let unavailable = "Sign in to sync before resolving this copy."

    static func failure(_ failure: ConflictResolutionFailure) -> String {
        switch failure {
        case .headChanged: return "The server version changed. Review the refreshed comparison and choose again."
        case .accessDenied: return "You cannot replace the server version. Your private copy is kept."
        case .originalUnavailable: return "The original is unavailable. Keep both retains your private copy."
        case .invalidCopy: return "This copy no longer has a valid conflict origin. Refresh the library."
        case .staleCopy: return "Your copy changed. Refresh the comparison before choosing again."
        case .staleAccess: return "Your access changed. Refresh the comparison before choosing again."
        case .inactive, .staleSession: return unavailable
        case .busy: return "Sync is busy. Refresh the comparison when it finishes."
        case .invalidCandidate: return "Your version cannot replace the original. Repair the copy or keep both."
        case .needsSignIn: return "Sign in again. Your private copy is kept."
        case .offline: return "The server could not be reached. Your private copy is kept. Try again when connected."
        case .recoveryRequired: return "Local sync recovery must finish before resolving this copy."
        case .operationFailed: return "The conflict could not be resolved. Your private copy is kept. Refresh and try again."
        }
    }

    static func resolved(_ action: ConflictResolutionAction) -> String {
        switch action {
        case .keepServer: return "Server version kept. Your conflict copy was moved to Trash."
        case .keepMine: return "Your version was sent to the server. Your conflict copy was moved to Trash."
        case .keepBoth: return "Both versions kept. Your private copy is no longer marked as a conflict."
        }
    }
}
#endif
