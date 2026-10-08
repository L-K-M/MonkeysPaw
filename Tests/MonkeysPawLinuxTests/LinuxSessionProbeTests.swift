#if os(Linux)
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxSessionProbeTests: XCTestCase {
    func testDesktopSessionTable() {
        let cases: [([String: String], DesktopSession)] = [
            (["XDG_CURRENT_DESKTOP": "ubuntu:GNOME", "XDG_SESSION_TYPE": "wayland"], .gnomeWayland),
            (["XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "x11"], .gnomeX11),
            (["XDG_CURRENT_DESKTOP": "KDE:Plasma", "WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"], .kdeWayland),
            (["XDG_CURRENT_DESKTOP": "plasma", "DISPLAY": ":1"], .kdeX11),
            (["XDG_CURRENT_DESKTOP": "XFCE", "DISPLAY": ":0"], .otherX11),
            (["XDG_CURRENT_DESKTOP": "sway", "WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":0"], .wlroots),
            (["XDG_CURRENT_DESKTOP": "Hyprland", "XDG_SESSION_TYPE": "wayland"], .wlroots),
            (["XDG_CURRENT_DESKTOP": "not-gnome", "XDG_SESSION_TYPE": "x11"], .otherX11),
            (["XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "X11", "WAYLAND_DISPLAY": "stale"], .gnomeX11),
            ([:], .wlroots),
        ]
        for (environment, session) in cases {
            XCTAssertEqual(LinuxSessionProbe.detect(environment: environment, flatpakInfoExists: false), session)
            XCTAssertEqual(LinuxSessionProbe.detect(environment: environment, flatpakInfoExists: true), .flatpak(host: session))
            var sandbox = environment
            sandbox["FLATPAK_ID"] = "ch.lkmc.monkeyspaw"
            XCTAssertEqual(LinuxSessionProbe.detect(environment: sandbox, flatpakInfoExists: false), .flatpak(host: session))
        }
        // macOS cannot be detected by a Linux driver; Core covers its ladder.
        XCTAssertEqual(LinuxSessionProbe.detect(environment: ["FLATPAK_ID": ""], flatpakInfoExists: false), .wlroots)
    }
}
#endif
