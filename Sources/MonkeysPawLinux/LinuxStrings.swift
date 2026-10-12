#if os(Linux)
import MonkeysPawCore

/// Linux-only copy; delivery notifications use Core's DeliveryStrings.
enum LinuxStrings {
    static let installShortcut = "Install the GNOME shortcut in Setup"
    static let shortcutFailed = "Could not install the GNOME shortcut. Bind: " + GnomeKeybindingInstaller.command
    static let pickerHint = "Return: use · Ctrl+Return: edit · Ctrl+L: library · Esc: close\nCtrl+Shift+Return: terminal paste · Alt+Return: copy only"
    static let fillHint = "Tab: next field · Return: deliver · Ctrl+Return: standard paste\nCtrl+Shift+Return: terminal paste · Alt+Return: copy only · Esc: back"
    static let searchPrompts = "Search prompts"
    static let preview = "Preview"
    static let usePrompt = "Use"
    static let deliver = "Deliver"
    static let copy = "Copy"
    static let cancel = "Cancel"
    static let edit = "Edit"
    static let library = "Library"
    static let emptyLibrary = "Your library is empty. Open the library folder to add a prompt."
    static let libraryUnavailable = "Library unavailable. Cached prompts remain available. Check the folder and restart to retry."
    static let promptFileUnavailable = "This prompt's file is unavailable."
    static let assistantNotConfigured = "Set up a provider in Settings"
    static let resolvingBuiltins = "Reading clipboard…"
    static let preparingPreview = "Preparing preview…"
    static let rememberedValuesUnavailable = "Remembered values unavailable. Defaults are shown."
    static let rememberedValuesNotSaved = "Delivered, but your field values could not be saved."
    static let usageNotSaved = "Delivered, but your recent use could not be saved."
    static let newPromptBody = "Write your prompt here.\n"
    static let createPromptFailed = "Could not create the prompt. Check library and app-data permissions."

    static func persistenceWarning(_ warning: PromptPersistenceWarning) -> String {
        switch warning {
        case .rememberedValuesUnavailable: return rememberedValuesUnavailable
        case .rememberedValuesNotSaved: return rememberedValuesNotSaved
        case .usageNotSaved: return usageNotSaved
        }
    }

    static func pickerSession(_ session: DesktopSession) -> String {
        switch session {
        case .gnomeX11, .kdeX11, .otherX11: return "→ X11 · Local library"
        case .flatpak: return "→ Flatpak · Local library"
        default: return "→ Wayland · Local library"
        }
    }
    static let setup = "Setup"
    static let settings = "Settings"
    static let openSettings = "Settings…"
    static let openSetup = "Open Setup…"
    static let generalTab = "General"
    static let shortcutsTab = "Shortcuts"
    static let libraryFolder = "Your library folder"
    static let defaultLibraryFolder = "You are using the default library folder."
    static let customLibraryFolder = "You are using a custom library folder."
    static let chooseFolder = "Choose…"
    static let chooseLibraryFolder = "Choose your library folder"
    static let choose = "Choose"
    static let useDefault = "Use Default"
    static let openFolder = "Open Folder"
    static let togglePicker = "Toggle picker"
    static let repeatLast = "Repeat last"
    static let repeatUnavailable = "Inactive. Unavailable for configuration."
    static let setupShortcut = "Set up shortcut"
    static let showInstructions = "Show instructions"

    static func shortcutBinding(_ binding: ShortcutsSettingsModel.Binding) -> String {
        switch binding {
        case .unknown: return unknown
        case .unbound: return SetupStrings.unboundShortcut
        case .reported(let text): return text
        case .accelerator(let accelerator): return (try? accelerator.gtkAccelerator()) ?? unknown
        }
    }

    static func shortcutRegistration(_ registration: HotkeyRegistration?) -> String {
        guard let registration else { return unknown }
        let mechanism: String
        switch registration.mechanism {
        case .globalShortcutsPortal: mechanism = "Desktop shortcut portal"
        case .gnomeCustomKeybinding: mechanism = "GNOME keyboard shortcut"
        case .kglobalaccel: mechanism = "KDE global shortcut"
        case .manual: mechanism = "Manual shortcut"
        case .carbon: mechanism = "Carbon"
        }
        let status: String
        switch registration.status {
        case .registered: status = "Registered"
        case .unbound: status = SetupStrings.unboundShortcut
        case .needsAction: status = "Needs your action"
        case .failed: status = "Registration failed"
        }
        return ([mechanism, status, registration.detail]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func shortcutVerification(_ verification: ShortcutVerification) -> String {
        switch verification {
        case .notStarted: return "Your shortcut has not been verified."
        case .waiting: return "Waiting for you to press your shortcut."
        case .verified: return "Your shortcut is verified."
        }
    }

    static func shortcutError(_ error: ShortcutRebindError) -> String {
        switch error {
        case .unavailable: return "You cannot change this shortcut in the app. Follow your desktop's instructions."
        case .invalidAccelerator, .unsupportedCarbonKey, .overlappingCommandModifiers:
            return "Your shortcut could not be changed. Choose a supported key combination."
        }
    }
    static let testPaste = "Test paste"
    static let selfTestTitle = "Monkey's Paw: Test paste"
    static let portalAllow = "Allow keyboard access in Setup, then run Test paste"
    static let portalUnavailable = "Keyboard portal unavailable. Check the desktop portal installation or use copy/paste"
    static let portalSessionLost = "Portal session closed. Allow access again, then run Test paste"
    static let portalTokenWriteFailed = "Keyboard access granted, but consent could not be saved. Check data-directory permissions"
    static let shortcutAllow = "Allow a global shortcut in Setup; you choose the keys"
    static let shortcutSessionLost = "Shortcut session closed. Allow the shortcut again in Setup"
    static let shortcutCancelled = "Shortcut consent cancelled or denied. Use Setup to try again"
    static let shortcutMigrationBlocked = "Disable the existing Monkey's Paw toggle binding in GNOME Settings, then retry in Setup"
    static let shortcutMigrationFailed = "Could not inspect or retire the old GNOME binding. Check GNOME Settings, then retry in Setup"
    static let configureShortcuts = "Change in system settings"
    static let allow = "Allow"
    static let kdeRegistering = "Checking the native KDE shortcut"
    static let kdeAssign = "No shortcut assigned. " + SetupStrings.kdeShortcut + ". Suggested default: Ctrl+Alt+P"
    static let kdeDefaultConflict = "No shortcut assigned; Ctrl+Alt+P is used by another action. Choose a free key in System Settings → Shortcuts → Monkey's Paw"
    static let kdeConflict = "This shortcut conflicts with another action. Choose a free key in System Settings → Shortcuts → Monkey's Paw, then retry in Setup"
    static let kdeUnavailable = "Could not register the native KDE shortcut. Check KGlobalAccel, then retry in Setup"
    static let kdeTimedOut = "The native KDE shortcut check timed out. Check KGlobalAccel, then retry in Setup"
    static let kdeLost = "The KDE shortcut service was lost. Restart KGlobalAccel, then retry in Setup"
    static let attachShortcutPortal = "Attach shortcut portal"
    static let useNativeKDE = "Use native KDE shortcut"
    static let kdePortalUnavailable = "The shortcut portal is unavailable. Use native KDE shortcut in Setup"
    static let kdeHandoffBlocked = "The KDE component has additional actions, contexts or changed keys. Keep the native shortcut; review Monkey's Paw in System Settings, then retry in Setup"
    static let kdeCleanupFailed = "Could not verify shortcut cleanup. Restart Monkey's Paw, then attach the portal or choose Use native KDE shortcut in Setup"
    static let kdeChoiceUnreadable = "Could not restore the shortcut mechanism choice. Saved native keys are preserved. Choose the mechanism again in Setup"
    static let kdeChoiceSaveFailed = "Could not save the shortcut mechanism choice. Check the app data directory permissions, then retry in Setup"

    static func portalFailure(_ failure: PasteFailure) -> String {
        switch failure {
        case .portalDenied: return "Keyboard access was denied or cancelled. Allow it again in Setup"
        case .timeout: return "Portal interaction timed out. Allow it again in Setup"
        default: return portalSessionLost
        }
    }
    static let ydotoolFix = """
        Install ydotool and start ydotoold. Allow access to /dev/uinput with:
        KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
        Add your user to the input group: sudo usermod -aG input "$USER"
        Log out and back in, then: systemctl --user enable --now ydotoold
        Set YDOTOOL_SOCKET to the daemon socket and make it readable and writable.
        """
    static let ydotoolDocs = "https://github.com/ReimuNotMoe/ydotool"
    static let ydotoolMissing = "ydotool was not found. " + ydotoolFix
    static let ydotoolSocketUnavailable = "ydotool's socket is unavailable. " + ydotoolFix
    static let fix = "Fix"
    static let refresh = "Refresh"
    static let verifyShortcut = "Press your shortcut now"
    static let ready = "Ready"
    static let notApplicable = "Not applicable"
    static let unknown = "Unknown"
    static let selfTestWorking = "Testing paste…"

    static func rowTitle(_ kind: SetupRow.Kind) -> String {
        switch kind {
        case .accessibility: return "Accessibility"
        case .portal: return "Desktop portal"
        case .ydotool: return "ydotool"
        case .hotkey: return "Hotkey"
        case .kde: return "KDE"
        }
    }
}
#endif
