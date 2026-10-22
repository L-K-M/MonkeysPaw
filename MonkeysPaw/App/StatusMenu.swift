import AppKit
import Carbon.HIToolbox
import MonkeysPawCore

/// Carbon owns activation on key release; these equivalents are display only.
final class StatusShortcutMenuItem: NSMenuItem {}

final class StatusMenu: NSMenu, NSMenuDelegate {
    var onUpdate: ((NSMenu) -> Void)?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) { onUpdate?(menu) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let displays = items.compactMap { $0 as? StatusShortcutMenuItem }
        let equivalents = displays.map(\.keyEquivalent)
        // Leave ordinary commands such as Settings available even if the user
        // assigned the same chord to a global action.
        for item in displays { item.keyEquivalent = "" }
        defer {
            for (item, equivalent) in zip(displays, equivalents) { item.keyEquivalent = equivalent }
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum StatusMenuShortcut {
    static func apply(_ state: ShortcutsSettingsModel.ActionState?, to item: NSMenuItem) {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        guard state?.registration?.mechanism == .carbon,
              case .accelerator(let accelerator)? = state?.binding,
              let combination = try? CarbonHotkeyBackend.translate(accelerator),
              let key = keyEquivalent(accelerator.key) else { return }

        item.keyEquivalent = key
        var flags: NSEvent.ModifierFlags = []
        if combination.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if combination.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if combination.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if combination.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        item.keyEquivalentModifierMask = flags
    }

    private static func keyEquivalent(_ key: Accelerator.Key) -> String? {
        switch key {
        case .character(let character): return String(character)
        case .function(let number): return functionKey(NSF1FunctionKey + number - 1)
        case .named(let name):
            switch name {
            case .space: return " "
            case .enter: return "\r"
            case .tab: return "\t"
            case .escape: return "\u{1b}"
            case .backspace: return "\u{8}"
            case .delete: return functionKey(NSDeleteFunctionKey)
            case .home: return functionKey(NSHomeFunctionKey)
            case .end: return functionKey(NSEndFunctionKey)
            case .pageUp: return functionKey(NSPageUpFunctionKey)
            case .pageDown: return functionKey(NSPageDownFunctionKey)
            case .up: return functionKey(NSUpArrowFunctionKey)
            case .down: return functionKey(NSDownArrowFunctionKey)
            case .left: return functionKey(NSLeftArrowFunctionKey)
            case .right: return functionKey(NSRightArrowFunctionKey)
            case .comma: return ","
            case .period: return "."
            case .slash: return "/"
            case .backslash: return "\\"
            case .minus: return "-"
            case .equal, .plus: return "="
            case .semicolon: return ";"
            case .quote: return "'"
            case .grave: return "`"
            case .bracketLeft: return "["
            case .bracketRight: return "]"
            case .insert, .printScreen: return nil
            }
        }
    }

    private static func functionKey(_ code: Int) -> String? {
        guard let scalar = UnicodeScalar(code) else { return nil }
        return String(scalar)
    }
}
