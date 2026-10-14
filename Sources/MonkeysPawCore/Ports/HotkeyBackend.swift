import Foundation

public protocol HotkeyBackend {
    var mechanism: HotkeyMechanism { get }
    /// Changes when a live selection/session supersedes earlier activation proof.
    var activationRevision: UUID? { get }

    /// Declare every owned action. Nil is deliberately unbound, never permission
    /// to choose a default or show consent. Retain callbacks only when the driver
    /// can bind the action; unsupported adapters discard them.
    /// Native key-grab drivers fire on release (§4.2); portals use Activated (§6.3).
    func register(
        _ action: HotkeyAction, accelerator: Accelerator?, onFire: @escaping () -> Void
    ) -> HotkeyRegistration

    func unregister(_ registration: HotkeyRegistration)
}

public extension HotkeyBackend {
    var activationRevision: UUID? { nil }
}
