import MonkeysPawCore
import XCTest

final class AcceleratorTests: XCTestCase {
    func testParsesDefaultsAndLeavesRepeatUnbound() throws {
        let expected = try Accelerator("Ctrl+Alt+P")
        XCTAssertEqual(try Accelerator("⌃⌥P"), expected)
        XCTAssertEqual(try Accelerator("Alt+Ctrl+P"), expected)
        XCTAssertEqual(expected.modifiers, [.control, .alt])
        XCTAssertEqual(expected.key, .character("p"))

        XCTAssertEqual(Accelerator.defaultBinding(for: .togglePicker), expected)
        XCTAssertNil(Accelerator.defaultBinding(for: .repeatLast))
    }

    func testParsesMixedGlyphAndPlusSpellings() throws {
        let table = [
            ("⌘+P", "Cmd+P"),
            ("⌃ + ⌥ + P", "Ctrl+Alt+P"),
            ("⌘⌥P", "Cmd+Alt+P"),
            ("⌘⌥+P", "Cmd+Alt+P"),
            ("⌘+Alt+P", "Cmd+Alt+P"),
            ("Ctrl+⌥P", "Ctrl+Alt+P"),
            ("Alt+⌘P", "Cmd+Alt+P"),
            ("⌥+⌃+P", "Ctrl+Alt+P"),
            ("⌃ ⌥ P", "Ctrl+Alt+P"),
            ("⇧ + ⌘ + P", "Cmd+Shift+P"),
            ("⌘+F12", "Cmd+F12"),
            ("⌘+⌥+Space", "Cmd+Alt+Space"),
        ]

        for (input, expected) in table {
            XCTAssertEqual(try Accelerator(input), try Accelerator(expected), input)
        }
    }

    func testGTKTranslationsFollowCopywraith() throws {
        let table = [
            ("Ctrl+Alt+P", "<Control><Alt>p"),
            ("Super+V", "<Super>v"),
            ("Meta+KeyV", "<Super>v"),
            ("command+V", "<Super>v"),
            ("control+Digit1", "<Control>1"),
            ("Option+Space", "<Alt>space"),
            ("CmdOrCtrl+F12", "<Control>F12"),
            ("Ctrl+ Shift + V", "<Control><Shift>v"),
            (" Shift+Alt+Control+Win+F24 ", "<Control><Alt><Shift><Super>F24"),
            ("F5", "F5"),
            ("Alt+Return", "<Alt>Return"),
            ("Ctrl+ArrowLeft", "<Control>Left"),
            ("Ctrl+PageDown", "<Control>Page_Down"),
            ("Ctrl+Quote", "<Control>apostrophe"),
            ("Ctrl+Plus", "<Control>plus"),
            ("PrintScreen", "Print"),
        ]

        for (input, expected) in table {
            XCTAssertEqual(try Accelerator(input).gtkAccelerator(), expected, input)
        }
    }

    func testRefusesUntranslatableOrMalformedShortcutsWithTypedErrors() {
        let table: [(String, AcceleratorError)] = [
            ("", .empty),
            ("   ", .empty),
            ("Hyper+V", .unsupportedModifier("Hyper")),
            ("Ctrl+Numpad0", .unsupportedKey("Numpad0")),
            ("Ctrl+F99", .unsupportedKey("F99")),
            ("Ctrl+F0", .unsupportedKey("F0")),
            ("Ctrl+é", .unsupportedKey("é")),
            ("Ctrl+V+B", .unsupportedModifier("V")),
            ("Ctrl++P", .malformed),
            ("Ctrl+", .malformed),
            ("⌘", .malformed),
            ("⌘ ", .malformed),
            ("⌘+ ", .malformed),
            ("⌘++P", .malformed),
            ("+⌘P", .malformed),
            ("Ctrl+⌥", .malformed),
            ("⌃⌥", .malformed),
            ("Ctrl+Control+P", .duplicateModifier(.control)),
            ("⌃+Ctrl+P", .duplicateModifier(.control)),
            ("⌘+⌘+P", .duplicateModifier(.command)),
        ]

        for (input, expected) in table {
            XCTAssertThrowsError(try Accelerator(input), input) { error in
                XCTAssertEqual(error as? AcceleratorError, expected)
            }
        }
    }

    func testGTKRefusesModifiersThatCollapseOnLinux() throws {
        for input in ["Ctrl+CmdOrCtrl+P", "Super+Cmd+P"] {
            let accelerator = try Accelerator(input)
            XCTAssertThrowsError(try accelerator.gtkAccelerator()) { error in
                XCTAssertEqual(error as? AcceleratorError, .conflictingGTKModifiers)
            }
        }
    }
}
