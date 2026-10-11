import AppKit
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

        if keyCode == 53, flags.isEmpty { return .escape }
        if state == .picker {
            if keyCode == 126, flags.isEmpty { return .moveUp }
            if keyCode == 125, flags.isEmpty { return .moveDown }
            if characters?.lowercased() == "l", flags == .command { return .openLibrary }
        } else if keyCode == 48 {
            if flags.isEmpty { return .focusNext }
            if flags == .shift { return .focusPrevious }
        }

        guard keyCode == 36 || keyCode == 76 else { return nil } // Return / keypad Enter.
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
