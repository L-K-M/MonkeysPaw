#if os(Linux)
import MonkeysPawCore

/// §4.6: Linux relies on compositor refocus; it never activates another window.
final class LinuxFocusTracker: FocusTracker {
    private let session: SessionProbe
    private let runner: LinuxToolRunner

    init(session: SessionProbe, runner: LinuxToolRunner) {
        self.session = session
        self.runner = runner
    }

    func captureTarget() -> DeliveryTarget? {
        let detected = session.currentSession()
        switch detected {
        case .gnomeX11, .kdeX11, .otherX11:
            guard case .success(let output) = runner.run("xdotool",
                arguments: ["getactivewindow", "getwindowclassname"],
                timeout: Limits.linuxFocusProbeTimeout), !output.text.isEmpty else { return nil }
            // GTK's X11 class comes from g_set_prgname at process startup.
            // Case-insensitive comparison also catches GTK's capitalized class.
            guard output.text.lowercased() != AppIdentity.linuxAppID.lowercased() else { return nil }
            return .linux(session: detected, x11WindowClass: output.text)
        case .gnomeWayland, .kdeWayland, .wlroots, .flatpak, .macOS:
            // Wayland offers no active-window identity. Returning no target also
            // avoids ever capturing our own window through an XWayland query.
            return nil
        }
    }

    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        // DeliveryService already waited settleDelayLinux. Dismissal likewise
        // leaves focus with the compositor, including when the user clicked away.
        completion(.unconfirmed)
    }
}
#endif
