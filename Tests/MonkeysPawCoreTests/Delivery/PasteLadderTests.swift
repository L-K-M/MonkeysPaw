import MonkeysPawCore
import XCTest

final class PasteLadderTests: XCTestCase {
    func testEverySessionMatchesSection61() {
        let table: [(DesktopSession, [PasteBackend])] = [
            (.macOS, [.cgEvent, .appleScript]),
            (.gnomeWayland, [.remoteDesktopPortal, .ydotool]),
            (.gnomeX11, [.remoteDesktopPortal, .ydotool]),
            (.kdeWayland, [.ydotool, .remoteDesktopPortal]),
            (.kdeX11, [.ydotool, .remoteDesktopPortal]),
            (.otherX11, [.xdotool, .ydotool]),
            (.wlroots, [.ydotool]),
            (.flatpak(host: .gnomeWayland), [.remoteDesktopPortal]),
            (.flatpak(host: .gnomeX11), [.remoteDesktopPortal]),
            (.flatpak(host: .kdeWayland), [.remoteDesktopPortal]),
            (.flatpak(host: .kdeX11), [.remoteDesktopPortal]),
            (.flatpak(host: .otherX11), [.remoteDesktopPortal]),
            (.flatpak(host: .wlroots), [.remoteDesktopPortal]),
        ]

        for (session, expected) in table {
            XCTAssertEqual(PasteLadder.backends(for: session), expected, "\(session)")
        }
    }
}
