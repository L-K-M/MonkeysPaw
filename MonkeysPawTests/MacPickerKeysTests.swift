import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacPickerKeysTests: XCTestCase {
    func testPickerTable() {
        let cases: [(UInt16, String?, NSEvent.ModifierFlags, MacPickerKeys.Intent)] = [
            (126, nil, [], .moveUp), (125, nil, [], .moveDown),
            (53, nil, [], .escape), (37, "l", .command, .openLibrary),
            (37, "L", .command, .openLibrary),
        ]
        for (code, text, flags, expected) in cases {
            XCTAssertEqual(route(code, text: text, flags: flags, state: .picker), expected)
        }
        for code: UInt16 in [36, 76] {
            XCTAssertEqual(route(code, state: .picker), .use(.paste(.standard)))
            XCTAssertEqual(route(code, flags: .command, state: .picker), .edit)
            XCTAssertEqual(route(code, flags: .option, state: .picker), .use(.copyOnly))
        }
    }

    func testFillTableAndNativeMultilineReturn() {
        XCTAssertEqual(route(48, state: .fill), .focusNext)
        XCTAssertEqual(route(48, flags: .shift, state: .fill), .focusPrevious)
        XCTAssertEqual(route(53, state: .fill), .escape)
        for code: UInt16 in [36, 76] {
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
        XCTAssertNil(route(37, text: "l", flags: .command, state: .fill))
        for code: UInt16 in [125, 126] {
            for kind: FieldKind? in [nil, .text, .choice, .multiline] {
                XCTAssertNil(route(code, state: .fill, kind: kind))
            }
        }
    }

    func testInactiveStatesNeverRoute() {
        for state: PickerModel.State in [.closed, .delivering, .done(.copiedOnly(.requested))] {
            for code: UInt16 in [36, 76, 48, 53, 125, 126, 37] {
                for flags: NSEvent.ModifierFlags in [[], .command, .option, .shift, [.command, .shift]] {
                    XCTAssertNil(route(code, text: "l", flags: flags, state: state, kind: .text))
                }
            }
        }
    }

    func testIncidentalFlagsAndUnboundChords() {
        for flags: NSEvent.ModifierFlags in [.capsLock, [.numericPad, .function], [.capsLock, .numericPad, .function]] {
            XCTAssertEqual(route(36, flags: flags, state: .picker), .use(.paste(.standard)))
            XCTAssertEqual(route(36, flags: flags.union(.command), state: .fill, kind: .multiline), .deliver(.paste(.standard)))
        }
        for state: PickerModel.State in [.picker, .fill] {
            for flags: NSEvent.ModifierFlags in [.shift, .control, [.command, .shift], [.option, .command], [.control, .shift]] {
                XCTAssertNil(route(36, flags: flags, state: state, kind: .text))
            }
        }
        XCTAssertNil(route(0, text: "a", state: .picker))
        XCTAssertNil(route(48, state: .picker))
    }

    private func route(_ code: UInt16, text: String? = nil, flags: NSEvent.ModifierFlags = [],
                       state: PickerModel.State, kind: FieldKind? = nil) -> MacPickerKeys.Intent? {
        MacPickerKeys.intent(keyCode: code, characters: text, modifiers: flags, state: state, fieldKind: kind)
    }
}
