/// Delivers UI work through the platform's own main loop (§4.2).
///
/// Core never uses DispatchQueue.main or @MainActor: neither runs under a
/// GLib main loop. Inject this port instead; Linux marshals with g_idle_add,
/// while the macOS driver uses its native UI thread.
public protocol MainThread {
    func run(_ work: @escaping () -> Void)
}
