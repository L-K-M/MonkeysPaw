#if os(Linux)
import CGtk
import MonkeysPawCore

/// An ordinary GTK window; the Wayland compositor owns placement and stacking.
final class LinuxPanel: PanelWindow {
    private let window: GTK.Widget
    private weak var model: PanelModel?
    private var initialFocus: GTK.Widget?
    private var blurRevision = 0

    var clipboardOwner: GTK.Widget { window }

    var isActiveAndVisible: Bool {
        gtk_widget_get_visible(window) != 0 && gtk_window_is_active(mp_window(window)) != 0
    }

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), AppIdentity.displayName)
        gtk_window_set_default_size(mp_window(window),
                                    Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))

        let placeholder = gtk_label_new(DeliveryStrings.testPrompt)!
        gtk_window_set_child(mp_window(window), placeholder)
        gtk_widget_set_focusable(window, 1)
    }

    func bind(model: PanelModel, openSetup: @escaping () -> Void) {
        self.model = model
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
        let prompt = GTK.label(model.prompt)
        gtk_label_set_selectable(mp_label(prompt), 1)
        gtk_widget_set_focusable(prompt, 1)
        initialFocus = prompt
        gtk_widget_set_vexpand(prompt, 1)
        gtk_box_append(mp_box(content), prompt)
        gtk_box_append(mp_box(content), GTK.label(LinuxStrings.panelHint))
        gtk_box_append(mp_box(content), GTK.button(LinuxStrings.setup, openSetup))
        gtk_window_set_child(mp_window(window), content)

        GTK.observeKeys(window) { [weak self, weak model] key, modifiers in
            guard let self, let model else { return false }
            if key == UInt32(GDK_KEY_Escape) {
                model.cancel()
                return true
            }
            guard [UInt32(GDK_KEY_Return), UInt32(GDK_KEY_KP_Enter), UInt32(GDK_KEY_ISO_Enter)].contains(key) else {
                return false
            }
            let terminalModifiers = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue
            let chord: PasteChord = modifiers & terminalModifiers == terminalModifiers ? .terminal : .standard
            if chord == .standard, let focus = gtk_window_get_focus(mp_window(self.window)), mp_is_button(focus) != 0 {
                // Let a focused Setup button handle its native Enter activation.
                return false
            }
            model.confirm(mode: .paste(chord))
            return true
        }

        GTK.onCloseRequested(window) { [weak model] in model?.cancel() }
        GTK.onNotify(UnsafeMutableRawPointer(window), "is-active") { [weak self] in self?.focusChanged() }
    }

    private func focusChanged() {
        blurRevision += 1
        let revision = blurRevision
        guard gtk_widget_get_visible(window) != 0, !isActiveAndVisible else { return }
        GTK.after(Limits.blurHideDelay.timeInterval) { [weak self] in
            guard let self, self.blurRevision == revision,
                  gtk_widget_get_visible(self.window) != 0, !self.isActiveAndVisible else { return }
            // Dismissal delegates to Core; LinuxFocusTracker never takes focus
            // back from the window the user just selected (§11.5).
            self.model?.cancel()
        }
    }

    private var activationToken: String?

    func useActivationToken(_ token: String?) { activationToken = token }

    func show() {
        blurRevision += 1
        if let activationToken {
            gtk_window_set_startup_id(mp_window(window), activationToken)
            self.activationToken = nil
        }
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(initialFocus ?? window)
    }

    func hideForDelivery() {
        // This operation has no focus-restoration callback or dismissal intent.
        hide()
    }

    func hide() {
        blurRevision += 1
        gtk_widget_set_visible(window, 0)
    }
}
#endif
