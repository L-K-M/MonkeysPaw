/// Shared Delivery copy; platform views render controls and accessibility labels.
public enum DeliverySettingsStrings {
    public static let title = "Delivery"
    public static let defaultChord = "Default paste chord"
    public static let standardChord = "Standard (Ctrl+V)"
    public static let terminalChord = "Terminal (Ctrl+Shift+V)"
    public static let macOSChord = "Cmd+V"
    public static let restoreClipboard = "Restore previous clipboard text"
    public static let restoreCaveat = "Previous text only; 750 ms delay may be too short for some apps."
    public static let testPaste = "Test paste"
    public static let openSetup = "Open Setup…"
    public static let x11Explanation = "Known X11 terminals use Ctrl+Shift+V; other targets use your default. Explicit paste and Copy choices override the default."
    public static let waylandExplanation = "Wayland cannot detect terminals. Choose your default or an explicit paste chord. Allow portal access in Setup; failed paste attempts fall back to Copy."
    public static let wlrootsExplanation = "Wayland cannot detect terminals. Choose your default or an explicit paste chord. Check paste permissions in Setup; failed paste attempts fall back to Copy."
    public static let flatpakExplanation = "Flatpak cannot detect terminals. Choose your default or an explicit paste chord. Allow portal access in Setup; delivery uses the portal or falls back to Copy."
    public static let macOSExplanation = "Paste uses Cmd+V. Check Accessibility and fallback permission status in Setup."

    public static func chordLabel(_ chord: PasteChord, session: DesktopSession) -> String {
        if session == .macOS { return macOSChord }
        return chord == .terminal ? terminalChord : standardChord
    }

    public static func chordExplanation(for session: DesktopSession) -> String {
        switch session {
        case .macOS: return macOSExplanation
        case .gnomeX11, .kdeX11, .otherX11: return x11Explanation
        case .flatpak: return flatpakExplanation
        case .gnomeWayland, .kdeWayland: return waylandExplanation
        case .wlroots: return wlrootsExplanation
        }
    }
}
