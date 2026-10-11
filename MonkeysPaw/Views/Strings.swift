import MonkeysPawCore

/// Front-end copy; shared delivery and setup instructions stay in Core's tables.
enum Strings {
    static let showPanel = "Show Panel"
    static let setup = "Setup…"
    static let setupTitle = "Monkey's Paw Setup"
    static let copy = "Copy"
    static let cancel = "Cancel"
    static let searchPrompts = "Search prompts"
    static let promptResults = "Prompt results"
    static let favorite = "Favourite"
    static let preview = "Preview"
    static let fillForm = "Fill prompt"
    static let chooseValue = "Choose a value"
    static let usePrompt = "Use"
    static let deliver = "Deliver"
    static let edit = "Edit"
    static let library = "Library"
    static let emptyLibrary = "Your library is empty. Open the library folder to add a prompt."
    static let libraryUnavailable = "Library unavailable. Cached prompts remain available. Check the folder and restart to retry."
    static let promptFileUnavailable = "This prompt's file is unavailable."
    static let assistantNotConfigured = "Set up a provider in Settings"
    static let preparingPreview = "Preparing preview…"
    static let newPromptBody = "Write your prompt here.\n"
    static let createPromptFailed = "Could not create the prompt. Check library and app-data permissions."
    static let pickerHint = "Return: use · ⌘Return: edit · ⌘L: library · ⌥Return: copy · Esc: close"
    static let fillHint = "Tab: next field · Return (single-line): deliver · ⌘Return: paste · ⌥Return: copy · Esc: back"
    static let noPasteTarget = "No paste target"

    static func pasteTarget(_ name: String) -> String { "→ " + name + " · Local library" }

    static func persistenceWarning(_ warning: PromptPersistenceWarning) -> String {
        switch warning {
        case .rememberedValuesUnavailable: return "Remembered values unavailable. Defaults are shown."
        case .rememberedValuesNotSaved: return "Delivered, but your field values could not be saved."
        case .usageNotSaved: return "Delivered, but your recent use could not be saved."
        }
    }
    static let runSelfTest = "Run self-test"
    static let testing = "Testing paste…"
    static let refresh = "Refresh"
    static let fix = "Fix…"
    static let accessibilityFix = "Grant Monkey's Paw in System Settings → Privacy & Security → Accessibility. An app update may require a new grant."
    static let selfTestWindowTitle = "Monkey's Paw Paste Test"
    static let selfTestPlaceholder = "The self-test pastes here"
    static let defaultHotkey = "Carbon default: ⌃⌥P"
    static let carbonRegistered = "Carbon shortcut registered"
    static let carbonUnsupportedKey = "This key has no macOS Carbon shortcut equivalent. Choose another key."
    static let carbonOverlappingModifiers = "Cmd, Super, and CmdOrCtrl all mean Command on macOS. Use only one."
    static let carbonTranslationFailure = "Could not translate this shortcut."
    static let carbonHandlerFailure = "Could not install the Carbon shortcut handler."

    static func carbonRegistrationFailure(status: Int32) -> String {
        "Could not register the shortcut (Carbon status \(status)). It may be in use."
    }

    static func rowTitle(_ kind: SetupRow.Kind) -> String {
        switch kind {
        case .accessibility: return "Accessibility"
        case .portal: return "GNOME/KDE portal"
        case .ydotool: return "ydotool"
        case .hotkey: return "Hotkey"
        case .kde: return "KDE shortcut"
        }
    }

    static func status(_ status: SetupStatus) -> String {
        switch status {
        case .ok: return "Ready"
        case .needsAction(let fix): return fix
        case .notApplicable: return "Not applicable on macOS"
        case .unknown: return "Not checked"
        }
    }

    static func backend(_ backend: PasteBackend) -> String {
        switch backend {
        case .cgEvent: return "CGEvent"
        case .appleScript: return "AppleScript"
        case .remoteDesktopPortal: return "RemoteDesktop portal"
        case .ydotool: return "ydotool"
        case .xdotool: return "xdotool"
        }
    }

    static func selfTestStatus(_ status: SelfTestStatus) -> String {
        switch status {
        case .pasted: return "Passed: text received"
        case .sentButNotReceived: return "Failed: sent, but no text received"
        case .failed(let failure):
            switch failure {
            case .permissionDenied: return "Failed: permission denied"
            case .toolMissing: return "Failed: tool missing"
            case .timeout: return "Failed: timed out"
            case .portalDenied: return "Failed: portal denied"
            case .backendUnavailable: return "Failed: backend unavailable"
            case .notReceived: return "Failed: no text received"
            case .unknown: return "Failed: unknown error"
            }
        }
    }
}
