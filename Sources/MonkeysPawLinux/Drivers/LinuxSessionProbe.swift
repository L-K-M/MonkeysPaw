#if os(Linux)
import Foundation
import MonkeysPawCore

struct LinuxSessionProbe: SessionProbe {
    private let session: DesktopSession

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         flatpakInfoExists: Bool = FileManager.default.fileExists(atPath: "/.flatpak-info")) {
        session = Self.detect(environment: environment, flatpakInfoExists: flatpakInfoExists)
    }

    func currentSession() -> DesktopSession { session }

    /// Pure detection over a snapshot. DISPLAY under Wayland means XWayland,
    /// which must never select the X11-only injection ladder (§6.1).
    static func detect(environment: [String: String], flatpakInfoExists: Bool) -> DesktopSession {
        let desktop = (environment["XDG_CURRENT_DESKTOP"] ?? "").lowercased()
            .split(whereSeparator: { $0 == ":" || $0 == ";" })
        let type = (environment["XDG_SESSION_TYPE"] ?? "").lowercased()
        let wayland = type == "wayland" || (type != "x11" && !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty)
        let host: DesktopSession
        if desktop.contains("gnome") {
            host = wayland ? .gnomeWayland : .gnomeX11
        } else if desktop.contains("kde") || desktop.contains("plasma") {
            host = wayland ? .kdeWayland : .kdeX11
        } else if wayland {
            host = .wlroots
        } else if type == "x11" || !(environment["DISPLAY"] ?? "").isEmpty {
            host = .otherX11
        } else {
            // No positive X11 evidence: prefer the ladder that cannot inject into
            // an unrelated XWayland window. Self-test exposes missing tools.
            host = .wlroots
        }
        if flatpakInfoExists || !(environment["FLATPAK_ID"] ?? "").isEmpty {
            return .flatpak(host: host)
        }
        return host
    }
}
#endif
