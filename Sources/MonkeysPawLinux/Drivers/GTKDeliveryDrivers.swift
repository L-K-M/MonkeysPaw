#if os(Linux)
import CGtk
import MonkeysPawCore

struct GTKClipboard: Clipboard {
    private let owner: GTK.Widget
    init(owner: GTK.Widget) { self.owner = owner }

    func writeText(_ text: String) {
        // The resident application retains ownership after its picker hides.
        mp_clipboard_set_text(owner, text)
    }
}

struct GTKNotifier: Notifier {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let session: SessionProbe

    init(application: UnsafeMutablePointer<GtkApplication>, session: SessionProbe) {
        self.application = application
        self.session = session
    }

    func copied() { mp_notify(application, AppIdentity.displayName, DeliveryStrings.copied) }

    func pressPaste(chord: PasteChord, reason: CopyReason) {
        mp_notify(application, AppIdentity.displayName,
                  DeliveryStrings.pressPaste(chord: chord, session: session.currentSession()))
    }
}

struct GLibScheduler: Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        GTK.after(delay.timeInterval, work)
    }
}

final class GTKSelfTestTarget: SelfTestTarget {
    private let window: GTK.Widget
    private let entry: GTK.Widget

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)!
        entry = gtk_entry_new()!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.selfTestTitle)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), -1)
        gtk_window_set_child(mp_window(window), entry)
    }

    func present(fieldExpecting text: String) {
        // The field must start empty: only an injected paste may establish receipt.
        mp_entry_set_text(entry, "")
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(entry)
    }

    func readBack() -> String? {
        guard let text = mp_entry_text(entry) else { return nil }
        return String(cString: text)
    }

    func close() { gtk_widget_set_visible(window, 0) }
}
#endif
