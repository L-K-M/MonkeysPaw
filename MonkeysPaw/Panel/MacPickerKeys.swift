import AppKit
import Carbon.HIToolbox
import MonkeysPawCore

/// Pure routing; incidental device flags do not change a binding.
enum MacPickerKeys {
    enum Intent: Equatable {
        case moveUp, moveDown, edit, openLibrary, escape
        case use(DeliveryMode)
        case focusNext, focusPrevious, deliverPreferred
        case deliver(DeliveryMode)
    }

    static func intent(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                       state: PickerModel.State, fieldKind: FieldKind? = nil) -> Intent? {
        guard state == .picker || state == .fill else { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if keyCode == UInt16(kVK_Escape), flags.isEmpty { return .escape }
        if state == .picker {
            if keyCode == UInt16(kVK_UpArrow), flags.isEmpty { return .moveUp }
            if keyCode == UInt16(kVK_DownArrow), flags.isEmpty { return .moveDown }
            if flags == .command, keyCode == UInt16(kVK_ANSI_L) || characters?.lowercased() == "l" {
                return .openLibrary
            }
        } else if keyCode == UInt16(kVK_Tab) {
            if flags.isEmpty { return .focusNext }
            if flags == .shift { return .focusPrevious }
        }

        guard keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return nil }
        if state == .picker {
            switch flags {
            case []: return .use(.paste(.standard))
            case .command: return .edit
            case .option: return .use(.copyOnly)
            default: return nil
            }
        }
        switch flags {
        case []:
            switch fieldKind {
            case .text, .choice: return .deliverPreferred
            case .multiline, nil: return nil
            }
        case .command: return .deliver(.paste(.standard))
        case .option: return .deliver(.copyOnly)
        default: return nil
        }
    }
}
