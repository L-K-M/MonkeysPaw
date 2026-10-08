import Foundation

public enum AcceleratorError: Error, Equatable {
    case empty
    case malformed
    case unsupportedModifier(String)
    case duplicateModifier(Accelerator.Modifier)
    case unsupportedKey(String)
    case conflictingGTKModifiers
}

/// A validated shortcut, keeping modifiers distinct for native drivers (§6.2).
public struct Accelerator: Equatable, Hashable, Sendable {
    public enum Modifier: String, Hashable, Sendable {
        case control, alt, shift, superKey, command, commandOrControl
    }

    public enum Key: Equatable, Hashable, Sendable {
        case character(Character)
        case function(Int)
        case named(NamedKey)
    }

    public enum NamedKey: String, Sendable {
        case space = "space", enter = "Return", tab = "Tab", escape = "Escape"
        case backspace = "BackSpace", delete = "Delete", insert = "Insert"
        case home = "Home", end = "End", pageUp = "Page_Up", pageDown = "Page_Down"
        case up = "Up", down = "Down", left = "Left", right = "Right"
        case comma = "comma", period = "period", slash = "slash", backslash = "backslash"
        case minus = "minus", equal = "equal", plus = "plus", semicolon = "semicolon"
        case quote = "apostrophe", grave = "grave"
        case bracketLeft = "bracketleft", bracketRight = "bracketright", printScreen = "Print"
    }

    public let modifiers: Set<Modifier>
    public let key: Key

    public init(_ text: String) throws {
        var spelling = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty else { throw AcceleratorError.empty }

        // Accept the macOS default spelling as well as Ctrl+Alt+P.
        var prefixes: [String] = []
        let symbols: [Character: String] = ["⌃": "Ctrl", "⌥": "Alt", "⇧": "Shift", "⌘": "Cmd"]
        while let first = spelling.first, let modifier = symbols[first] {
            prefixes.append(modifier)
            spelling.removeFirst()
        }
        spelling = (prefixes + [spelling]).joined(separator: "+")

        let parts = spelling.components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.allSatisfy({ !$0.isEmpty }), let last = parts.last else {
            throw AcceleratorError.malformed
        }

        var parsed: Set<Modifier> = []
        for part in parts.dropLast() {
            let modifier = try Self.modifier(part)
            guard parsed.insert(modifier).inserted else {
                throw AcceleratorError.duplicateModifier(modifier)
            }
        }
        modifiers = parsed
        key = try Self.key(last)
    }

    private init(modifiers: Set<Modifier>, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// §6.2: one default shortcut on both platforms; repeat remains unbound.
    public static func defaultBinding(for action: HotkeyAction) -> Accelerator? {
        guard action == .togglePicker else { return nil }
        return Accelerator(modifiers: [.control, .alt], key: .character("p"))
    }

    /// Copywraith linux/shortcuts.rs:638-735 is the accepted-key precedent.
    /// Reject aliases that would collapse two distinct modifiers on Linux.
    public func gtkAccelerator() throws -> String {
        guard !(modifiers.contains(.control) && modifiers.contains(.commandOrControl)),
              !(modifiers.contains(.superKey) && modifiers.contains(.command)) else {
            throw AcceleratorError.conflictingGTKModifiers
        }

        var result = ""
        if modifiers.contains(.control) || modifiers.contains(.commandOrControl) {
            result += "<Control>"
        }
        if modifiers.contains(.alt) { result += "<Alt>" }
        if modifiers.contains(.shift) { result += "<Shift>" }
        if modifiers.contains(.superKey) || modifiers.contains(.command) { result += "<Super>" }
        return result + keyName
    }

    private var keyName: String {
        switch key {
        case .character(let character): return String(character)
        case .function(let number): return "F\(number)"
        case .named(let name): return name.rawValue
        }
    }

    private static func modifier(_ spelling: String) throws -> Modifier {
        switch spelling.lowercased() {
        case "ctrl", "control": return .control
        case "alt", "option": return .alt
        case "shift": return .shift
        case "super", "meta", "win": return .superKey
        case "cmd", "command": return .command
        case "cmdorctrl", "commandorcontrol": return .commandOrControl
        default: throw AcceleratorError.unsupportedModifier(spelling)
        }
    }

    private static func key(_ spelling: String) throws -> Key {
        var lower = spelling.lowercased()
        for prefix in ["key", "digit"] where lower.hasPrefix(prefix) {
            let suffix = String(lower.dropFirst(prefix.count))
            if suffix.count == 1 { lower = suffix }
        }

        if lower.count == 1, let character = lower.first,
           character.isASCII, character.isLetter || character.isNumber {
            return .character(character)
        }
        if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...24).contains(number) {
            return .function(number)
        }

        let names: [String: NamedKey] = [
            "space": .space, "enter": .enter, "return": .enter, "tab": .tab,
            "escape": .escape, "esc": .escape, "backspace": .backspace,
            "delete": .delete, "del": .delete, "insert": .insert, "home": .home, "end": .end,
            "pageup": .pageUp, "pagedown": .pageDown, "up": .up, "arrowup": .up,
            "down": .down, "arrowdown": .down, "left": .left, "arrowleft": .left,
            "right": .right, "arrowright": .right, "comma": .comma, "period": .period,
            "dot": .period, "slash": .slash, "backslash": .backslash, "minus": .minus,
            "equal": .equal, "plus": .plus, "semicolon": .semicolon, "quote": .quote,
            "backquote": .grave, "grave": .grave, "bracketleft": .bracketLeft,
            "bracketright": .bracketRight, "printscreen": .printScreen,
        ]
        guard let name = names[lower] else { throw AcceleratorError.unsupportedKey(spelling) }
        return .named(name)
    }
}
