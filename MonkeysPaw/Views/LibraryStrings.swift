import Foundation
import MonkeysPawCore

enum LibraryStrings {
    static let title = "Monkey's Paw Library"
    static let sidebar = "Library sections"
    static let prompts = "Library prompts"
    static let filter = "Filter library"
    static let preview = "Prompt preview"
    static let folders = "Folders"
    static let groups = "Groups"
    static let tags = "Tags"
    static let readOnly = "Read-only"
    static let invalid = "Invalid"
    static let noSelection = "Select a prompt to edit it."
    static let noRows = "No prompts in this view."
    static let newPromptDefaultTitle = "New prompt"
    static let addFavorite = "Add to Favourites"
    static let removeFavorite = "Remove from Favourites"

    static let library = "Library"
    static let allPrompts = "All Prompts"
    static let favourites = "Favourites"
    static let recent = "Recent"
    static let conflicts = "Conflicts"
    static let noPrompts = "No Prompts"
    static let search = "Search"
    static let favourite = "Favourite"
    static let editPreview = "Edit or Preview"
    static let showSidebar = "Show Sidebar"
    static let hideSidebar = "Hide Sidebar"
    static let showInspector = "Show Inspector"
    static let hideInspector = "Hide Inspector"
    static let showToolbar = "Show Toolbar"
    static let hideToolbar = "Hide Toolbar"
    static let open = "Open"
    static let topLevel = "Top Level"
    static let other = "Other…"
    static let duplicate = "Duplicate"
    static let moveTo = "Move To"

    static func noResults(_ filter: String) -> String { "No Results for “\(filter)”" }
    static func promptCount(_ count: Int) -> String { "\(count) " + (count == 1 ? "prompt" : "prompts") }
    static func lastUsed(_ date: Date) -> String {
        "Last used " + date.formatted(date: .abbreviated, time: .shortened)
    }
    static func sectionTitle(_ id: LibrarySectionID, sections: [LibraryBrowserSection]) -> String {
        switch id {
        case .all: return allPrompts
        case .favourites: return favourites
        case .recent: return recent
        case .conflicts: return conflicts
        default: return sections.first { $0.id == id }?.title ?? library
        }
    }

    static func role(_ role: AssistantGroupRole) -> String {
        switch role {
        case .viewer: return "Viewer"
        case .editor: return "Editor"
        case .owner: return "Owner"
        }
    }

    /// Built in steps: one concatenation with an optional and a ternary
    /// exceeds the Release type checker's time limit.
    static func sectionLabel(title: String, role: AssistantGroupRole?, count: Int) -> String {
        var parts = [title]
        if let role { parts.append(Self.role(role)) }
        parts.append(String(count) + (count == 1 ? " prompt" : " prompts"))
        return parts.joined(separator: ", ")
    }

    static func favoriteMessage(_ outcome: PromptFavoriteOutcome) -> String? {
        switch outcome {
        // The open editor reports its own unsaved or saving state.
        case .saved, .editedBuffer, .savePending: return nil
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
