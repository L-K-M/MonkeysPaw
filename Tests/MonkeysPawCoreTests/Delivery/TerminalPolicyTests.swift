import MonkeysPawCore
import XCTest

final class TerminalPolicyTests: XCTestCase {
    func testExactCaseInsensitiveAliasesForEveryNativeX11Session() {
        let aliases = ["Gnome-terminal", "gnome-terminal-server", "konsole", "Xfce4-terminal",
                       "mate-terminal", "Tilix", "Alacritty", "kitty"]
        for session: DesktopSession in [.gnomeX11, .kdeX11, .otherX11] {
            for alias in aliases {
                for spelling in [alias, alias.lowercased(), alias.uppercased()] {
                    let target = DeliveryTarget.linux(session: session, x11WindowClass: spelling)
                    for saved: PasteChord in [.standard, .terminal] {
                        XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: session,
                                                                      defaultChord: saved), .terminal)
                    }
                }
            }
        }
    }

    func testLookalikesExcludedTerminalsUnknownEmptyAndOwnClassUseSavedDefault() {
        let classes: [String?] = [nil, "", "Firefox", "XTerm", "URxvt", "st", "Code",
                                 "Gnome-terminal-helper", "kitty-editor", "my-konsole", "Tilix terminal",
                                 " kitty", "kitty ", "kitty\n", "\"kitty\"", "kitty\0", "Kitty", "kıtty",
                                 "Ｋｉｔｔｙ", AppIdentity.linuxAppID, AppIdentity.linuxAppID.uppercased()]
        for windowClass in classes {
            let target = DeliveryTarget.linux(session: .otherX11, x11WindowClass: windowClass)
            for saved: PasteChord in [.standard, .terminal] {
                XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: .otherX11,
                                                              defaultChord: saved), saved)
            }
        }
    }

    func testWaylandAndFlatpakIgnoreEvenAProvidedTerminalClass() {
        for session: DesktopSession in [.gnomeWayland, .kdeWayland, .wlroots,
                                       .flatpak(host: .otherX11), .flatpak(host: .gnomeX11),
                                       .flatpak(host: .kdeWayland)] {
            for target: DeliveryTarget? in [nil,
                .linux(session: session, x11WindowClass: "konsole"),
                .linux(session: .otherX11, x11WindowClass: "kitty")] {
                for saved: PasteChord in [.standard, .terminal] {
                    XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: session,
                                                                  defaultChord: saved), saved)
                }
            }
        }
    }

    func testMissingMismatchedOrMacOSTargetAndMacOSDefault() {
        for target: DeliveryTarget? in [nil, .macOS(processID: 42, bundleID: nil),
            .linux(session: .gnomeX11, x11WindowClass: "kitty"),
            .linux(session: .kdeWayland, x11WindowClass: "konsole")] {
            for saved: PasteChord in [.standard, .terminal] {
                XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: .otherX11,
                                                              defaultChord: saved), saved)
                XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: .macOS,
                                                              defaultChord: saved), .standard)
            }
        }
        XCTAssertEqual(TerminalPolicy.recommendedChord(for: nil, session: .otherX11), .standard)
    }
}
