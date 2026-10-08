#if os(Linux)
import MonkeysPawCore

/// Linux-only copy; delivery notifications use Core's DeliveryStrings.
enum LinuxStrings {
    static let installingShortcut = "Installing the GNOME shortcut"
    static let shortcutFailed = "Could not install the GNOME shortcut. Bind: " + GnomeKeybindingInstaller.command
    static let panelHint = "Return: paste · Ctrl+Shift+Return: terminal paste · Esc: cancel"
    static let setup = "Setup"
    static let testPaste = "Test paste"
    static let selfTestTitle = "Monkey's Paw: Test paste"
    static let portalDeferred = "Added in M1c"
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
