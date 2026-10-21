#if os(Linux)
import CGtk
import MonkeysPawCore

/// General's update section has no timer, network or browser access.
final class LinuxSettingsUpdatePage {
    let widget: GTK.Widget
    private let model: UpdateSettingsModel
    private let automatic: GTK.Widget
    private let version: GTK.Widget
    private let result: GTK.Widget
    private let lastChecked: GTK.Widget
    private let error: GTK.Widget
    private let stateError: GTK.Widget
    private let openingError: GTK.Widget
    private var check: GTK.Widget!
    private var release: GTK.Widget!
    private var isShown = false
    private var isRendering = false

    init(model: UpdateSettingsModel) {
        self.model = model
        // The update pane is a group inside the General column, not a page.
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        gtk_widget_set_name(widget, "settings-update-page")
        let heading = GTK.label(LinuxSettingsUpdateStrings.title)
        gtk_widget_add_css_class(heading, "heading")
        gtk_box_append(mp_box(widget), heading)
        let list = LinuxSettingsLayout.list(in: widget)
        let automaticRow = LinuxSettingsLayout.row(in: list)
        LinuxSettingsLayout.rowText(LinuxSettingsUpdateStrings.automatic, in: automaticRow)
        // A check button keeps the existing tests and accessibility intact.
        automatic = gtk_check_button_new()!
        gtk_widget_set_name(automatic, "settings-automatic-updates")
        mp_accessible_label(automatic, LinuxSettingsUpdateStrings.automatic)
        gtk_widget_set_valign(automatic, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(automaticRow), automatic)
        version = Self.rowLabel("settings-update-version", in: list)
        lastChecked = Self.rowLabel("settings-update-last-checked", in: list)
        result = Self.rowLabel("settings-update-result", in: list)
        let notices = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        LinuxSettingsLayout.caption(LinuxSettingsUpdateStrings.disclosure, in: notices)
        error = LinuxSettingsLayout.caption(name: "settings-update-error", in: notices)
        stateError = LinuxSettingsLayout.caption(name: "settings-update-state-error", in: notices)
        openingError = LinuxSettingsLayout.caption(name: "settings-update-open-error", in: notices)
        for label in [error, stateError, openingError] { gtk_widget_add_css_class(label, "error") }
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        check = GTK.button(LinuxSettingsUpdateStrings.checkNow) { [weak self] in
            guard let self, self.isShown else { return }
            self.model.checkNow()
        }
        gtk_widget_set_name(check, "settings-check-updates")
        release = GTK.button(LinuxSettingsUpdateStrings.viewRelease) { [weak self] in
            guard let self, self.isShown else { return }
            self.model.viewRelease()
        }
        gtk_widget_set_name(release, "settings-view-release")
        for button in [check!, release!] { gtk_box_append(mp_box(buttons), button) }
        gtk_box_append(mp_box(widget), buttons)
        gtk_box_append(mp_box(widget), notices)
        GTK.onSignal(automatic, "toggled") { [weak self] in
            guard let self, self.isShown, !self.isRendering, !self.model.state.isReadOnly else { return }
            self.model.setAutomaticUpdateChecks(gtk_check_button_get_active(mp_check_button(self.automatic)) != 0 ? .enabled : .disabled)
            // Keep committed consent visible even after identical save failures.
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
        let update = state.update
        gtk_check_button_set_active(mp_check_button(automatic), state.automaticUpdateChecks == .enabled ? 1 : 0)
        gtk_widget_set_sensitive(automatic, state.isReadOnly ? 0 : 1)
        gtk_label_set_text(mp_label(version), LinuxSettingsUpdateStrings.version(update?.currentVersion))
        gtk_label_set_text(mp_label(lastChecked), LinuxSettingsUpdateStrings.lastChecked(update?.lastSuccessfulCheck))
        gtk_label_set_text(mp_label(result), LinuxSettingsUpdateStrings.result(update))
        Self.message(error, state.settingsError.map(GeneralSettingsStrings.settingsError))
        Self.message(stateError, update?.stateError.map(LinuxSettingsUpdateStrings.stateError))
        Self.message(openingError, update?.releasePageOpeningFailed == true ? LinuxSettingsUpdateStrings.openingFailed : nil)
        gtk_widget_set_sensitive(check, update?.currentVersion != nil && update?.isChecking == false ? 1 : 0)
        gtk_widget_set_sensitive(release, update?.canOpenRelease == true && update?.isChecking == false ? 1 : 0)
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
