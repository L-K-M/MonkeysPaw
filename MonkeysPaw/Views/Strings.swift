import MonkeysPawCore

/// Front-end copy; shared delivery and setup instructions stay in Core's tables.
enum Strings {
    static let showPanel = "Show Panel"
    static let setup = "Setup…"
    static let setupTitle = "Monkey's Paw Setup"
    static let cannedPromptTitle = "Test delivery"
    static let paste = "Paste"
    static let copy = "Copy"
    static let cancel = "Cancel"
    static let panelHint = "Return to paste · Option+Return to copy · Esc to cancel"
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
