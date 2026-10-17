#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Borrows GTK widgets and the active library's shared Account model.
final class LinuxAccountSettingsPage {
    enum Retirement { case hidden, destroyed }
    let widget: GTK.Widget
    private let makeModel: () -> AccountModel?
    private let groups: LinuxGroupManagementView
    private var model: AccountModel?
    private var observer: UUID?
    private var isShown = false
    private var isDestroyed = false
    private var pendingIntent: UUID?
    private var passwordInputReset: UUID?
    private var renderedConnection: AccountConnection?
    private var hasRenderedConnection = false
    private var renderedDevices: [SyncAPI.Device] = []
    private var deviceButtons: [GTK.Widget] = []
    private var renderedHeld: [AccountHeldPrompt] = []
    private var renderedKeptLocal: Set<PromptIdentity> = []
    private var selectedHeld: Set<PromptIdentity> = []

    private let connection: GTK.Widget
    private let form: GTK.Widget
    private let server: GTK.Widget
    private let username: GTK.Widget
    private let password: GTK.Widget
    private let deviceName: GTK.Widget
    private let storage: GTK.Widget
    private let progress: GTK.Widget
    private let error: GTK.Widget
    private let cleanup: GTK.Widget
    private let reserved: GTK.Widget
    private let devices: GTK.Widget
    private let heldSection: GTK.Widget
    private let heldRows: GTK.Widget
    private var signIn: GTK.Widget!
    private var signOut: GTK.Widget!
    private var refresh: GTK.Widget!
    private var keepLocal: GTK.Widget!
    private var include: GTK.Widget!

    init(makeModel: @escaping () -> AccountModel?, makeGroups: @escaping () -> GroupManagementModel? = { nil }) {
        self.makeModel = makeModel
        groups = LinuxGroupManagementView(makeModel: makeGroups)
        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(page, 12) }
        widget = gtk_scrolled_window_new()!
        gtk_widget_set_name(widget, "settings-account-page")
        gtk_scrolled_window_set_child(mp_scrolled_window(widget), page)
        connection = Self.label("connection", in: page)
        storage = Self.label("storage", in: page)
        form = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(page), form)
        server = Self.entry("server", title: LinuxAccountSettingsStrings.server, in: form)
        username = Self.entry("username", title: LinuxAccountSettingsStrings.username, in: form)
        gtk_box_append(mp_box(form), GTK.label(LinuxAccountSettingsStrings.password))
        password = gtk_password_entry_new()!
        gtk_widget_set_name(password, "settings-account-password")
        mp_accessible_label(password, LinuxAccountSettingsStrings.password)
        gtk_box_append(mp_box(form), password)
        deviceName = Self.entry("device-name", title: LinuxAccountSettingsStrings.deviceName, in: form)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(page), actions)
        progress = Self.label("progress", in: page)
        error = Self.label("error", in: page)
        cleanup = Self.label("cleanup", in: page)
        for label in [error, cleanup] { gtk_widget_add_css_class(label, "error") }
        reserved = Self.label("reserved", in: page)
        gtk_box_append(mp_box(page), GTK.label(LinuxAccountSettingsStrings.devices))
        devices = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_name(devices, "settings-account-devices")
        gtk_box_append(mp_box(page), devices)
        heldSection = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(page), heldSection)
        gtk_box_append(mp_box(heldSection), GTK.label(LinuxAccountSettingsStrings.heldFiles))
        gtk_box_append(mp_box(heldSection), GTK.label(LinuxAccountSettingsStrings.heldGuidance))
        heldRows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(heldSection), heldRows)
        let heldActions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(heldSection), heldActions)
        gtk_box_append(mp_box(page), groups.widget)

        signIn = button("sign-in", title: LinuxAccountSettingsStrings.signIn, in: actions) { [weak self] model in
            guard let self else { return }
            var supplied = String(cString: mp_entry_text(self.password))
            mp_entry_set_text(self.password, "")
            model.login(server: String(cString: mp_entry_text(self.server)),
                username: String(cString: mp_entry_text(self.username)), password: &supplied,
                deviceName: String(cString: mp_entry_text(self.deviceName)))
        }
        refresh = button("refresh", title: LinuxAccountSettingsStrings.refresh, in: actions) { $0.refresh() }
        signOut = button("sign-out", title: LinuxAccountSettingsStrings.signOut, in: actions) { $0.signOut() }
        keepLocal = button("keep-local", title: LinuxAccountSettingsStrings.keepLocal, in: heldActions) { [weak self] model in
            if let self { model.decideHeld(self.selectedHeld, decision: .keepLocal) }
        }
        include = button("include", title: LinuxAccountSettingsStrings.include, in: heldActions) { [weak self] model in
            if let self { model.decideHeld(self.selectedHeld, decision: .include) }
        }
        // Unmapping also covers leaving the Account tab and native destruction.
        GTK.onSignal(password, "unmap") { [weak self] in
            guard let self else { return }
            mp_entry_set_text(self.password, "")
            self.model?.clearPasswordInput()
        }
        groups.onBusyChange = { [weak self] in self?.render() }
        render()
    }

    deinit {
        if let observer { model?.removeObserver(observer) }
        model?.clearPasswordInput()
    }

    func show() {
        guard !isDestroyed, !isShown else { return }
        isShown = true
        hasRenderedConnection = false
        model = makeModel()
        observer = model?.addObserver { [weak self] _ in
            guard let self, self.isShown, !self.isDestroyed else { return }
            self.render()
        }
        groups.show()
        render()
    }

    /// Account work finishes independently; detached observers cannot touch GTK.
    func retire(_ reason: Retirement) {
        guard !isDestroyed else { return }
        groups.retire(reason)
        isShown = false
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model?.clearPasswordInput()
        model = nil
        pendingIntent = nil
        selectedHeld.removeAll()
        passwordInputReset = nil
        if reason == .destroyed {
            isDestroyed = true
            return
        }
        releaseFormFocus()
        mp_entry_set_text(password, "")
        render()
    }

    private var canOperate: Bool {
        isShown && !isDestroyed && pendingIntent == nil && model?.state.isBusy == false && !groups.isBusy
    }

    private func render() {
        guard !isDestroyed else { return }
        let state = model?.state
        groups.updateAccount(state, pendingIntent: pendingIntent)
        let canOperate = canOperate
        if !canOperate { releaseFormFocus() }
        gtk_widget_set_sensitive(form, canOperate ? 1 : 0)
        if let state, !state.isBusy,
           !hasRenderedConnection || renderedConnection != state.connection {
            selectedHeld.removeAll()
            renderedHeld = []
            mp_entry_set_text(password, "")
            hasRenderedConnection = true
            renderedConnection = state.connection
            mp_entry_set_text(server, state.connection?.serverURL.absoluteString ?? "")
            mp_entry_set_text(username, state.connection?.username ?? "")
            mp_entry_set_text(deviceName, state.connection?.deviceName ?? LinuxAccountSettingsStrings.defaultDeviceName)
        }
        if state == nil || passwordInputReset != state?.passwordInputReset {
            passwordInputReset = state?.passwordInputReset
            mp_entry_set_text(password, "")
        }
        setMessage(connection, state?.connection.map {
            LinuxAccountSettingsStrings.connection($0, enabled: state?.enabled == true)
        } ?? (state == nil ? LinuxAccountSettingsStrings.unavailable : LinuxAccountSettingsStrings.signedOut))
        setMessage(storage, state?.secretStorageMessage)
        setMessage(progress, state?.operation.map(LinuxAccountSettingsStrings.progress)
            ?? (groups.isBusy ? LinuxGroupManagementStrings.busyAccount : nil))
        setMessage(error, state?.error?.message)
        setMessage(cleanup, state.flatMap { LinuxAccountSettingsStrings.cleanup($0.cleanup) })
        let conflicts = state?.reservedFolders ?? []
        setMessage(reserved, conflicts.isEmpty ? nil : LinuxAccountSettingsStrings.reservedFolders
            + "\n" + conflicts.map(\.string).joined(separator: "\n"))
        renderDevices(state?.devices ?? [])
        renderHeld(state?.heldPrompts ?? [], keptLocal: state?.keptLocal ?? [])
        gtk_widget_set_sensitive(signIn, canOperate ? 1 : 0)
        gtk_widget_set_sensitive(refresh, canOperate ? 1 : 0)
        gtk_widget_set_sensitive(signOut, canOperate && state?.connection != nil ? 1 : 0)
        for (device, button) in zip(renderedDevices, deviceButtons) {
            gtk_widget_set_sensitive(button, canOperate && state?.enabled == true && device.revokedAt == nil ? 1 : 0)
        }
        let canDecide = canOperate && state?.enabled == true && !selectedHeld.isEmpty
        gtk_widget_set_sensitive(keepLocal, canDecide ? 1 : 0)
        gtk_widget_set_sensitive(include, canDecide ? 1 : 0)
        gtk_widget_set_sensitive(heldRows, canOperate && state?.enabled == true ? 1 : 0)
    }

    private func renderDevices(_ rows: [SyncAPI.Device]) {
        guard rows != renderedDevices else { return }
        renderedDevices = rows
        deviceButtons.removeAll()
        while let child = gtk_widget_get_first_child(devices) { gtk_box_remove(mp_box(devices), child) }
        for device in rows {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            gtk_box_append(mp_box(devices), row)
            let label = GTK.label(LinuxAccountSettingsStrings.device(device))
            gtk_widget_set_hexpand(label, 1)
            gtk_box_append(mp_box(row), label)
            let revoke = button("revoke-" + device.id,
                title: device.isCurrent ? LinuxAccountSettingsStrings.revokeCurrent : LinuxAccountSettingsStrings.revoke,
                in: row) { model in
                    if let id = ULID(device.id) { model.revokeDevice(id) }
                }
            deviceButtons.append(revoke)
        }
    }

    private func renderHeld(_ rows: [AccountHeldPrompt], keptLocal: Set<PromptIdentity>) {
        gtk_widget_set_visible(heldSection, rows.isEmpty ? 0 : 1)
        guard rows != renderedHeld || keptLocal != renderedKeptLocal else { return }
        renderedHeld = rows
        renderedKeptLocal = keptLocal
        selectedHeld.formIntersection(Set(rows.map(\.identity)))
        while let child = gtk_widget_get_first_child(heldRows) { gtk_box_remove(mp_box(heldRows), child) }
        for (index, prompt) in rows.enumerated() {
            let title = LinuxAccountSettingsStrings.held(prompt, keptLocal: keptLocal.contains(prompt.identity))
            let check = gtk_check_button_new_with_label(title)!
            gtk_widget_set_name(check, "settings-account-held-\(index)")
            mp_accessible_label(check, title)
            gtk_check_button_set_active(mp_check_button(check), selectedHeld.contains(prompt.identity) ? 1 : 0)
            gtk_box_append(mp_box(heldRows), check)
            GTK.onSignal(check, "toggled") { [weak self] in
                guard let self, self.canOperate else { return }
                if gtk_check_button_get_active(mp_check_button(check)) != 0 { self.selectedHeld.insert(prompt.identity) }
                else { self.selectedHeld.remove(prompt.identity) }
                self.render()
            }
        }
    }

    private func button(_ name: String, title: String, in box: GTK.Widget,
                        intent: @escaping (AccountModel) -> Void) -> GTK.Widget {
        let button = GTK.button(title) { [weak self] in
            guard let self, self.canOperate, let model = self.model else { return }
            let request = UUID()
            self.pendingIntent = request
            intent(model)
            self.render()
            // Admission is queued before this idle; a no-op need not publish.
            GTK.onMainLoop { [weak self, weak model] in
                guard let self, let model, self.model === model,
                      self.pendingIntent == request else { return }
                self.pendingIntent = nil
                self.render()
            }
        }
        gtk_widget_set_name(button, "settings-account-" + name)
        mp_accessible_label(button, title)
        gtk_box_append(mp_box(box), button)
        return button
    }

    private func releaseFormFocus() {
        if let root = gtk_widget_get_root(form), let focus = gtk_root_get_focus(root),
           gtk_widget_is_ancestor(focus, form) != 0 { gtk_root_set_focus(root, nil) }
    }

    private func setMessage(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }

    private static func label(_ name: String, in box: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, "settings-account-" + name)
        gtk_box_append(mp_box(box), label)
        return label
    }

    private static func entry(_ name: String, title: String, in box: GTK.Widget) -> GTK.Widget {
        gtk_box_append(mp_box(box), GTK.label(title))
        let entry = gtk_entry_new()!
        gtk_widget_set_name(entry, "settings-account-" + name)
        mp_accessible_label(entry, title)
        gtk_box_append(mp_box(box), entry)
        return entry
    }
}
#endif
