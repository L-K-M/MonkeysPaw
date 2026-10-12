import MonkeysPawCore

enum LibraryStrings {
    static let title = "Monkey's Paw Library"
    static let sidebar = "Library sections"
    static let prompts = "Library prompts"
    static let filter = "Filter library"
    static let preview = "Prompt preview"
    static let folders = "Folders"
    static let tags = "Tags"
    static let readOnly = "Read-only"
    static let invalid = "Invalid"
    static let noSelection = "Select a prompt to preview it."
    static let noRows = "No prompts in this view."
    static let addFavorite = "Add to Favourites"
    static let removeFavorite = "Remove from Favourites"
    static let keyboardHint = "↑↓: select · ⌘⇧F: favourite · Esc: clear filter, then close"

    static func favoriteMessage(_ outcome: PromptFavoriteOutcome) -> String? {
        switch outcome {
        case .saved: return nil
        case .noSelection: return "Select a prompt before changing its favourite."
        case .inactive: return "This library is no longer active. Reopen Library to try again."
        case .fileStoreFailure(let error):
            switch error {
            case .notFound: return "The prompt file is missing. Refresh the library before trying again."
            case .outsideRoot, .invalidRoot, .invalidPath:
                return "The prompt file is outside the active library or has an invalid path."
            default: return "Could not save the favourite. Check library and app-data permissions."
            }
        case .libraryFailure(let error):
            switch error {
            case .conflict: return "The prompt changed on disk. Wait for the library to refresh, then try again."
            case .recoveryRequired, .historyMaintenanceFailed:
                return "The save needs recovery. Refresh the library before trying again."
            default: return "Could not save the favourite. Check the prompt and library, then try again."
            }
        case .writeFailure(let error): return error.description
        }
    }
}
