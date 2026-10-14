/// G11/G12: recommendations only. Explicit paste and Copy modes bypass this
/// policy; class capture proves neither focus restoration nor text receipt.
public enum TerminalPolicy {
    private static let aliases: Set<String> = [
        "gnome-terminal", "gnome-terminal-server", "konsole", "xfce4-terminal",
        "mate-terminal", "tilix", "alacritty", "kitty",
    ]

    public static func recommendedChord(for target: DeliveryTarget?, session: DesktopSession,
                                        defaultChord: PasteChord = .standard) -> PasteChord {
        if session == .macOS { return .standard }
        guard let windowClass = nativeX11Class(for: target, session: session),
              aliases.contains(windowClass) else { return defaultChord }
        return .terminal
    }

    static func targetHint(for target: DeliveryTarget?, session: DesktopSession) -> String {
        if session == .macOS { return "macOS target" }
        guard let windowClass = nativeX11Class(for: target, session: session) else { return "Target unknown" }
        return aliases.contains(windowClass) ? "X11 terminal" : "X11 target"
    }

    private static func nativeX11Class(for target: DeliveryTarget?, session: DesktopSession) -> String? {
        switch session {
        case .gnomeX11, .kdeX11, .otherX11: break
        case .macOS, .gnomeWayland, .kdeWayland, .wlroots, .flatpak: return nil
        }
        guard case .linux(let capturedSession, let windowClass) = target,
              capturedSession == session, let windowClass, !windowClass.isEmpty,
              // Aliases are ASCII; Unicode lookalikes must not gain a match
              // through Unicode lowercasing (for example Kelvin-sign kitty).
              windowClass.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let normalized = windowClass.lowercased()
        guard normalized != AppIdentity.linuxAppID.lowercased() else { return nil }
        return normalized
    }
}
