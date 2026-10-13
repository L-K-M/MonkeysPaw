/// Settings diagnostics contain no target identity, text or clipboard data.
public struct DeliveryStatusSnapshot: Equatable, Sendable {
    public let session: DesktopSession
    /// Policy order, not evidence that any backend is ready or received text.
    public let pasteLadder: [PasteBackend]
    public let cachedFailures: [BackendFailure]
    /// A sent chord remains best-effort; only self-test reports readback.
    public let lastDelivery: DeliveryReceipt?
}
