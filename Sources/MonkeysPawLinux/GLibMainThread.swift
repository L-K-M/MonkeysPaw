#if os(Linux)
import MonkeysPawCore

/// Core's callbacks enter the GLib loop through this driver, never MainActor.
struct GLibMainThread: MainThread {
    func run(_ work: @escaping () -> Void) {
        GTK.onMainLoop(work)
    }
}
#endif
