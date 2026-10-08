public enum PasteLadder {
    /// The §6.1 order is intentional: Mutter may silently drop uinput events.
    public static func backends(for session: DesktopSession) -> [PasteBackend] {
        switch session {
        case .macOS:
            return [.cgEvent, .appleScript]
        case .gnomeWayland, .gnomeX11:
            return [.remoteDesktopPortal, .ydotool]
        case .kdeWayland, .kdeX11:
            return [.ydotool, .remoteDesktopPortal]
        case .otherX11:
            return [.xdotool, .ydotool]
        case .wlroots:
            return [.ydotool]
        case .flatpak:
            return [.remoteDesktopPortal]
        }
    }
}
