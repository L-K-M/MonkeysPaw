#if os(Linux)
import MonkeysPawCore

/// Linux-only copy; delivery notifications use Core's DeliveryStrings.
enum LinuxStrings {
    static let installShortcut = "Install the GNOME shortcut in Setup"
    static let shortcutFailed = "Could not install the GNOME shortcut. Bind: " + GnomeKeybindingInstaller.command
    static let panelHint = "Return: paste · Ctrl+Shift+Return: terminal paste · Esc: cancel"
    static let setup = "Setup"
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
