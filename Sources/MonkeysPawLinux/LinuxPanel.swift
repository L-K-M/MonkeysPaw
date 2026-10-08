#if os(Linux)
import CGtk
import MonkeysPawCore

/// An ordinary GTK window; the Wayland compositor owns placement and stacking.
final class LinuxPanel {
    private let window: GTK.Widget

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), AppIdentity.displayName)
        gtk_window_set_default_size(mp_window(window),
                                    Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))

        let placeholder = gtk_label_new("Monkey's Paw: nothing here yet")!
        gtk_window_set_child(mp_window(window), placeholder)
        gtk_widget_set_focusable(window, 1)
    }

    /// "Up" means visible and active. A window buried behind the user's editor
    /// needs presenting; hiding it would make the shortcut appear to do nothing.
    func toggle() {
        guard gtk_widget_get_visible(window) != 0,
              gtk_window_is_active(mp_window(window)) != 0 else {
            show()
            return
        }

        gtk_widget_set_visible(window, 0)
    }

    func show() {
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(window)
    }
}
#endif
