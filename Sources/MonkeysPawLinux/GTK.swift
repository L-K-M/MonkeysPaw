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

    private final class DrawBox {
        let call: (OpaquePointer, Int32, Int32) -> Void
        init(_ call: @escaping (OpaquePointer, Int32, Int32) -> Void) { self.call = call }
    }

    /// GTK owns the closure until a new draw function replaces it or the area dies.
    static func draw(_ area: Widget, _ handler: @escaping (OpaquePointer, Int32, Int32) -> Void) {
        let data = Unmanaged.passRetained(DrawBox(handler)).toOpaque()
        gtk_drawing_area_set_draw_func(mp_drawing_area(area), { _, cr, width, height, data in
            guard let cr, let data else { return }
            Unmanaged<DrawBox>.fromOpaque(data).takeUnretainedValue().call(cr, width, height)
        }, data, { data in
            if let data { Unmanaged<DrawBox>.fromOpaque(data).release() }
        })
    }

    private final class TickBox {
        let call: (Int64) -> Bool
        init(_ call: @escaping (Int64) -> Bool) { self.call = call }
    }

    /// Frame-clock callbacks run on GLib's UI thread. False removes the callback.
    @discardableResult
    static func tick(_ widget: Widget, _ handler: @escaping (Int64) -> Bool) -> guint {
        let data = Unmanaged.passRetained(TickBox(handler)).toOpaque()
        return gtk_widget_add_tick_callback(widget, { _, clock, data in
            guard let clock, let data else { return 0 }
            return Unmanaged<TickBox>.fromOpaque(data).takeUnretainedValue().call(
                Int64(gdk_frame_clock_get_frame_time(clock))) ? 1 : 0
        }, data, { data in
            if let data { Unmanaged<TickBox>.fromOpaque(data).release() }
        })
    }

    static func removeTick(_ widget: Widget, _ id: guint) {
        gtk_widget_remove_tick_callback(widget, id)
    }

    private final class ResizeBox {
        let call: (Int32, Int32) -> Void
        init(_ call: @escaping (Int32, Int32) -> Void) { self.call = call }
    }

    static func onResize(_ area: Widget, _ handler: @escaping (Int32, Int32) -> Void) {
        let data = Unmanaged.passRetained(ResizeBox(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, gint, gint, UnsafeMutableRawPointer?) -> Void = { _, width, height, data in
            guard let data else { return }
            Unmanaged<ResizeBox>.fromOpaque(data).takeUnretainedValue().call(width, height)
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<ResizeBox>.fromOpaque(data).release() }
        }
        mp_connect(area, "resize", unsafeBitCast(callback, to: GCallback.self), data, release)
    }

    static func onClick(_ widget: Widget, _ handler: @escaping () -> Void) {
        let gesture = gtk_gesture_click_new()!
        let data = Unmanaged.passRetained(ClickBox { _, _ in handler() }).toOpaque()
        let pressed: @convention(c) (UnsafeMutableRawPointer?, gint, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, x, y, data in
            guard let data else { return }
            Unmanaged<ClickBox>.fromOpaque(data).takeUnretainedValue().call(x, y)
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<ClickBox>.fromOpaque(data).release() }
        }
        mp_connect(UnsafeMutableRawPointer(gesture), "released", unsafeBitCast(pressed, to: GCallback.self), data, release)
        gtk_widget_add_controller(widget, mp_gesture_controller(gesture))
    }

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

    private final class PreeditBox {
        let call: (Bool) -> Void
        init(_ call: @escaping (Bool) -> Void) { self.call = call }
    }

    /// GtkText and GtkTextView emit their preedit string before commit. Keep
    /// only its presence; the native input method owns the composition text.
    static func onPreeditChanged(_ widget: Widget, _ handler: @escaping (Bool) -> Void) {
        let box = Unmanaged.passRetained(PreeditBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
                                        UnsafeMutableRawPointer?) -> Void = { _, text, data in
            guard let data else { return }
            Unmanaged<PreeditBox>.fromOpaque(data).takeUnretainedValue().call((text?.pointee ?? 0) != 0)
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<PreeditBox>.fromOpaque(data).release()
        }
        mp_connect(widget, "preedit-changed", unsafeBitCast(trampoline, to: GCallback.self), box, release)
    }

    private final class RowBox {
        let call: (Int?) -> Void
        init(_ call: @escaping (Int?) -> Void) { self.call = call }
    }

    private final class ResponseBox {
        let call: (Int32) -> Void
        init(_ call: @escaping (Int32) -> Void) { self.call = call }
    }

    private final class HeaderBox {
        let heading: (Int, Int?) -> String?
        init(_ heading: @escaping (Int, Int?) -> String?) { self.heading = heading }
    }

    static func listHeaders(_ list: Widget, heading: @escaping (Int, Int?) -> String?) {
        let data = Unmanaged.passRetained(HeaderBox(heading)).toOpaque()
        gtk_list_box_set_header_func(mp_list_box(list), { row, before, data in
            guard let row, let data else { return }
            let heading = Unmanaged<HeaderBox>.fromOpaque(data).takeUnretainedValue().heading(
                Int(gtk_list_box_row_get_index(row)), before.map { Int(gtk_list_box_row_get_index($0)) })
            let label = heading.map { text -> Widget in
                let label = GTK.label(text)
                gtk_widget_add_css_class(label, "heading")
                gtk_widget_add_css_class(label, "dim-label")
                gtk_widget_set_margin_top(label, 16)
                gtk_widget_set_margin_bottom(label, 6)
                gtk_widget_set_margin_start(label, 12)
                return label
            }
            gtk_list_box_row_set_header(row, label)
        }, data, { data in
            if let data { Unmanaged<HeaderBox>.fromOpaque(data).release() }
        })
    }

    private final class ClickBox {
        let call: (Double, Double) -> Void
        init(_ call: @escaping (Double, Double) -> Void) { self.call = call }
    }

    static func onSecondaryClick(_ widget: Widget, _ handler: @escaping (Double, Double) -> Void) {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(mp_gesture_single(gesture), 3)
        let data = Unmanaged.passRetained(ClickBox(handler)).toOpaque()
        let pressed: @convention(c) (UnsafeMutableRawPointer?, gint, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, x, y, data in
            guard let data else { return }
            Unmanaged<ClickBox>.fromOpaque(data).takeUnretainedValue().call(x, y)
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<ClickBox>.fromOpaque(data).release() }
        }
        mp_connect(UnsafeMutableRawPointer(gesture), "pressed", unsafeBitCast(pressed, to: GCallback.self), data, release)
        gtk_widget_add_controller(widget, mp_gesture_controller(gesture))
    }

    /// GtkNativeDialog responses carry a response id before user data.
    static func onResponse(_ dialog: UnsafeMutableRawPointer, _ handler: @escaping (Int32) -> Void) {
        let box = Unmanaged.passRetained(ResponseBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, gint,
                                        UnsafeMutableRawPointer?) -> Void = { _, response, data in
            guard let data else { return }
            Unmanaged<ResponseBox>.fromOpaque(data).takeUnretainedValue().call(response)
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<ResponseBox>.fromOpaque(data).release()
        }
        mp_connect(dialog, "response", unsafeBitCast(trampoline, to: GCallback.self), box, release)
    }

    /// List signals carry a nullable row between the instance and user data.
    static func onRow(_ list: Widget, _ signal: String, _ handler: @escaping (Int?) -> Void) {
        let box = Unmanaged.passRetained(RowBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                        UnsafeMutableRawPointer?) -> Void = { _, row, data in
            guard let data else { return }
            let index = row.map { Int(gtk_list_box_row_get_index(mp_list_box_row(
                $0.assumingMemoryBound(to: GtkWidget.self)))) }
            Unmanaged<RowBox>.fromOpaque(data).takeUnretainedValue().call(index)
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<RowBox>.fromOpaque(data).release()
        }
        mp_connect(list, signal, unsafeBitCast(trampoline, to: GCallback.self), box, release)
    }

    private final class CommandLineBox {
        let call: (UnsafeMutablePointer<GApplicationCommandLine>) -> Int32
        init(_ call: @escaping (UnsafeMutablePointer<GApplicationCommandLine>) -> Int32) { self.call = call }
    }

    private final class OpenBox {
        let call: (String) -> Void
        init(_ call: @escaping (String) -> Void) { self.call = call }
    }

    /// GApplication's open signal carries GFile**, count and hint before data.
    static func onOpen(_ application: UnsafeMutablePointer<GtkApplication>, _ handler: @escaping (String) -> Void) {
        let box = Unmanaged.passRetained(OpenBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>?,
                                        gint, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, files, count, _, data in
            guard let files, count == 1, let file = files[0], let data,
                  let uri = g_file_get_uri(file) else { return }
            defer { g_free(uri) }
            Unmanaged<OpenBox>.fromOpaque(data).takeUnretainedValue().call(String(cString: uri))
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<OpenBox>.fromOpaque(data).release()
        }
        mp_connect(UnsafeMutableRawPointer(application), "open", unsafeBitCast(trampoline, to: GCallback.self), box, release)
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

    /// GtkSearchEntry's placeholder setter arrived after GTK 4.8; the property
    /// is already available there through GObject's non-variadic API.
    static func searchPlaceholder(_ entry: Widget, _ text: String) {
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        g_value_set_string(&value, text)
        g_object_set_property(mp_object(entry), "placeholder-text", &value)
        g_value_unset(&value)
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

    private final class StateBox {
        let call: (Bool) -> Void
        init(_ call: @escaping (Bool) -> Void) { self.call = call }
    }

    /// Checkable action consumers can request a state instead of activating.
    /// Both signals carry a GVariant; keep the same exact-arity interop.
    static func onActionStateChanged(_ action: UnsafeMutableRawPointer, _ handler: @escaping (Bool) -> Void) {
        let box = Unmanaged.passRetained(StateBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, value, data in
            guard let value, let data, String(cString: g_variant_get_type_string(value)) == "b" else { return }
            Unmanaged<StateBox>.fromOpaque(data).takeUnretainedValue().call(g_variant_get_boolean(value) != 0)
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<StateBox>.fromOpaque(data).release() }
        }
        mp_connect(action, "change-state", unsafeBitCast(trampoline, to: GCallback.self), box, release)
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

    private final class PaintBox {
        let call: () -> Void
        var clock: OpaquePointer?
        var handler: gulong = 0
        init(_ call: @escaping () -> Void) { self.call = call }
    }

    /// Runs `work` once, after the widget's next paint, when every allocation
    /// in the window is current. Snapshotting a widget whose layout is still
    /// queued is a GTK warning (fatal in tests).
    static func afterNextPaint(_ widget: Widget, _ work: @escaping () -> Void) {
        guard let clock = gtk_widget_get_frame_clock(widget) else { return }
        let box = PaintBox(work)
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            let box = Unmanaged<PaintBox>.fromOpaque(data).takeUnretainedValue()
            guard box.handler != 0, let clock = box.clock else { return }
            let handler = box.handler
            let work = box.call
            box.handler = 0
            // Disconnect first (its destroy notify releases the box): the work
            // may tear down the widget and, with it, the frame clock.
            g_signal_handler_disconnect(UnsafeMutableRawPointer(clock), handler)
            work()
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<PaintBox>.fromOpaque(data).release()
        }
        box.clock = clock
        box.handler = mp_connect(UnsafeMutableRawPointer(clock), "after-paint",
                                 unsafeBitCast(trampoline, to: GCallback.self),
                                 Unmanaged.passRetained(box).toOpaque(), release)
        gtk_widget_queue_draw(widget)
    }

    /// Keep borrowed widget pointers valid when the window manager closes the panel.
    static func hideOnClose(_ window: Widget) {
        gtk_window_set_hide_on_close(mp_window(window), 1)
    }
}
#endif
