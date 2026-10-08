public protocol Scheduler {
    /// Nonblocking delay; the driver owns its timer and callback thread.
    /// Call work exactly once after the delay; never drop or repeat the callback.
    func after(_ delay: Duration, _ work: @escaping () -> Void)
}
