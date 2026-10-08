#if os(Linux)
import Foundation
import MonkeysPawCore

/// §4.6: Linux relies on compositor refocus; it never activates another window.
final class LinuxFocusTracker: FocusTracker {
    private let session: SessionProbe
    private let runner: LinuxToolRunner
    private static let classPattern = try! NSRegularExpression(
        pattern: #"\AWM_CLASS\(STRING\) = "([^"\\\p{Cc}]*)", "([^"\\\p{Cc}]+)"\z"#)

    init(session: SessionProbe, runner: LinuxToolRunner) {
        self.session = session
        self.runner = runner
    }

    func captureTarget() -> DeliveryTarget? {
        let detected = session.currentSession()
        switch detected {
        case .gnomeX11, .kdeX11, .otherX11:
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Limits.linuxFocusProbeTimeout)
            guard case .success(let activeWindow) = runner.run("xdotool",
                arguments: ["getactivewindow"], timeout: clock.now.duration(to: deadline)),
                !activeWindow.text.isEmpty,
                activeWindow.text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let windowID = UInt64(activeWindow.text), windowID > 0,
                clock.now < deadline else { return nil }

            // Both subprocesses spend the same synchronous UI capture budget.
            guard case .success(let output) = runner.run("xprop",
                arguments: ["-id", String(windowID), "WM_CLASS"], timeout: clock.now.duration(to: deadline)),
                clock.now < deadline,
                let match = Self.classPattern.firstMatch(in: output.text,
                    range: NSRange(output.text.startIndex..., in: output.text)),
                let instanceRange = Range(match.range(at: 1), in: output.text),
                let classRange = Range(match.range(at: 2), in: output.text) else { return nil }

            let instance = String(output.text[instanceRange])
            let windowClass = String(output.text[classRange])
            // GTK's X11 class comes from g_set_prgname at process startup.
            // Case-insensitive comparison also catches GTK's capitalized class.
            guard ![instance, windowClass].contains(where: {
                $0.lowercased() == AppIdentity.linuxAppID.lowercased()
            }) else { return nil }
            return .linux(session: detected, x11WindowClass: windowClass)
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
