#if os(Linux)
import CGtk
import Foundation

/// Closure interop and main-loop scheduling for GTK4.
///
/// The casts and macro gaps are handled in `Sources/CGtk/shim.h`. Swift represents
/// an opaque GTK type as `OpaquePointer` and a complete one as a typed pointer;
/// casting in C means callers never have to know which is which.
enum GTK {
    typealias Widget = UnsafeMutablePointer<GtkWidget>

    private static let millisecondsPerSecond: TimeInterval = 1_000
    private static let maximumDelayMilliseconds = TimeInterval(guint.max)

    /// Holds a Swift closure for the lifetime of a signal connection.
    ///
    /// A C function pointer cannot capture, so the closure travels as `user_data`
    /// and is unboxed inside the trampoline. The matching `GClosureNotify` balances
    /// the retain when the object is finalised; without it every connection leaks.
    private final class Box {
        let call: () -> Void

        init(_ call: @escaping () -> Void) {
            self.call = call
        }
    }

    private static let releaseBox: GClosureNotify = { data, _ in
        guard let data else { return }

        Unmanaged<Box>.fromOpaque(data).release()
    }

    /// Only for signals taking the instance and user data, such as "activate".
    /// Anything else needs its own trampoline with the exact arity.
    static func onSignal(_ instance: UnsafeMutableRawPointer, _ name: String,
                         _ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }

            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
        }

        mp_connect(instance, name, unsafeBitCast(trampoline, to: GCallback.self), box, releaseBox)
    }

    /// A GSimpleAction's "activate" has three arguments, including a GVariant.
    /// Using onSignal's two-argument trampoline would read that variant as the
    /// boxed closure: unsafeBitCast defeats the type check and the result crashes.
    static func onActionActivated(_ action: UnsafeMutableRawPointer,
                                  _ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                        UnsafeMutableRawPointer?) -> Void = { _, _, data in
            guard let data else { return }

            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
        }

        mp_connect(action, "activate", unsafeBitCast(trampoline, to: GCallback.self), box, releaseBox)
    }

    /// This is the only correct UI hop from Swift concurrency on Linux.
    /// GLib does not drain libdispatch's main queue: DispatchQueue.main never
    /// fires and a MainActor hop hangs silently, leaving a window that never updates.
    @discardableResult
    static func onMainLoop(_ work: @escaping () -> Void) -> guint {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            guard let data else { return 0 }

            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
            return 0 // G_SOURCE_REMOVE; the destroy notify releases the box
        }
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
            guard let data else { return }

            Unmanaged<Box>.fromOpaque(data).release()
        }

        return g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, trampoline, box, release)
    }

    /// The delayed counterpart to onMainLoop, on the same GLib thread.
    /// DispatchQueue.main.asyncAfter would schedule onto a queue nothing drains.
    @discardableResult
    static func after(_ interval: TimeInterval, _ work: @escaping () -> Void) -> guint {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            guard let data else { return 0 }

            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
            return 0 // G_SOURCE_REMOVE; the destroy notify releases the box
        }
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
            guard let data else { return }

            Unmanaged<Box>.fromOpaque(data).release()
        }

        // GLib runs the destroy notify exactly once, even if the source is removed
        // before firing, so a timer cannot leak its closure on early teardown.
        let milliseconds = min(maximumDelayMilliseconds, max(0, interval * millisecondsPerSecond))
        return g_timeout_add_full(G_PRIORITY_DEFAULT, guint(milliseconds),
                                  trampoline, box, release)
    }

    /// Keep borrowed widget pointers valid when the window manager closes the panel.
    static func hideOnClose(_ window: Widget) {
        gtk_window_set_hide_on_close(mp_window(window), 1)
    }
}
#endif
