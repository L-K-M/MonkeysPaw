import Carbon.HIToolbox
import Foundation
import MonkeysPawCore

/// Carbon's Event Manager needs no Accessibility or Input Monitoring permission.
final class CarbonHotkeyBackend: HotkeyBackend {
    let mechanism = HotkeyMechanism.carbon

    struct Combination: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    enum TranslationError: Error {
        case unsupportedKey
        case overlappingCommandModifiers

        var detail: String {
            switch self {
            case .unsupportedKey: return Strings.carbonUnsupportedKey
            case .overlappingCommandModifiers: return Strings.carbonOverlappingModifiers
            }
        }
    }

    private struct Entry {
        let identifier: UInt32
        let reference: EventHotKeyRef
        let onFire: () -> Void
    }

    /// Four-character signature 'MNKP', separate from the precedent apps.
    private static let signature: OSType = 0x4D4E_4B50
    private var handler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 0
    private var entries: [UUID: Entry] = [:]
    private var liveRegistrations: [HotkeyAction: HotkeyRegistration] = [:]

    deinit {
        for entry in entries.values { UnregisterEventHotKey(entry.reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        liveRegistrations[action] ?? HotkeyRegistration(
            mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
    }

    func register(_ action: HotkeyAction, accelerator: Accelerator,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        if let previous = liveRegistrations[action] { unregister(previous) }

        let combination: Combination
        do {
            combination = try Self.translate(accelerator)
        } catch {
            let detail = (error as? TranslationError)?.detail ?? Strings.carbonTranslationFailure
            return record(action, status: .failed, detail: detail)
        }

        guard installHandler() else {
            return record(action, status: .failed, detail: Strings.carbonHandlerFailure)
        }

        nextIdentifier &+= 1
        let identifier = nextIdentifier
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(combination.keyCode, combination.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: identifier),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            removeUnusedHandler()
            return record(action, status: .failed,
                          detail: Strings.carbonRegistrationFailure(status: status))
        }

        let registration = record(action, status: .registered, detail: Strings.carbonRegistered)
        entries[registration.id] = Entry(identifier: identifier, reference: reference, onFire: onFire)
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) {
        if let entry = entries.removeValue(forKey: registration.id) {
            UnregisterEventHotKey(entry.reference)
        }
        if let action = liveRegistrations.first(where: { $0.value.id == registration.id })?.key {
            liveRegistrations[action] = HotkeyRegistration(
                mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
        }
        removeUnusedHandler()
    }

    private func record(_ action: HotkeyAction, status: RegistrationStatus,
                        detail: String) -> HotkeyRegistration {
        let registration = HotkeyRegistration(mechanism: mechanism, status: status, detail: detail)
        liveRegistrations[action] = registration
        return registration
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyReleased))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CarbonHotkeyBackend>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == CarbonHotkeyBackend.signature,
                  owner.entries.values.contains(where: { $0.identifier == identifier.id }) else {
                // Claiming a foreign event would swallow another app handler's hotkey.
                return OSStatus(eventNotHandledErr)
            }

            let id = identifier.id
            DispatchQueue.main.async { [weak owner] in
                // Teardown may happen before this hop. Do not fire an old registration.
                owner?.entries.values.first(where: { $0.identifier == id })?.onFire()
            }
            return noErr
        }
        return InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type,
                                    Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }

    private func removeUnusedHandler() {
        guard entries.isEmpty, let handler else { return }
        RemoveEventHandler(handler)
        self.handler = nil
    }

    /// Key names denote ANSI physical positions, matching the precedent's kVK table.
    static func translate(_ accelerator: Accelerator) throws -> Combination {
        let commandAliases: Set<Accelerator.Modifier> = [.command, .superKey, .commandOrControl]
        guard accelerator.modifiers.intersection(commandAliases).count <= 1 else {
            throw TranslationError.overlappingCommandModifiers
        }
        var modifiers: UInt32 = 0
        for modifier in accelerator.modifiers {
            switch modifier {
            case .control: modifiers |= UInt32(controlKey)
            case .alt: modifiers |= UInt32(optionKey)
            case .shift: modifiers |= UInt32(shiftKey)
            case .command, .superKey, .commandOrControl: modifiers |= UInt32(cmdKey)
            }
        }

        let code: Int?
        switch accelerator.key {
        case .character(let character): code = characterCodes[character]
        case .function(let number): code = functionCodes[number]
        case .named(let key):
            code = namedCodes[key]
            if key == .plus { modifiers |= UInt32(shiftKey) }
        }
        guard let code else { throw TranslationError.unsupportedKey }
        return Combination(keyCode: UInt32(code), modifiers: modifiers)
    }

    private static let characterCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    private static let functionCodes: [Int: Int] = [
        1: kVK_F1, 2: kVK_F2, 3: kVK_F3, 4: kVK_F4, 5: kVK_F5,
        6: kVK_F6, 7: kVK_F7, 8: kVK_F8, 9: kVK_F9, 10: kVK_F10,
        11: kVK_F11, 12: kVK_F12, 13: kVK_F13, 14: kVK_F14, 15: kVK_F15,
        16: kVK_F16, 17: kVK_F17, 18: kVK_F18, 19: kVK_F19, 20: kVK_F20,
    ]

    private static let namedCodes: [Accelerator.NamedKey: Int] = [
        .space: kVK_Space, .enter: kVK_Return, .tab: kVK_Tab, .escape: kVK_Escape,
        .backspace: kVK_Delete, .delete: kVK_ForwardDelete,
        .home: kVK_Home, .end: kVK_End, .pageUp: kVK_PageUp, .pageDown: kVK_PageDown,
        .up: kVK_UpArrow, .down: kVK_DownArrow, .left: kVK_LeftArrow, .right: kVK_RightArrow,
        .comma: kVK_ANSI_Comma, .period: kVK_ANSI_Period, .slash: kVK_ANSI_Slash,
        .backslash: kVK_ANSI_Backslash, .minus: kVK_ANSI_Minus, .equal: kVK_ANSI_Equal,
        .plus: kVK_ANSI_Equal, .semicolon: kVK_ANSI_Semicolon, .quote: kVK_ANSI_Quote,
        .grave: kVK_ANSI_Grave, .bracketLeft: kVK_ANSI_LeftBracket,
        .bracketRight: kVK_ANSI_RightBracket,
        // Insert, PrintScreen and F21–F24 have no matching macOS virtual key.
    ]
}
