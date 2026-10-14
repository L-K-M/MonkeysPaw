@testable import MonkeysPawCore
import XCTest

final class DeliveryStringsTests: XCTestCase {
    func testHintAndFallbackUseChosenChordAndGenericTargetWithoutEchoingClass() {
        let terminal = DeliveryTarget.linux(session: .otherX11, x11WindowClass: "kitty")
        XCTAssertEqual(DeliveryStrings.hint(mode: .paste(.standard), target: terminal, session: .otherX11),
                       "X11 terminal · Ctrl+V")
        XCTAssertEqual(DeliveryStrings.hint(mode: .copyOnly, target: terminal, session: .otherX11),
                       "X11 terminal · Copy only")
        XCTAssertEqual(DeliveryStrings.pressPaste(chord: .terminal, session: .otherX11, target: terminal),
                       "Copied. Press Ctrl+Shift+V\nX11 terminal")
        for target: DeliveryTarget? in [nil, .linux(session: .otherX11, x11WindowClass: nil),
                                       .linux(session: .otherX11, x11WindowClass: AppIdentity.linuxAppID)] {
            XCTAssertEqual(DeliveryStrings.hint(mode: .paste(.standard), target: target, session: .otherX11),
                           "Target unknown · Ctrl+V")
        }
        XCTAssertEqual(DeliveryStrings.hint(mode: .paste(.terminal), target: terminal, session: .gnomeWayland),
                       "Target unknown · Ctrl+Shift+V")
        XCTAssertEqual(DeliveryStrings.hint(mode: .paste(.terminal), target: nil, session: .macOS),
                       "macOS target · Cmd+V")
    }

    func testPressPasteUsesThePlatformAndSelectedChord() {
        let table: [(DesktopSession, PasteChord, String)] = [
            (.macOS, .standard, "Copied. Press Cmd+V"),
            (.macOS, .terminal, "Copied. Press Cmd+V"),
            (.gnomeWayland, .standard, "Copied. Press Ctrl+V"),
            (.gnomeWayland, .terminal, "Copied. Press Ctrl+Shift+V"),
        ]
        for (session, chord, expected) in table {
            XCTAssertEqual(DeliveryStrings.pressPaste(chord: chord, session: session), expected)
        }
    }
}
