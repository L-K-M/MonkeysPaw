public protocol FocusTracker {
    /// Capture before showing the picker, without retaining platform UI types.
    func captureTarget() -> DeliveryTarget?

    /// Nonblocking restore, including the driver's bounded verify/retry (§6.3).
    /// On dismissal the driver restores only while our app is still frontmost;
    /// hideForDelivery tells the driver to use the explicit delivery path.
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void)
}
