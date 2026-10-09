#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// KDE v2 alternatives, each containing a complete Qt QKeySequence. Keep even
/// empty sequences and trailing zeros so a saved assignment is never flattened.
struct KGlobalAccelKeys: Equatable {
    let sequences: [[Int32]]
    var bound: [[Int32]] { sequences.filter { $0.contains { $0 != 0 } } }
    var detail: String {
        bound.map { $0.filter { $0 != 0 }.map(KGlobalAccelWire.describe).joined(separator: ", ") }
            .joined(separator: " / ")
    }
}

/// Fixed consumed shapes from KDE's v2 XML, linked in §15. No Qt dependency.
enum KGlobalAccelWire {
    static let busName = "org.kde.kglobalaccel"
    static let root = "/kglobalaccel"
    static let interface = "org.kde.KGlobalAccel"
    static let componentInterface = "org.kde.kglobalaccel.Component"
    static let actionID = [AppIdentity.linuxAppID, ActionName.toggle.rawValue, "Monkey's Paw", "Open picker"]

    // kglobalaccel_p.h SetShortcutFlag. Autoloading is zero; never add 4 here.
    enum Setter: UInt32 { case present = 2, defaultSuggestion = 8 }

    // kglobalaccel.h enum order; its D-Bus operator wraps the int in a struct.
    enum MatchType: Int32, CaseIterable { case equal = 0, shadows = 1, shadowed = 2 }

    // Qt 6.8 qnamespace.h KeyboardModifier and Key. These are Qt combined
    // keys, not X keysyms or GTK accelerator masks.
    private static let shift: Int32 = 0x02000000
    private static let control: Int32 = 0x04000000
    private static let alt: Int32 = 0x08000000
    private static let meta: Int32 = 0x10000000
    private static let keypad: Int32 = 0x20000000
    private static let groupSwitch: Int32 = 0x40000000
    private static let modifierMask: Int32 = 0x7e000000
    private static let functionFirst: Int32 = 0x01000030
    private static let named: [Accelerator.NamedKey: Int32] = [
        .space: 0x20, .enter: 0x01000004, .tab: 0x01000001, .escape: 0x01000000,
        .backspace: 0x01000003, .delete: 0x01000007, .insert: 0x01000006,
        .home: 0x01000010, .end: 0x01000011, .left: 0x01000012, .up: 0x01000013,
        .right: 0x01000014, .down: 0x01000015, .pageUp: 0x01000016, .pageDown: 0x01000017,
        .comma: 0x2c, .period: 0x2e, .slash: 0x2f, .backslash: 0x5c, .minus: 0x2d,
        .equal: 0x3d, .plus: 0x2b, .semicolon: 0x3b, .quote: 0x27, .grave: 0x60,
        .bracketLeft: 0x5b, .bracketRight: 0x5d, .printScreen: 0x01000009,
    ]

    static func translate(_ accelerator: Accelerator) -> KGlobalAccelKeys {
        let key: Int32
        switch accelerator.key {
        case .character(let value): key = Int32(String(value).uppercased().unicodeScalars.first!.value)
        case .function(let value): key = functionFirst + Int32(value - 1)
        case .named(let value): key = named[value]!
        }
        var modifiers: Int32 = 0
        for modifier in accelerator.modifiers {
            switch modifier {
            case .control, .commandOrControl: modifiers |= control
            case .alt: modifiers |= alt
            case .shift: modifiers |= shift
            case .superKey, .command: modifiers |= meta
            }
        }
        return KGlobalAccelKeys(sequences: [[modifiers | key]])
    }

    static func describe(_ combined: Int32) -> String {
        var parts: [String] = []
        for (mask, name) in [(control, "Ctrl"), (alt, "Alt"), (shift, "Shift"),
                             (meta, "Super"), (keypad, "Keypad"), (groupSwitch, "GroupSwitch")] {
            if combined & mask != 0 { parts.append(name) }
        }
        let key = combined & ~modifierMask
        if (functionFirst..<(functionFirst + 35)).contains(key) {
            parts.append("F\(key - functionFirst + 1)")
        } else if let name = named.first(where: { $0.value == key })?.key {
            parts.append(name.rawValue)
        } else if key >= 0x21, key <= 0x10ffff, let scalar = UnicodeScalar(UInt32(key)),
                  !CharacterSet.controlCharacters.contains(scalar) {
            parts.append(String(scalar))
        } else {
            // Preserve unfamiliar Qt keys and show their numeric identity.
            parts.append(String(format: "0x%08X", UInt32(bitPattern: key)))
        }
        return parts.joined(separator: "+")
    }

    static func hasType(_ value: OpaquePointer, _ type: String) -> Bool {
        g_variant_get_size(value) <= Limits.kglobalaccelPayloadMaxBytes
            && String(cString: g_variant_get_type_string(value)) == type
    }

    static func strings(_ value: OpaquePointer) -> [String]? {
        guard hasType(value, "as"), g_variant_n_children(value) == 4 else { return nil }
        return (0..<g_variant_n_children(value)).map { index in
            let child = g_variant_get_child_value(value, index)!
            defer { g_variant_unref(child) }
            return String(cString: g_variant_get_string(child, nil))
        }
    }

    static func keys(_ value: OpaquePointer) -> KGlobalAccelKeys? {
        guard hasType(value, "a(ai)"), g_variant_n_children(value) <= Limits.kglobalaccelSequenceCap else { return nil }
        var sequences: [[Int32]] = []
        for index in 0..<g_variant_n_children(value) {
            let sequence = g_variant_get_child_value(value, index)!
            let chords = g_variant_get_child_value(sequence, 0)!
            defer { g_variant_unref(sequence); g_variant_unref(chords) }
            guard g_variant_n_children(chords) <= Limits.kglobalaccelChordCap else { return nil }
            sequences.append((0..<g_variant_n_children(chords)).map { index in
                let chord = g_variant_get_child_value(chords, index)!
                defer { g_variant_unref(chord) }
                return g_variant_get_int32(chord)
            })
        }
        return KGlobalAccelKeys(sequences: sequences)
    }

    static func replyKeys(_ value: OpaquePointer) -> KGlobalAccelKeys? {
        guard hasType(value, "(a(ai))") else { return nil }
        let child = g_variant_get_child_value(value, 0)!
        defer { g_variant_unref(child) }
        return keys(child)
    }

    static func hasForeignHolder(_ value: OpaquePointer) -> Bool? {
        guard hasType(value, "(a(ssssssaiai))") else { return nil }
        let holders = g_variant_get_child_value(value, 0)!
        defer { g_variant_unref(holders) }
        guard g_variant_n_children(holders) <= Limits.kglobalaccelHolderCap else { return nil }
        var foreign = false
        for index in 0..<g_variant_n_children(holders) {
            let holder = g_variant_get_child_value(holders, index)!
            // kglobalshortcutinfo_dbus.cpp: action unique is field 0,
            // component unique is field 2. Friendly names are not identities.
            let action = g_variant_get_child_value(holder, 0)!
            let component = g_variant_get_child_value(holder, 2)!
            let keys = g_variant_get_child_value(holder, 6)!
            let defaults = g_variant_get_child_value(holder, 7)!
            defer {
                g_variant_unref(holder); g_variant_unref(action); g_variant_unref(component)
                g_variant_unref(keys); g_variant_unref(defaults)
            }
            // These legacy arrays count alternatives, not chords. Validate
            // their bounds but never use them to reconstruct assigned keys.
            guard g_variant_n_children(keys) <= Limits.kglobalaccelSequenceCap,
                  g_variant_n_children(defaults) <= Limits.kglobalaccelSequenceCap else { return nil }
            let actionName = String(cString: g_variant_get_string(action, nil))
            let componentName = String(cString: g_variant_get_string(component, nil))
            guard !actionName.isEmpty, !componentName.isEmpty else { return nil }
            if actionName != ActionName.toggle.rawValue || componentName != AppIdentity.linuxAppID { foreign = true }
        }
        return foreign
    }

    static func tuple(_ children: [OpaquePointer?]) -> OpaquePointer {
        children.withUnsafeBufferPointer { g_variant_new_tuple($0.baseAddress, UInt($0.count))! }
    }

    private static func array(_ type: String, _ children: [OpaquePointer?]) -> OpaquePointer {
        let nativeType = g_variant_type_new(type)!
        defer { g_variant_type_free(nativeType) }
        return children.withUnsafeBufferPointer { g_variant_new_array(nativeType, $0.baseAddress, UInt($0.count))! }
    }

    static func action() -> OpaquePointer { array("s", actionID.map { g_variant_new_string($0) }) }
    static func sequence(_ chords: [Int32]) -> OpaquePointer {
        tuple([array("i", chords.map { g_variant_new_int32($0) })])
    }
    static func encode(_ keys: KGlobalAccelKeys) -> OpaquePointer {
        array("(ai)", keys.sequences.map { sequence($0) })
    }
    static func setter(_ keys: KGlobalAccelKeys, _ mode: Setter) -> OpaquePointer {
        tuple([action(), encode(keys), g_variant_new_uint32(mode.rawValue)])
    }
    static func holderQuery(_ chords: [Int32], _ match: MatchType) -> OpaquePointer {
        tuple([sequence(chords), tuple([g_variant_new_int32(match.rawValue)])])
    }
}
#endif
