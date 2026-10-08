public protocol Scheduler {
    /// Nonblocking delay; the driver owns its timer and callback thread.
    func after(_ delay: Duration, _ work: @escaping () -> Void)
}
