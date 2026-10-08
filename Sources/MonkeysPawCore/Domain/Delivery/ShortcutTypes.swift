import Foundation

public enum HotkeyAction: String, CaseIterable, Sendable {
    case togglePicker
    case repeatLast
}

public enum HotkeyMechanism: String, Equatable, Sendable {
    case carbon
    case globalShortcutsPortal
    case gnomeCustomKeybinding
    case kglobalaccel
    case manual
}

public enum RegistrationStatus: Equatable, Sendable {
    case registered
    case needsAction
    case failed
    case unbound
}

/// The opaque id lets a driver retain its native registration privately.
public struct HotkeyRegistration: Equatable, Sendable {
    public let id: UUID
    public let mechanism: HotkeyMechanism
    public let status: RegistrationStatus
    public let detail: String

    public init(
        id: UUID = UUID(), mechanism: HotkeyMechanism,
        status: RegistrationStatus, detail: String
    ) {
        self.id = id
        self.mechanism = mechanism
        self.status = status
        self.detail = detail
    }
}

public enum ShortcutVerification: Equatable, Sendable {
    case notStarted
    case waiting
    case verified
}
