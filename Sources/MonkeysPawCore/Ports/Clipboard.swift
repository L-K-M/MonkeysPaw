public protocol Clipboard {
    func writeText(_ text: String)
    /// Call on the driver's owning UI thread. Completes exactly once on that
    /// thread/context, inline or asynchronously; nil means empty/unavailable.
    func readText(_ completion: @escaping @Sendable (String?) -> Void)
}
