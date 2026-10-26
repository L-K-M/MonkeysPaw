import MonkeysPawCore

/// Front-end copy; shared delivery and setup instructions stay in Core's tables.
enum Strings {
    static let showPanel = "Show Picker"
    static let about = "About Monkey's Paw"
    static let quit = "Quit Monkey's Paw"
    static let aboutDescription = "Keep your prompts ready to fill, copy and paste."
    static let projectLink = "Monkey's Paw on GitHub"
    static let thirdPartyNotices = "Third-party notices"
    static let setup = "Setup…"
    static let setupTitle = "Monkey's Paw Setup"
    static let settings = "Settings…"
    static let settingsTitle = "Monkey's Paw Settings"
    static let onboardingTitle = "Monkey's Paw Library Setup"
    static let onboardingComplete = "Your library is ready."
    static let defaultFolder = "Default folder"
    static let done = "Done"
    static let generalTab = "General"
    static let shortcutsTab = "Shortcuts"
    static let libraryFolder = "Library Folder"
    static let rememberedValues = "Remembered Values"
    static let rememberedValuesExplanation = "Saved field values are reused the next time you fill a prompt."
    static let defaultLibraryFolder = "You are using the default library folder."
    static let chosenLibraryFolder = "You are using a folder you chose."
    static let chooseFolder = "Choose…"
    static let useDefaultFolder = "Use Default"
    static let showInFinder = "Show in Finder"
    static let togglePicker = "Show Picker"
    static let repeatLast = "Repeat Last Prompt"
    static let shortcutBindingLabel = "Shortcut"
    static let shortcutStatusLabel = "Status"
    static let libraryLocation = "Location"
    static let testShortcut = "Test Shortcut"
    static let openRepeatPrompt = "Open prompt"
    static let clearShortcut = "Clear"
    static let openSetup = "Open Setup…"
    static let changeShortcut = "Change shortcut…"
    static let configureShortcut = "Configure in Setup…"
    static let recordShortcut = "Record Shortcut"
    static let recordingShortcut = "Type Shortcut…"
    static let shortcutCaptureHint = "Record a key with Control, Option, Shift or Command. Escape cancels."
    static let unknownShortcut = "Your shortcut is unknown."
    static let shortcutUnavailable = "Your shortcut cannot be changed right now."
    static let invalidShortcut = "Choose one key with modifier keys for your shortcut."

    static func recordShortcutLabel(_ action: String) -> String { "Record shortcut for " + action }
    static func clearShortcutLabel(_ action: String) -> String { "Clear shortcut for " + action }
    static func verifyShortcutLabel(_ action: String) -> String { "Verify shortcut for " + action }

    static func shortcutRegistration(_ registration: HotkeyRegistration) -> String {
        hotkeyMechanism(registration.mechanism) + ": " + registrationStatus(registration.status)
    }

    static func repeatMessage(_ result: RepeatResult) -> String? {
        switch result {
        case .nothingToRepeat: return "Nothing to repeat"
        case .reviewRequired(_, let reason):
            switch reason {
            case .sessionOnlyValues: return "Your last delivery used values kept only for that session. Open the prompt and fill it again."
            case .sourceChanged: return "Your last prompt changed. Open it and review it before delivering again."
            case .outputTooLarge: return PromptRenderError.outputTooLarge.description
            case .sourceUnavailable: return "Your last prompt is unavailable. Check your library, then open the prompt again."
            }
        case .unavailable(let failure):
            switch failure {
            case .ownWindow: return "Focus the app you want to paste into, then repeat again."
            case .invalidationFailed: return "Repeat could not be cleared. Check your app data permissions and retry the library change or Forget values."
            case .corruptRecord, .futureRecord, .recordTooLarge: return "Your saved repeat record cannot be read. Deliver a prompt to replace it."
            case .readFailed: return "Repeat could not be read. Check your app data permissions, then retry."
            case .writeFailed: return "Repeat could not be saved. Check your app data permissions."
            case .invalidBinding, .inactive: return "Repeat is unavailable for this library."
            }
        case .delivered(_, let warnings):
            return warnings.isEmpty ? nil : warnings.map(persistenceWarning).joined(separator: "\n")
        case .cancelled: return nil
        }
    }

    static func shortcutError(_ error: ShortcutRebindError) -> String {
        switch error {
        case .unavailable: return shortcutUnavailable
        case .invalidAccelerator: return invalidShortcut
        case .unsupportedCarbonKey: return carbonUnsupportedKey
        case .overlappingCommandModifiers: return carbonOverlappingModifiers
        case .collision: return "This key is assigned to your other Monkey's Paw action."
        case .registrationFailed: return "Your shortcut could not be registered. Your previous choice was restored."
        case .saveFailed: return "Your shortcut could not be saved. Your previous choice was restored."
        case .recoveryFailed: return "Your previous shortcut could not be restored. Assign it again."
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

    /// Mac menus and System Settings show shortcuts as symbols in ⌃⌥⇧⌘ order,
    /// for example "⌃⌥P". Unbound or unknown bindings have no symbol form.
    static func shortcutSymbols(_ binding: ShortcutsSettingsModel.Binding) -> String? {
        guard case .accelerator(let accelerator) = binding else { return nil }
        let modifiers: [(Accelerator.Modifier, String)] = [
            (.control, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.superKey, "Super+"), (.command, "⌘"),
            (.commandOrControl, "⌘"),
        ]
        var text = ""
        for (modifier, symbol) in modifiers where accelerator.modifiers.contains(modifier) { text += symbol }
        return text + keySymbol(accelerator.key)
    }

    private static func keySymbol(_ key: Accelerator.Key) -> String {
        guard case .named(let name) = key else { return acceleratorKeyName(key) }
        switch name {
        case .space: return "Space"
        case .enter: return "↩"
        case .tab: return "⇥"
        case .escape: return "⎋"
        case .backspace: return "⌫"
        case .delete: return "⌦"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .backslash: return "\\"
        case .minus: return "-"
        case .equal: return "="
        case .plus: return "+"
        case .semicolon: return ";"
        case .quote: return "'"
        case .grave: return "`"
        case .bracketLeft: return "["
        case .bracketRight: return "]"
        case .insert, .printScreen: return acceleratorKeyName(key)
        }
    }

    /// macOS has one registration mechanism, so its status needs no "Carbon" prefix.
    static func shortcutStatus(_ registration: HotkeyRegistration) -> String {
        registration.mechanism == .carbon ? registrationStatus(registration.status) : shortcutRegistration(registration)
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
        case .unbound: return "Not set"
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
    static let paste = "Paste"
    static let back = "Back"
    static let pickerMore = "More actions"
    static let writeWithAssistant = "Write with Assistant"
    static func createPrompt(_ query: String) -> String { "Create “" + query + "”" }
    static let deliver = "Deliver"
    static let forgetValues = "Forget values"
    static let forgetAllValues = "Forget All Values…"
    static let edit = "Edit"
    static let library = "Library"
    static let openLibrary = "Open Library"
    static let emptyLibrary = "Your library is empty. Open Library, then Show in Finder to add a prompt."
    static let libraryUnavailable = "Library unavailable. Cached prompts remain available. Check the folder and restart to retry."
    static let promptFileUnavailable = "This prompt's file is unavailable."
    static let assistantNotConfigured = "Set up a provider in Settings"
    static let preparingPreview = "Preparing preview…"
    static let newPromptBody = "Write your prompt here.\n"
    static let createPromptFailed = "Could not create the prompt. Check library and app-data permissions."
    static let pickerHint = "Return: use · ⌘Return: edit · ⌘L: library · ⌥Return: copy · Esc: close"
    static let fillHint = "Tab: next field · Return (single-line): deliver · ⌘Return: paste · ⌥Return: copy · Esc: back"
    static let noPasteTarget = "No paste target"

    static func pasteTarget(_ name: String) -> String { "→ " + name }

    static func persistenceWarning(_ warning: PromptPersistenceWarning) -> String {
        switch warning {
        case .rememberedValuesUnavailable: return "Remembered values unavailable. Defaults are shown."
        case .rememberedValuesNotSaved: return "Delivered, but your field values could not be saved."
        case .usageNotSaved: return "Delivered, but your recent use could not be saved."
        case .lastDeliveryNotSaved: return "Delivered, but repeat could not be saved."
        }
    }

    static func forgetValuesError(_ error: Error, state: PickerModel.State) -> String {
        if state == .delivering, error as? LibraryError == .operationFailed {
            return RememberedValuesStrings.message(for: .deliveryInFlight)
        }
        if let error = error as? FileStoreError {
            return RememberedValuesStrings.message(for: .fileStoreFailure(error))
        }
        return RememberedValuesStrings.message(for: .libraryFailure(error as? LibraryError ?? .operationFailed))
    }
    static let runSelfTest = "Run self-test"
    static let testing = "Testing paste…"
    static let refresh = "Refresh"
    static let fix = "Fix…"
    static let accessibilityFix = "Grant Monkey's Paw in System Settings → Privacy & Security → Accessibility. An app update may require a new grant."
    static let selfTestWindowTitle = "Monkey's Paw Paste Test"
    static let selfTestPlaceholder = "The self-test pastes here"
    static let defaultHotkey = "Default shortcut: ⌃⌥P"
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
        case .hotkey: return "Keyboard Shortcut"
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
        // Name what the user grants, not the API: keystrokes need Accessibility,
        // the fallback needs Automation of System Events.
        case .cgEvent: return "Keystroke"
        case .appleScript: return "System Events"
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
