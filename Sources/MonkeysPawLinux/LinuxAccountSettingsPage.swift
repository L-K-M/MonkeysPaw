#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Borrows GTK widgets and the active library's shared Account model.
final class LinuxAccountSettingsPage {
    enum Retirement { case hidden, destroyed }
    let widget: GTK.Widget
    private let makeModel: () -> AccountModel?
    private let accountStartupPending: () -> Bool
    private let startupIntent = UUID()
    private let invite: LinuxInviteView
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

    init(makeModel: @escaping () -> AccountModel?, makeInvite: @escaping () -> InviteModel? = { nil },
         makeGroups: @escaping () -> GroupManagementModel? = { nil },
         accountStartupPending: @escaping () -> Bool = { false }) {
        self.makeModel = makeModel
        self.accountStartupPending = accountStartupPending
        invite = LinuxInviteView(makeModel: makeInvite)
        groups = LinuxGroupManagementView(makeModel: makeGroups)
        let (scroll, column) = LinuxSettingsLayout.page(named: "settings-account-page")
        widget = scroll
        let connectionGroup = LinuxSettingsLayout.group(LinuxSettingsStrings.connection, in: column)
        connection = Self.status("connection", in: connectionGroup)
        storage = Self.caption("storage", in: connectionGroup)
        form = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        gtk_box_append(mp_box(connectionGroup), form)
        let formList = LinuxSettingsLayout.list(in: form)
        server = Self.entryRow("server", title: LinuxAccountSettingsStrings.server, in: formList)
        username = Self.entryRow("username", title: LinuxAccountSettingsStrings.username, in: formList)
        let passwordRow = LinuxSettingsLayout.row(in: formList)
        LinuxSettingsLayout.rowText(LinuxAccountSettingsStrings.password, in: passwordRow)
        password = gtk_password_entry_new()!
        gtk_widget_set_name(password, "settings-account-password")
        mp_accessible_label(password, LinuxAccountSettingsStrings.password)
        gtk_widget_set_hexpand(password, 1)
        gtk_widget_set_valign(password, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(passwordRow), password)
        deviceName = Self.entryRow("device-name", title: LinuxAccountSettingsStrings.deviceName, in: formList)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(connectionGroup), actions)
        progress = Self.caption("progress", in: connectionGroup)
        error = Self.caption("error", in: connectionGroup)
        cleanup = Self.caption("cleanup", in: connectionGroup)
        for label in [error, cleanup] { gtk_widget_add_css_class(label, "error") }
        reserved = Self.caption("reserved", in: connectionGroup)
        let devicesGroup = LinuxSettingsLayout.group(LinuxAccountSettingsStrings.devices, in: column)
        devices = gtk_list_box_new()!
        gtk_widget_set_name(devices, "settings-account-devices")
        gtk_widget_add_css_class(devices, "boxed-list")
        gtk_list_box_set_selection_mode(mp_list_box(devices), GTK_SELECTION_NONE)
        gtk_box_append(mp_box(devicesGroup), devices)
        heldSection = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        gtk_box_append(mp_box(column), heldSection)
        let heldHeading = GTK.label(LinuxAccountSettingsStrings.heldFiles)
        gtk_widget_add_css_class(heldHeading, "heading")
        gtk_box_append(mp_box(heldSection), heldHeading)
        LinuxSettingsLayout.caption(LinuxAccountSettingsStrings.heldGuidance, in: heldSection)
        heldRows = gtk_list_box_new()!
        gtk_widget_add_css_class(heldRows, "boxed-list")
        gtk_list_box_set_selection_mode(mp_list_box(heldRows), GTK_SELECTION_NONE)
        gtk_box_append(mp_box(heldSection), heldRows)
        let heldActions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(heldSection), heldActions)
        gtk_box_append(mp_box(column), invite.widget)
        gtk_box_append(mp_box(column), groups.widget)

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

    func stageInvite(_ input: inout String) {
        show()
        invite.stage(&input)
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
        invite.show(account: model)
    }

    /// Account work finishes independently; detached observers cannot touch GTK.
    func retire(_ reason: Retirement) {
        guard !isDestroyed else { return }
        invite.retire(reason)
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

    func refreshStartup() { render() }

    private var canOperate: Bool {
        isShown && !isDestroyed && pendingIntent == nil && !accountStartupPending()
            && model?.state.isBusy == false && !groups.isBusy
    }

    private func render() {
        guard !isDestroyed else { return }
        let state = model?.state
        groups.updateAccount(state, pendingIntent: pendingIntent ?? (accountStartupPending() ? startupIntent : nil))
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
        while let child = gtk_widget_get_first_child(devices) { gtk_list_box_remove(mp_list_box(devices), child) }
        for device in rows {
            let row = LinuxSettingsLayout.row(in: devices)
            let text = LinuxSettingsLayout.rowText(in: row)
            LinuxSettingsLayout.label(LinuxAccountSettingsStrings.device(device), in: text)
            let revoke = button("revoke-" + device.id,
                title: device.isCurrent ? LinuxAccountSettingsStrings.revokeCurrent : LinuxAccountSettingsStrings.revoke,
                in: row) { model in
                    if let id = ULID(device.id) { model.revokeDevice(id) }
                }
            gtk_widget_set_valign(revoke, GTK_ALIGN_CENTER)
            deviceButtons.append(revoke)
        }
    }

    private func renderHeld(_ rows: [AccountHeldPrompt], keptLocal: Set<PromptIdentity>) {
        gtk_widget_set_visible(heldSection, rows.isEmpty ? 0 : 1)
        guard rows != renderedHeld || keptLocal != renderedKeptLocal else { return }
        renderedHeld = rows
        renderedKeptLocal = keptLocal
        selectedHeld.formIntersection(Set(rows.map(\.identity)))
        while let child = gtk_widget_get_first_child(heldRows) { gtk_list_box_remove(mp_list_box(heldRows), child) }
        for (index, prompt) in rows.enumerated() {
            let title = LinuxAccountSettingsStrings.held(prompt, keptLocal: keptLocal.contains(prompt.identity))
            let check = gtk_check_button_new_with_label(title)!
            gtk_widget_set_name(check, "settings-account-held-\(index)")
            mp_accessible_label(check, title)
            gtk_check_button_set_active(mp_check_button(check), selectedHeld.contains(prompt.identity) ? 1 : 0)
            gtk_list_box_append(mp_list_box(heldRows), check)
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

    private static func status(_ name: String, in box: GTK.Widget) -> GTK.Widget {
        LinuxSettingsLayout.label("", name: "settings-account-" + name, in: box)
    }

    private static func caption(_ name: String, in box: GTK.Widget) -> GTK.Widget {
        LinuxSettingsLayout.caption(name: "settings-account-" + name, in: box)
    }

    private static func entryRow(_ name: String, title: String, in list: GTK.Widget) -> GTK.Widget {
        let row = LinuxSettingsLayout.row(in: list)
        LinuxSettingsLayout.rowText(title, in: row)
        let entry = gtk_entry_new()!
        gtk_widget_set_name(entry, "settings-account-" + name)
        mp_accessible_label(entry, title)
        gtk_widget_set_hexpand(entry, 1)
        gtk_widget_set_valign(entry, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(row), entry)
        return entry
    }
}
#endif
