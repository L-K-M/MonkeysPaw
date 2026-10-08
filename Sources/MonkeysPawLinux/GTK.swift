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

    private final class KeyBox {
        let call: (UInt32, UInt32) -> Bool
        init(_ call: @escaping (UInt32, UInt32) -> Bool) { self.call = call }
    }

    private final class CommandLineBox {
        let call: (UnsafeMutablePointer<GApplicationCommandLine>) -> Int32
        init(_ call: @escaping (UnsafeMutablePointer<GApplicationCommandLine>) -> Int32) { self.call = call }
    }

    /// notify signals include a GParamSpec between the instance and user data.
    static func onNotify(_ instance: UnsafeMutableRawPointer, _ property: String,
                         _ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                        UnsafeMutableRawPointer?) -> Void = { _, _, data in
            guard let data else { return }
            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
        }
        mp_connect(instance, "notify::" + property, unsafeBitCast(trampoline, to: GCallback.self), box, releaseBox)
    }

    static func onCloseRequested(_ window: Widget, _ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, data in
            guard let data else { return 0 }
            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
            return 1 // The presentation model owns dismissal; GTK must not destroy.
        }
        mp_connect(window, "close-request", unsafeBitCast(trampoline, to: GCallback.self), box, releaseBox)
    }

    /// Vervellum's exact-arity key trampoline. Controllers own their closures.
    static func observeKeys(_ widget: Widget, _ handler: @escaping (UInt32, UInt32) -> Bool) {
        let controller = gtk_event_controller_key_new()!
        let box = Unmanaged.passRetained(KeyBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType,
                                        UnsafeMutableRawPointer?) -> gboolean = { _, key, _, modifiers, data in
            guard let data else { return 0 }
            return Unmanaged<KeyBox>.fromOpaque(data).takeUnretainedValue().call(key, modifiers.rawValue) ? 1 : 0
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<KeyBox>.fromOpaque(data).release()
        }
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        mp_connect(UnsafeMutableRawPointer(controller), "key-pressed",
                   unsafeBitCast(trampoline, to: GCallback.self), box, release)
        gtk_widget_add_controller(widget, controller)
    }

    static func onCommandLine(_ application: UnsafeMutablePointer<GtkApplication>,
                             _ handler: @escaping (UnsafeMutablePointer<GApplicationCommandLine>) -> Int32) {
        let box = Unmanaged.passRetained(CommandLineBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GApplicationCommandLine>?,
                                        UnsafeMutableRawPointer?) -> gint = { _, command, data in
            guard let command, let data else { return 1 }
            return Unmanaged<CommandLineBox>.fromOpaque(data).takeUnretainedValue().call(command)
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<CommandLineBox>.fromOpaque(data).release()
        }
        mp_connect(UnsafeMutableRawPointer(application), "command-line",
                   unsafeBitCast(trampoline, to: GCallback.self), box, release)
    }

    static func button(_ title: String, _ action: @escaping () -> Void) -> Widget {
        let button = gtk_button_new_with_label(title)!
        onSignal(UnsafeMutableRawPointer(button), "clicked", action)
        return button
    }

    static func label(_ text: String) -> Widget {
        let label = gtk_label_new(text)!
        gtk_label_set_wrap(mp_label(label), 1)
        gtk_label_set_xalign(mp_label(label), 0)
        return label
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
