#if os(Linux)
import CGtk
import MonkeysPawCore

/// GTK renders the shared model; delivery, permission and preference work stays in Core.
final class LinuxSettingsDeliveryPage {
    let widget: GTK.Widget
    private let model: DeliverySettingsModel
    private let chord: GTK.Widget
    private let restore: GTK.Widget
    private let status: GTK.Widget
    private let permissions: GTK.Widget
    private let error: GTK.Widget
    private let report: GTK.Widget
    private var testButton: GTK.Widget!
    private var isShown = false
    private var isRendering = false

    init(model: DeliverySettingsModel, session: DesktopSession) {
        self.model = model
        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(page, 12) }
        widget = gtk_scrolled_window_new()!
        gtk_widget_set_name(widget, "settings-delivery-page")
        gtk_scrolled_window_set_child(mp_scrolled_window(widget), page)

        gtk_box_append(mp_box(page), GTK.label(DeliverySettingsStrings.defaultChord))
        chord = gtk_combo_box_text_new()!
        gtk_widget_set_name(chord, "settings-default-chord")
        mp_accessible_label(chord, DeliverySettingsStrings.defaultChord)
        for title in [DeliverySettingsStrings.standardChord, DeliverySettingsStrings.terminalChord] {
            gtk_combo_box_text_append_text(mp_combo_box_text(chord), title)
        }
        gtk_box_append(mp_box(page), chord)
        let explanation = GTK.label(DeliverySettingsStrings.chordExplanation(for: session))
        gtk_widget_set_name(explanation, "settings-chord-explanation")
        gtk_box_append(mp_box(page), explanation)
        let explicit = GTK.label(LinuxSettingsDeliveryStrings.explicitChoices)
        gtk_widget_set_name(explicit, "settings-explicit-chords")
        gtk_box_append(mp_box(page), explicit)
        restore = gtk_check_button_new_with_label(DeliverySettingsStrings.restoreClipboard)!
        gtk_widget_set_name(restore, "settings-restore-clipboard")
        mp_accessible_label(restore, DeliverySettingsStrings.restoreClipboard)
        gtk_box_append(mp_box(page), restore)
        gtk_box_append(mp_box(page), GTK.label(DeliverySettingsStrings.restoreCaveat))
        gtk_box_append(mp_box(page), GTK.label(LinuxSettingsDeliveryStrings.restoreOwnership))
        status = Self.label("settings-delivery-status", in: page)
        permissions = Self.label("settings-delivery-permissions", in: page)
        error = Self.label("settings-delivery-error", in: page)
        gtk_widget_add_css_class(error, "error")
        report = Self.label("settings-delivery-report", in: page)

        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        testButton = GTK.button(DeliverySettingsStrings.testPaste) { [weak self] in
            guard let self, self.isShown else { return }
            self.model.runSelfTest()
        }
        gtk_widget_set_name(testButton, "settings-test-paste")
        let setup = GTK.button(DeliverySettingsStrings.openSetup) { [weak self] in
            guard let self, self.isShown else { return }
            self.model.openSetup()
        }
        gtk_widget_set_name(setup, "settings-delivery-open-setup")
        for button in [testButton!, setup] { gtk_box_append(mp_box(buttons), button) }
        gtk_box_append(mp_box(page), buttons)

        GTK.onSignal(chord, "changed") { [weak self] in
            guard let self, self.isShown, !self.isRendering, !self.model.state.isReadOnly else { return }
            self.model.setLinuxDefaultPasteChord(gtk_combo_box_get_active(mp_combo_box(self.chord)) == 1 ? .terminal : .standard)
        }
        GTK.onSignal(restore, "toggled") { [weak self] in
            guard let self, self.isShown, !self.isRendering, !self.model.state.isReadOnly else { return }
            self.model.setClipboardRestore(gtk_check_button_get_active(mp_check_button(self.restore)) != 0 ? .previousText : .off)
        }
        render()
    }

    deinit { model.onChange = nil }

    func show() {
        isShown = true
        model.onChange = { [weak self] in self?.render() }
        model.refresh()
        render()
    }

    func hide() {
        isShown = false
        model.onChange = nil
    }

    func retire() { hide(); model.retire() }

    private func render() {
        isRendering = true
        defer { isRendering = false }
        let state = model.state
        gtk_combo_box_set_active(mp_combo_box(chord), state.preferences.linuxDefaultPasteChord == .terminal ? 1 : 0)
        gtk_check_button_set_active(mp_check_button(restore), state.preferences.clipboardRestore == .previousText ? 1 : 0)
        for control in [chord, restore] { gtk_widget_set_sensitive(control, state.isReadOnly ? 0 : 1) }
        gtk_label_set_text(mp_label(status), LinuxSettingsDeliveryStrings.status(state.delivery))
        gtk_label_set_text(mp_label(permissions), state.permissionRows.map(LinuxSettingsDeliveryStrings.permission).joined(separator: "\n"))
        Self.message(error, state.settingsError.map(GeneralSettingsStrings.settingsError))
        let testing = state.test == .testing
        gtk_widget_set_sensitive(testButton, testing ? 0 : 1)
        let text: String
        switch state.test {
        case .idle: text = ""
        case .testing: text = LinuxStrings.selfTestWorking
        case .tested(let result): text = LinuxSettingsDeliveryStrings.report(result)
        }
        Self.message(report, text)
    }

    private static func label(_ name: String, in page: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, name)
        gtk_box_append(mp_box(page), label)
        return label
    }

    private static func message(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }
}
#endif
