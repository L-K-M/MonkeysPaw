import MonkeysPawCore
import XCTest

final class DeliverySettingsStringsTests: XCTestCase {
    func testChordLabelsKeepMacOSFixedAndExplainLinuxSessionLimits() {
        for chord in [PasteChord.standard, .terminal] {
            XCTAssertEqual(DeliverySettingsStrings.chordLabel(chord, session: .macOS), "Cmd+V")
        }
        XCTAssertEqual(DeliverySettingsStrings.chordLabel(.standard, session: .gnomeX11), "Standard (Ctrl+V)")
        XCTAssertEqual(DeliverySettingsStrings.chordLabel(.terminal, session: .kdeWayland), "Terminal (Ctrl+Shift+V)")
        for session in [DesktopSession.gnomeX11, .kdeX11, .otherX11] {
            XCTAssertEqual(DeliverySettingsStrings.chordExplanation(for: session), DeliverySettingsStrings.x11Explanation)
        }
        for session in [DesktopSession.gnomeWayland, .kdeWayland] {
            XCTAssertEqual(DeliverySettingsStrings.chordExplanation(for: session), DeliverySettingsStrings.waylandExplanation)
        }
        XCTAssertEqual(DeliverySettingsStrings.chordExplanation(for: .wlroots),
                       DeliverySettingsStrings.wlrootsExplanation)
        XCTAssertEqual(DeliverySettingsStrings.chordExplanation(for: .flatpak(host: .gnomeX11)),
                       DeliverySettingsStrings.flatpakExplanation)
        XCTAssertEqual(DeliverySettingsStrings.restoreCaveat,
                       "Previous text only; 750 ms delay may be too short for some apps.")
    }
}
