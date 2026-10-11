import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacPickerKeysTests: XCTestCase {
    func testPickerTable() {
        let cases: [(Int, String?, NSEvent.ModifierFlags, MacPickerKeys.Intent)] = [
            (kVK_UpArrow, nil, [], .moveUp), (kVK_DownArrow, nil, [], .moveDown),
            (kVK_Escape, nil, [], .escape), (kVK_ANSI_L, "l", .command, .openLibrary),
            (kVK_ANSI_L, "L", .command, .openLibrary),
            (kVK_ANSI_L, "д", .command, .openLibrary),
            (kVK_ANSI_L, nil, .command, .openLibrary),
            (kVK_ANSI_A, "l", .command, .openLibrary),
        ]
        for (code, text, flags, expected) in cases {
            for kind: FieldKind? in [nil, .text, .choice, .multiline] {
                XCTAssertEqual(route(code, text: text, flags: flags, state: .picker, kind: kind), expected)
            }
        }
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            for kind: FieldKind? in [nil, .text, .choice, .multiline] {
                XCTAssertEqual(route(code, state: .picker, kind: kind), .use(.paste(.standard)))
                XCTAssertEqual(route(code, flags: .command, state: .picker, kind: kind), .edit)
                XCTAssertEqual(route(code, flags: .option, state: .picker, kind: kind), .use(.copyOnly))
            }
        }
    }

    func testFillTableAndNativeMultilineReturn() {
        XCTAssertEqual(route(kVK_Tab, state: .fill), .focusNext)
        XCTAssertEqual(route(kVK_Tab, flags: .shift, state: .fill), .focusPrevious)
        XCTAssertEqual(route(kVK_Escape, state: .fill), .escape)
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            for kind: FieldKind in [.text, .choice] {
                XCTAssertEqual(route(code, state: .fill, kind: kind), .deliverPreferred)
            }
            XCTAssertNil(route(code, state: .fill, kind: .multiline))
            XCTAssertNil(route(code, state: .fill))
            for kind: FieldKind? in [nil, .text, .choice, .multiline] {
                XCTAssertEqual(route(code, flags: .command, state: .fill, kind: kind), .deliver(.paste(.standard)))
                XCTAssertEqual(route(code, flags: .option, state: .fill, kind: kind), .deliver(.copyOnly))
            }
        }
        XCTAssertNil(route(kVK_ANSI_L, text: "l", flags: .command, state: .fill))
        for code in [kVK_DownArrow, kVK_UpArrow] {
            for kind: FieldKind? in [nil, .text, .choice, .multiline] {
                XCTAssertNil(route(code, state: .fill, kind: kind))
            }
        }
    }

    func testInactiveStatesNeverRoute() {
        for state: PickerModel.State in [.closed, .delivering, .done(.copiedOnly(.requested))] {
            for code in [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
                         kVK_DownArrow, kVK_UpArrow, kVK_ANSI_L] {
                for flags: NSEvent.ModifierFlags in [[], .command, .option, .shift, [.command, .shift]] {
                    XCTAssertNil(route(code, text: "l", flags: flags, state: state, kind: .text))
                }
            }
        }
    }

    func testIncidentalFlagsAndUnboundChords() {
        for flags: NSEvent.ModifierFlags in [.capsLock, .function, [.numericPad, .function], [.capsLock, .numericPad, .function]] {
            XCTAssertEqual(route(kVK_Return, flags: flags, state: .picker), .use(.paste(.standard)))
            XCTAssertEqual(route(kVK_Return, flags: flags, state: .fill, kind: .text), .deliverPreferred)
            XCTAssertEqual(route(kVK_Return, flags: flags.union(.command), state: .fill, kind: .multiline), .deliver(.paste(.standard)))
        }
        for state: PickerModel.State in [.picker, .fill] {
            for flags: NSEvent.ModifierFlags in [.shift, .control, [.command, .shift], [.option, .command], [.control, .shift]] {
                for code in [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_DownArrow, kVK_UpArrow] {
                    if state == .fill, code == kVK_Tab, flags == .shift { continue }
                    XCTAssertNil(route(code, flags: flags, state: state, kind: .text))
                }
            }
        }
        XCTAssertNil(route(kVK_ANSI_A, text: "a", state: .picker))
        XCTAssertNil(route(kVK_Tab, state: .picker))
    }

    private func route(_ code: Int, text: String? = nil, flags: NSEvent.ModifierFlags = [],
                       state: PickerModel.State, kind: FieldKind? = nil) -> MacPickerKeys.Intent? {
        MacPickerKeys.intent(keyCode: UInt16(code), characters: text, modifiers: flags, state: state, fieldKind: kind)
    }
}
