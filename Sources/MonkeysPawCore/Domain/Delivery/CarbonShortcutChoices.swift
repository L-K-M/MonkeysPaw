import Foundation

/// App-owned choices only. System-owned bindings are always read from drivers.
public struct CarbonShortcutChoices: Equatable, Sendable, Decodable {
    public let togglePicker: Accelerator?
    public let repeatLast: Accelerator?

    public init() {
        togglePicker = Accelerator.defaultBinding(for: .togglePicker)
        repeatLast = nil
    }

    public init(togglePicker: Accelerator?, repeatLast: Accelerator?) throws {
        let pickerBinding = try togglePicker?.carbonBinding()
        let repeatBinding = try repeatLast?.carbonBinding()
        if let pickerBinding, pickerBinding == repeatBinding {
            throw ShortcutRebindError.collision(.togglePicker)
        }
        self.togglePicker = togglePicker
        self.repeatLast = repeatLast
    }

    public func accelerator(for action: HotkeyAction) -> Accelerator? {
        action == .togglePicker ? togglePicker : repeatLast
    }

    func replacing(_ action: HotkeyAction, with accelerator: Accelerator?) throws -> Self {
        do {
            return try Self(togglePicker: action == .togglePicker ? accelerator : togglePicker,
                            repeatLast: action == .repeatLast ? accelerator : repeatLast)
        } catch ShortcutRebindError.collision(_) {
            throw ShortcutRebindError.collision(action == .togglePicker ? .repeatLast : .togglePicker)
        }
    }

    private enum CodingKeys: String, CodingKey { case togglePicker, repeatLast }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func binding(_ key: CodingKeys, default fallback: Accelerator?) throws -> Accelerator? {
            guard values.contains(key) else { return fallback }
            return try values.decodeIfPresent(String.self, forKey: key).map { try Accelerator($0) }
        }
        try self.init(togglePicker: binding(.togglePicker, default: Self().togglePicker),
                      repeatLast: binding(.repeatLast, default: nil))
    }
}
