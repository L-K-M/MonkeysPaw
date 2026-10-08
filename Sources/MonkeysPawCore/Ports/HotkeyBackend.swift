public protocol HotkeyBackend {
    var mechanism: HotkeyMechanism { get }

    /// Native key-grab drivers fire on release (§4.2); portals use Activated (§6.3).
    func register(
        _ action: HotkeyAction, accelerator: Accelerator, onFire: @escaping () -> Void
    ) -> HotkeyRegistration

    func unregister(_ registration: HotkeyRegistration)
}
