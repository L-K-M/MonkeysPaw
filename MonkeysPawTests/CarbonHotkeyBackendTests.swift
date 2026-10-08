import Carbon.HIToolbox
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class CarbonHotkeyBackendTests: XCTestCase {
    func testDefaultAndModifierTranslation() throws {
        let cases: [(String, Int, Int)] = [
            ("⌃⌥P", kVK_ANSI_P, controlKey | optionKey),
            ("Ctrl+Alt+Shift+Cmd+A", kVK_ANSI_A, controlKey | optionKey | shiftKey | cmdKey),
            ("Super+P", kVK_ANSI_P, cmdKey),
            ("CmdOrCtrl+V", kVK_ANSI_V, cmdKey),
            ("Ctrl+CmdOrCtrl+V", kVK_ANSI_V, controlKey | cmdKey),
            ("Tab", kVK_Tab, 0),
            ("Cmd+Plus", kVK_ANSI_Equal, cmdKey | shiftKey),
        ]
        for (text, code, modifiers) in cases {
            let combination = try CarbonHotkeyBackend.translate(Accelerator(text))
            XCTAssertEqual(combination.keyCode, UInt32(code), text)
            XCTAssertEqual(combination.modifiers, UInt32(modifiers), text)
        }
        let binding = try XCTUnwrap(Accelerator.defaultBinding(for: .togglePicker))
        XCTAssertEqual(try CarbonHotkeyBackend.translate(binding),
                       CarbonHotkeyBackend.Combination(keyCode: UInt32(kVK_ANSI_P),
                                                       modifiers: UInt32(controlKey | optionKey)))
        XCTAssertNil(Accelerator.defaultBinding(for: .repeatLast))
    }

    func testAllSupportedPhysicalKeys() throws {
        let characters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
            ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        let named: [(String, Int)] = [
            ("Space", kVK_Space), ("Return", kVK_Return), ("Tab", kVK_Tab), ("Escape", kVK_Escape),
            ("BackSpace", kVK_Delete), ("Delete", kVK_ForwardDelete),
            ("Home", kVK_Home), ("End", kVK_End), ("PageUp", kVK_PageUp), ("PageDown", kVK_PageDown),
            ("Up", kVK_UpArrow), ("Down", kVK_DownArrow), ("Left", kVK_LeftArrow), ("Right", kVK_RightArrow),
            ("Comma", kVK_ANSI_Comma), ("Period", kVK_ANSI_Period), ("Slash", kVK_ANSI_Slash),
            ("Backslash", kVK_ANSI_Backslash), ("Minus", kVK_ANSI_Minus), ("Equal", kVK_ANSI_Equal),
            ("Semicolon", kVK_ANSI_Semicolon), ("Quote", kVK_ANSI_Quote), ("Grave", kVK_ANSI_Grave),
            ("BracketLeft", kVK_ANSI_LeftBracket), ("BracketRight", kVK_ANSI_RightBracket),
        ]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                         kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                         kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let keys = characters + named + functions.enumerated().map { ("F\($0.offset + 1)", $0.element) }
        for (name, code) in keys {
            let combination = try CarbonHotkeyBackend.translate(Accelerator("Alt+\(name)"))
            XCTAssertEqual(combination.keyCode, UInt32(code), name)
            XCTAssertEqual(combination.modifiers, UInt32(optionKey), name)
        }
    }

    func testRefusalsReportFailedLiveStateWithoutNativeRegistration() throws {
        let backend = CarbonHotkeyBackend()
        for key in ["Insert", "PrintScreen", "F21", "F22", "F23", "F24", "Cmd+Super+P", "Cmd+CmdOrCtrl+P"] {
            let accelerator = try Accelerator(key)
            XCTAssertThrowsError(try CarbonHotkeyBackend.translate(accelerator), key)
            let registration = backend.register(.togglePicker, accelerator: accelerator) {
                XCTFail("A refused shortcut must never fire")
            }
            XCTAssertEqual(registration.mechanism, .carbon)
            XCTAssertEqual(registration.status, .failed, key)
            XCTAssertFalse(registration.detail.isEmpty)
            XCTAssertEqual(backend.registration(for: .togglePicker), registration)
            backend.unregister(registration)
            XCTAssertEqual(backend.registration(for: .togglePicker).status, .unbound)
        }
    }
}
