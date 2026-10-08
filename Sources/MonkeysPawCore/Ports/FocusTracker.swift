public protocol FocusTracker {
    /// Capture before showing the picker, without retaining platform UI types.
    /// Never return this process's own window or application.
    func captureTarget() -> DeliveryTarget?

    /// Nonblocking restore, including the driver's bounded verify/retry (§6.3).
    /// Completion may run on any thread and must be called exactly once.
    /// The driver bounds its own waits and reports .unconfirmed on timeout;
    /// it must not also report a later confirmation.
    /// On dismissal the driver restores only while our app is still frontmost;
    /// hideForDelivery tells the driver to use the explicit delivery path.
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void)
}
