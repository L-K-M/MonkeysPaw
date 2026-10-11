#if os(Linux)
import CGtk
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPickerKeysTests: XCTestCase {
    private let control = GDK_CONTROL_MASK.rawValue
    private let shift = GDK_SHIFT_MASK.rawValue
    private let alt = GDK_ALT_MASK.rawValue

    func testPickerBindings() {
        let cases: [(Int32, UInt32, LinuxPickerKeys.Intent)] = [
            (GDK_KEY_Up, 0, .moveUp), (GDK_KEY_Down, 0, .moveDown),
            (GDK_KEY_Escape, 0, .escape), (GDK_KEY_l, control, .openLibrary),
            (GDK_KEY_L, control, .openLibrary),
        ]
        for (key, modifiers, expected) in cases {
            XCTAssertEqual(route(key, modifiers: modifiers, state: .picker), expected)
        }
        for key in [GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_ISO_Enter] {
            XCTAssertEqual(route(key, state: .picker), .use(.paste(.standard)))
            XCTAssertEqual(route(key, modifiers: control, state: .picker), .edit)
            XCTAssertEqual(route(key, modifiers: control | shift, state: .picker), .use(.paste(.terminal)))
            XCTAssertEqual(route(key, modifiers: alt, state: .picker), .use(.copyOnly))
        }
    }

    func testFillBindingsAndMultilineReturn() {
        XCTAssertEqual(route(GDK_KEY_Tab, state: .fill), .focusNext)
        XCTAssertEqual(route(GDK_KEY_Tab, modifiers: shift, state: .fill), .focusPrevious)
        XCTAssertEqual(route(GDK_KEY_ISO_Left_Tab, modifiers: shift, state: .fill), .focusPrevious)
        XCTAssertEqual(route(GDK_KEY_Escape, state: .fill), .escape)
        for key in [GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_ISO_Enter] {
            for kind in [FieldKind.text, .choice] {
                XCTAssertEqual(route(key, state: .fill, kind: kind), .deliverPreferred)
            }
            XCTAssertNil(route(key, state: .fill, kind: .multiline))
            XCTAssertNil(route(key, state: .fill))
            for kind: FieldKind? in [nil, .text, .multiline, .choice] {
                XCTAssertEqual(route(key, modifiers: control, state: .fill, kind: kind), .deliver(.paste(.standard)))
                XCTAssertEqual(route(key, modifiers: control | shift, state: .fill, kind: kind), .deliver(.paste(.terminal)))
                XCTAssertEqual(route(key, modifiers: alt, state: .fill, kind: kind), .deliver(.copyOnly))
            }
        }
        XCTAssertNil(route(GDK_KEY_l, modifiers: control, state: .fill))
        XCTAssertNil(route(GDK_KEY_Up, state: .fill, kind: .multiline))
        XCTAssertNil(route(GDK_KEY_Down, state: .fill, kind: .choice))
        for key in [GDK_KEY_Up, GDK_KEY_Down] {
            XCTAssertNil(route(key, state: .fill, kind: .text))
            XCTAssertNil(route(key, state: .fill))
        }
    }

    func testInactiveStatesNeverRouteKeys() {
        let keys = [GDK_KEY_Up, GDK_KEY_Down, GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_ISO_Enter,
                    GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab, GDK_KEY_Escape, GDK_KEY_l]
        for state: PickerModel.State in [.delivering, .closed, .done(.copiedOnly(.requested))] {
            for key in keys {
                for modifiers in [UInt32(0), control, shift, control | shift, alt] {
                    XCTAssertNil(route(key, modifiers: modifiers, state: state, kind: .text))
                }
            }
        }
    }

    func testTypingAndUnboundModifiersStayNativeAndLockDoesNotChangeBindings() {
        XCTAssertNil(route(GDK_KEY_a, state: .picker))
        XCTAssertNil(route(GDK_KEY_Tab, state: .picker))
        for state: PickerModel.State in [.picker, .fill] {
            for modifiers in [shift, control | alt, GDK_SUPER_MASK.rawValue] {
                XCTAssertNil(route(GDK_KEY_Return, modifiers: modifiers, state: state, kind: .text))
            }
        }
        XCTAssertEqual(route(GDK_KEY_Return, modifiers: GDK_LOCK_MASK.rawValue, state: .picker), .use(.paste(.standard)))
    }

    private func route(_ key: Int32, modifiers: UInt32 = 0, state: PickerModel.State,
                       kind: FieldKind? = nil) -> LinuxPickerKeys.Intent? {
        LinuxPickerKeys.intent(for: UInt32(key), modifiers: modifiers, state: state, fieldKind: kind)
    }
}
#endif
