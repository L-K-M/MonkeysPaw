public enum SetupStatus: Equatable, Sendable {
    case ok
    case needsAction(fix: String)
    case notApplicable
    case unknown
}

public struct SetupRow: Equatable, Sendable {
    public enum Kind: CaseIterable, Sendable {
        case accessibility, portal, ydotool, hotkey, kde
    }

    public let kind: Kind
    public let status: SetupStatus
    public let registration: HotkeyRegistration?

    public init(kind: Kind, status: SetupStatus, registration: HotkeyRegistration? = nil) {
        self.kind = kind
        self.status = status
        self.registration = registration
    }
}

public enum SetupStrings {
    public static let pressShortcut = "Press your shortcut now"
    public static let assignShortcut = "Assign a shortcut in Settings"
    public static let unboundShortcut = "No shortcut assigned"
    public static let kdeShortcut = "Set the key in System Settings → Shortcuts → Monkey's Paw"
}
