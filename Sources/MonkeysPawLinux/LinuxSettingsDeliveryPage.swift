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
        let (scroll, column) = LinuxSettingsLayout.page(named: "settings-delivery-page")
        widget = scroll
        do {
            let pasting = LinuxSettingsLayout.group(LinuxSettingsStrings.pasting, in: column)
            let list = LinuxSettingsLayout.list(in: pasting)
            let chordRow = LinuxSettingsLayout.row(in: list)
            LinuxSettingsLayout.rowText(DeliverySettingsStrings.defaultChord, in: chordRow)
            chord = gtk_combo_box_text_new()!
            gtk_widget_set_name(chord, "settings-default-chord")
            mp_accessible_label(chord, DeliverySettingsStrings.defaultChord)
            for title in [DeliverySettingsStrings.standardChord, DeliverySettingsStrings.terminalChord] {
                gtk_combo_box_text_append_text(mp_combo_box_text(chord), title)
            }
            gtk_widget_set_valign(chord, GTK_ALIGN_CENTER)
            gtk_box_append(mp_box(chordRow), chord)

            let restoreRow = LinuxSettingsLayout.row(in: list)
            LinuxSettingsLayout.rowText(DeliverySettingsStrings.restoreClipboard, in: restoreRow)
            // A check button keeps the existing tests and accessibility intact.
            restore = gtk_check_button_new()!
            gtk_widget_set_name(restore, "settings-restore-clipboard")
            mp_accessible_label(restore, DeliverySettingsStrings.restoreClipboard)
            gtk_widget_set_valign(restore, GTK_ALIGN_CENTER)
            gtk_box_append(mp_box(restoreRow), restore)

            LinuxSettingsLayout.caption(
                DeliverySettingsStrings.chordExplanation(for: session),
                name: "settings-chord-explanation", in: pasting)
            LinuxSettingsLayout.caption(
                LinuxSettingsDeliveryStrings.explicitChoices,
                name: "settings-explicit-chords", in: pasting)
            LinuxSettingsLayout.caption(DeliverySettingsStrings.restoreCaveat, in: pasting)
            LinuxSettingsLayout.caption(LinuxSettingsDeliveryStrings.restoreOwnership, in: pasting)

            let statusGroup = LinuxSettingsLayout.group(LinuxSettingsStrings.status, in: column)
            let statusList = LinuxSettingsLayout.list(in: statusGroup)
            status = Self.rowLabel("settings-delivery-status", in: statusList)
            permissions = Self.rowLabel("settings-delivery-permissions", in: statusList)
            report = Self.rowLabel("settings-delivery-report", in: statusList)
            error = LinuxSettingsLayout.caption(name: "settings-delivery-error", in: statusGroup)
            gtk_widget_add_css_class(error, "error")

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
            gtk_box_append(mp_box(statusGroup), buttons)
        }

        GTK.onSignal(chord, "changed") { [weak self] in
            guard let self, self.isShown, !self.isRendering, !self.model.state.isReadOnly else { return }
            self.model.setLinuxDefaultPasteChord(gtk_combo_box_get_active(mp_combo_box(self.chord)) == 1 ? .terminal : .standard)
            // Repeated save errors emit no change; redraw after GTK settles.
            GTK.onMainLoop { [weak self] in
                guard let self, self.isShown else { return }
                self.render()
            }
        }
        GTK.onSignal(restore, "toggled") { [weak self] in
            guard let self, self.isShown, !self.isRendering, !self.model.state.isReadOnly else { return }
            self.model.setClipboardRestore(gtk_check_button_get_active(mp_check_button(self.restore)) != 0 ? .previousText : .off)
            GTK.onMainLoop { [weak self] in
                guard let self, self.isShown else { return }
                self.render()
            }
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

    private static func rowLabel(_ name: String, in list: GTK.Widget) -> GTK.Widget {
        let row = LinuxSettingsLayout.row(in: list)
        let text = LinuxSettingsLayout.rowText(in: row)
        return LinuxSettingsLayout.label("", name: name, in: text)
    }

    private static func message(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }
}
#endif
