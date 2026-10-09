import Foundation

public protocol HotkeyBackend {
    var mechanism: HotkeyMechanism { get }
    /// Changes when a live selection/session supersedes earlier activation proof.
    var activationRevision: UUID? { get }

    /// Native key-grab drivers fire on release (§4.2); portals use Activated (§6.3).
    func register(
        _ action: HotkeyAction, accelerator: Accelerator, onFire: @escaping () -> Void
    ) -> HotkeyRegistration

    func unregister(_ registration: HotkeyRegistration)
}

public extension HotkeyBackend {
    var activationRevision: UUID? { nil }
}
