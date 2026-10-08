import MonkeysPawCore
import XCTest

final class DeliveryStringsTests: XCTestCase {
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
