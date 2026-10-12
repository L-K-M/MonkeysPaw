import MonkeysPawCore

/// Front-end copy; shared delivery and setup instructions stay in Core's tables.
enum Strings {
    static let showPanel = "Show Panel"
    static let setup = "Setup…"
    static let setupTitle = "Monkey's Paw Setup"
    static let settings = "Settings…"
    static let settingsTitle = "Monkey's Paw Settings"
    static let generalTab = "General"
    static let shortcutsTab = "Shortcuts"
    static let libraryFolder = "Library folder"
    static let defaultLibraryFolder = "You are using the default library folder."
    static let chosenLibraryFolder = "You are using a folder you chose."
    static let chooseFolder = "Choose…"
    static let useDefaultFolder = "Use Default"
    static let showInFinder = "Show in Finder"
    static let togglePicker = "Toggle picker"
    static let repeatLast = "Repeat last"
    static let repeatUnavailable = "Repeat last is not available yet."
    static let openSetup = "Open Setup…"
    static let changeShortcut = "Change shortcut…"
    static let configureShortcut = "Configure in Setup…"
    static let recordShortcut = "Record shortcut…"
    static let recordingShortcut = "Press a shortcut; Escape cancels"
    static let shortcutCaptureHint = "Record a key with Control, Option, Shift or Command. Escape cancels."
    static let unknownShortcut = "Your shortcut is unknown."
    static let shortcutUnavailable = "Your shortcut cannot be changed right now."
    static let invalidShortcut = "Choose one key with modifier keys for your shortcut."

    static func shortcutError(_ error: ShortcutRebindError) -> String {
        switch error {
        case .unavailable: return shortcutUnavailable
        case .invalidAccelerator: return invalidShortcut
        case .unsupportedCarbonKey: return carbonUnsupportedKey
        case .overlappingCommandModifiers: return carbonOverlappingModifiers
        }
    }

    static func shortcutBinding(_ binding: ShortcutsSettingsModel.Binding) -> String {
        switch binding {
        case .unknown: return unknownShortcut
        case .unbound: return SetupStrings.unboundShortcut
        case .reported(let text): return text
        case .accelerator(let accelerator):
            var parts: [String] = []
            let modifiers: [(Accelerator.Modifier, String)] = [
                (.control, "Ctrl"), (.alt, "Alt"), (.shift, "Shift"), (.command, "Cmd"),
                (.superKey, "Super"), (.commandOrControl, "Cmd"),
            ]
            for (modifier, name) in modifiers where accelerator.modifiers.contains(modifier) { parts.append(name) }
            parts.append(acceleratorKeyName(accelerator.key))
            return parts.joined(separator: "+")
        }
    }

    /// Native capture and binding display share names the Core parser accepts.
    static func acceleratorKeyName(_ key: Accelerator.Key) -> String {
        switch key {
        case .character(let key): return String(key).uppercased()
        case .function(let number): return "F\(number)"
        case .named(let key):
            switch key {
            case .pageUp: return "PageUp"
            case .pageDown: return "PageDown"
            case .quote: return "Quote"
            case .backspace: return "Backspace"
            case .bracketLeft: return "BracketLeft"
            case .bracketRight: return "BracketRight"
            case .printScreen: return "PrintScreen"
            default: return key.rawValue.prefix(1).uppercased() + key.rawValue.dropFirst()
            }
        }
    }

    static func hotkeyMechanism(_ mechanism: HotkeyMechanism) -> String {
        switch mechanism {
        case .carbon: return "Carbon"
        case .globalShortcutsPortal: return "Global Shortcuts portal"
        case .kglobalaccel: return "KGlobalAccel"
        case .gnomeCustomKeybinding: return "GNOME keyboard shortcut"
        case .manual: return "Manual shortcut"
        }
    }

    static func registrationStatus(_ status: RegistrationStatus) -> String {
        switch status {
        case .registered: return "Registered"
        case .unbound: return "Unbound"
        case .needsAction: return "Action required"
        case .failed: return "Failed"
        }
    }

    static func shortcutVerification(_ verification: ShortcutVerification) -> String {
        switch verification {
        case .notStarted: return "Not verified"
        case .waiting: return "Waiting for your shortcut"
        case .verified: return "Verified"
        }
    }
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
    static let carbonOverlappingModifiers = "This shortcut repeats the Command modifier. Use Command only once."
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
