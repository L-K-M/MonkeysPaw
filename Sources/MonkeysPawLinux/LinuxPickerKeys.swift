#if os(Linux)
import CGtk
import MonkeysPawCore

/// Pure routing; widget callbacks forward the resulting presentation intent.
enum LinuxPickerKeys {
    enum Intent: Equatable {
        case moveUp, moveDown, edit, openLibrary, openSettings, escape
        case use(DeliveryMode)
        case focusNext, focusPrevious, deliverPreferred
        case deliver(DeliveryMode)
    }

    static func intent(for key: UInt32, modifiers: UInt32, state: PickerModel.State,
                       fieldKind: FieldKind? = nil) -> Intent? {
        guard state == .picker || state == .fill else { return nil }
        let control = GDK_CONTROL_MASK.rawValue
        let shift = GDK_SHIFT_MASK.rawValue
        let alt = GDK_ALT_MASK.rawValue
        let relevant = control | shift | alt | GDK_SUPER_MASK.rawValue
            | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
        let modifiers = modifiers & relevant // Caps/Num Lock do not change bindings.

        if key == UInt32(GDK_KEY_Escape), modifiers == 0 { return .escape }
        if state == .picker {
            if key == UInt32(GDK_KEY_Up), modifiers == 0 { return .moveUp }
            if key == UInt32(GDK_KEY_Down), modifiers == 0 { return .moveDown }
            if [UInt32(GDK_KEY_l), UInt32(GDK_KEY_L)].contains(key), modifiers == control {
                return .openLibrary
            }
            if key == UInt32(GDK_KEY_comma), modifiers == control { return .openSettings }
        } else {
            if key == UInt32(GDK_KEY_Tab), modifiers == 0 { return .focusNext }
            if [UInt32(GDK_KEY_Tab), UInt32(GDK_KEY_ISO_Left_Tab)].contains(key), modifiers == shift {
                return .focusPrevious
            }
        }

        guard [UInt32(GDK_KEY_Return), UInt32(GDK_KEY_KP_Enter), UInt32(GDK_KEY_ISO_Enter)].contains(key) else {
            return nil
        }
        if state == .picker {
            switch modifiers {
            case 0: return .use(.paste(.standard))
            case control: return .edit
            case control | shift: return .use(.paste(.terminal))
            case alt: return .use(.copyOnly)
            default: return nil
            }
        }
        switch modifiers {
        case 0:
            switch fieldKind {
            case .text, .choice: return .deliverPreferred
            case .multiline: return nil
            case nil: return nil
            }
        case control: return .deliver(.paste(.standard))
        case control | shift: return .deliver(.paste(.terminal))
        case alt: return .deliver(.copyOnly)
        default: return nil
        }
    }
}
#endif
