#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Account's group section only renders presentation state and forwards intents.
final class LinuxGroupManagementView {
    private enum IntentKind { case refresh, change }
    let widget: GTK.Widget
    var onBusyChange: (() -> Void)?
    private let makeModel: () -> GroupManagementModel?
    private var model: GroupManagementModel?
    private var observer: UUID?
    private var isShown = false
    private var isDestroyed = false
    private var account: AccountState?
    private var accountIntentPending = false
    private var renderedBusy = false
    private var pendingIntent: UUID?
    private var needsRefresh = false
    private var inputReset: UUID?
    private var mayDisplayInvite = false
    private var confirmingGroup: SyncAPI.GroupMembership?
    private var renderedGroups: [SyncAPI.GroupMembership] = []
    private var groupButtons: [GTK.Widget] = []
    private var renderedMembers: [SyncAPI.Member] = []
    private var memberInputReset: UUID?
    private var memberWidgets: [(controls: GTK.Widget, role: GTK.Widget, set: GTK.Widget, remove: GTK.Widget)] = []
    private var managementVisible = false
    private var renderedName = ""

    private let message: GTK.Widget
    private let progress: GTK.Widget
    private let error: GTK.Widget
    private let confirmed: GTK.Widget
    private let groups: GTK.Widget
    private let groupID: GTK.Widget
    private let createForm: GTK.Widget
    private let createName: GTK.Widget
    private let management: GTK.Widget
    private let name: GTK.Widget
    private let confirmation: GTK.Widget
    private let members: GTK.Widget
    private let memberForm: GTK.Widget
    private let userID: GTK.Widget
    private let memberRole: GTK.Widget
    private let readOnly: GTK.Widget
    private let inviteRole: GTK.Widget
    private let invite: GTK.Widget
    private let inviteExpiry: GTK.Widget
    private var refresh: GTK.Widget!
    private var create: GTK.Widget!
    private var rename: GTK.Widget!
    private var delete: GTK.Widget!
    private var cancelDelete: GTK.Widget!
    private var confirmDelete: GTK.Widget!
    private var setRole: GTK.Widget!
    private var createInvite: GTK.Widget!
    private var copyInvite: GTK.Widget!

    init(makeModel: @escaping () -> GroupManagementModel?) {
        self.makeModel = makeModel
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_name(widget, "settings-groups")
        gtk_box_append(mp_box(widget), GTK.label(LinuxGroupManagementStrings.groups))
        message = Self.label("message", in: widget)
        progress = Self.label("progress", in: widget)
        error = Self.label("error", in: widget)
        gtk_widget_add_css_class(error, "error")
        confirmed = Self.label("confirmed", in: widget)
        groups = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(widget), groups)
        groupID = Self.label("id", in: widget)
        gtk_label_set_selectable(mp_label(groupID), 1)
        createForm = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(widget), createForm)
        createName = Self.entry("create-name", title: LinuxGroupManagementStrings.createName, in: createForm)
        management = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(widget), management)
        name = Self.entry("name", title: LinuxGroupManagementStrings.name, in: management)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(management), actions)
        confirmation = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_name(confirmation, "settings-groups-delete-confirmation")
        gtk_box_append(mp_box(confirmation), GTK.label(LinuxGroupManagementStrings.deleteWarning))
        gtk_box_append(mp_box(management), confirmation)
        let confirmationActions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(confirmation), confirmationActions)
        readOnly = Self.label("read-only", in: widget)
        gtk_box_append(mp_box(widget), GTK.label(LinuxGroupManagementStrings.members))
        members = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_name(members, "settings-groups-members")
        gtk_box_append(mp_box(widget), members)
        memberForm = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(widget), memberForm)
        gtk_box_append(mp_box(memberForm), GTK.label(LinuxGroupManagementStrings.userIDGuidance))
        userID = Self.entry("user-id", title: LinuxGroupManagementStrings.userID, in: memberForm)
        memberRole = Self.roles("member-role", title: LinuxGroupManagementStrings.role, in: memberForm,
            roles: [.viewer, .editor, .owner], selected: .editor)
        let inviteForm = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(management), inviteForm)
        inviteRole = Self.roles("invite-role", title: LinuxGroupManagementStrings.inviteRole, in: inviteForm,
            roles: [.viewer, .editor], selected: .viewer)
        invite = Self.label("invite-link", in: inviteForm)
        gtk_label_set_wrap_mode(mp_label(invite), PANGO_WRAP_WORD_CHAR)
        inviteExpiry = Self.label("invite-expiry", in: inviteForm)

        refresh = button("refresh", title: LinuxGroupManagementStrings.refresh, in: widget, kind: .refresh) { $0.refresh() }
        create = button("create", title: LinuxGroupManagementStrings.create, in: createForm,
            allowed: { $0.canCreate }) { [weak self] model in
                if let self { model.create(name: self.text(self.createName)) }
            }
        rename = button("rename", title: LinuxGroupManagementStrings.rename, in: actions,
            allowed: { $0.canManage }) { [weak self] model in
                if let self { model.rename(name: self.text(self.name)) }
            }
        delete = GTK.button(LinuxGroupManagementStrings.delete) { [weak self] in self?.requestDelete() }
        Self.identify(delete, "delete", title: LinuxGroupManagementStrings.delete)
        gtk_box_append(mp_box(actions), delete)
        cancelDelete = GTK.button(LinuxGroupManagementStrings.cancel) { [weak self] in
            guard let self, self.isShown, !self.isDestroyed else { return }
            self.confirmingGroup = nil
            self.render()
            gtk_widget_grab_focus(self.delete)
        }
        Self.identify(cancelDelete, "cancel-delete", title: LinuxGroupManagementStrings.cancel)
        gtk_box_append(mp_box(confirmationActions), cancelDelete)
        confirmDelete = button("confirm-delete", title: LinuxGroupManagementStrings.confirmDelete, in: confirmationActions,
            allowed: { $0.canManage }) { [weak self] model in
                guard let self, self.confirmingGroup == model.state.selectedGroup else { return }
                self.confirmingGroup = nil
                model.deleteGroup()
            }
        gtk_widget_add_css_class(confirmDelete, "destructive-action")
        setRole = button("set-role", title: LinuxGroupManagementStrings.setRole, in: memberForm,
            allowed: { $0.canManage }) { [weak self] model in
                guard let self, let role = self.selectedRole(self.memberRole) else { return }
                model.setRole(userID: self.text(self.userID), role: role)
            }
        for entry in [userID, memberRole] {
            GTK.onSignal(entry, "changed") { [weak self] in self?.renderPermissions() }
        }
        createInvite = button("create-invite", title: LinuxGroupManagementStrings.createInvite, in: inviteForm,
            allowed: { $0.canManage }) { [weak self] model in
                guard let self, let role = self.selectedRole(self.inviteRole),
                      let inviteRole = SyncAPI.InviteRole(rawValue: role.rawValue) else { return }
                self.mayDisplayInvite = true
                model.createInvite(role: inviteRole)
            }
        gtk_box_append(mp_box(inviteForm), GTK.label(LinuxGroupManagementStrings.inviteGuidance))
        copyInvite = button("copy-invite", title: LinuxGroupManagementStrings.copyInvite, in: inviteForm,
            allowed: { $0.canCopyInvite }) { [weak self] model in
                guard self?.mayDisplayInvite == true else { return }
                model.copyCreatedInvite()
            }
        render()
    }

    deinit {
        if let observer { model?.removeObserver(observer) }
        model?.dismiss()
    }

    func show() {
        guard !isDestroyed, !isShown else { return }
        isShown = true
        needsRefresh = true
        model = makeModel()
        observer = model?.addObserver { [weak self] _ in
            guard let self, self.isShown, !self.isDestroyed else { return }
            self.render()
        }
        render()
    }

    func updateAccount(_ state: AccountState?, pendingIntent: UUID?) {
        guard !isDestroyed else { return }
        let changed = account?.connection != state?.connection || account?.enabled != state?.enabled
        let completed = account?.isBusy == true && state?.isBusy == false
        account = state
        accountIntentPending = pendingIntent != nil
        if changed {
            mayDisplayInvite = false
            confirmingGroup = nil
            model?.dismiss()
        }
        if changed || completed { needsRefresh = true }
        render()
    }

    func retire(_ reason: LinuxAccountSettingsPage.Retirement) {
        guard !isDestroyed else { return }
        isShown = false
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model?.dismiss()
        model = nil
        account = nil
        accountIntentPending = false
        pendingIntent = nil
        needsRefresh = false
        mayDisplayInvite = false
        confirmingGroup = nil
        inputReset = nil
        if reason == .destroyed { isDestroyed = true; return }
        render()
    }

    private var isIdle: Bool {
        isShown && !isDestroyed && pendingIntent == nil && !accountIntentPending
            && account?.isBusy == false && model?.state.isBusy == false
    }

    var isBusy: Bool {
        isShown && model != nil && (needsRefresh || pendingIntent != nil || model?.state.isBusy == true)
    }

    private var canOperate: Bool {
        isIdle && account?.connection == model?.state.connection && account?.enabled == model?.state.enabled
    }

    private func render() {
        guard !isDestroyed else { return }
        let state = model?.state
        if inputReset != state?.inputReset || state == nil {
            inputReset = state?.inputReset
            confirmingGroup = nil
            mayDisplayInvite = false
            mp_entry_set_text(createName, "")
            mp_entry_set_text(userID, "")
            mp_entry_set_text(name, state?.selectedGroup?.name ?? "")
            gtk_combo_box_set_active_id(mp_combo_box(memberRole), SyncAPI.Role.editor.rawValue)
            gtk_combo_box_set_active_id(mp_combo_box(inviteRole), SyncAPI.Role.viewer.rawValue)
        } else if text(name) == renderedName {
            mp_entry_set_text(name, state?.selectedGroup?.name ?? "")
        }
        renderedName = state?.selectedGroup?.name ?? ""
        if state?.isBusy == false { managementVisible = state?.canManage == true }
        if state == nil { managementVisible = false }
        if confirmingGroup != state?.selectedGroup || !canOperate { confirmingGroup = nil }
        gtk_widget_set_visible(management, managementVisible ? 1 : 0)
        gtk_widget_set_visible(memberForm, managementVisible ? 1 : 0)
        gtk_widget_set_visible(confirmation, confirmingGroup == nil ? 0 : 1)
        setMessage(message, state?.enabled != true ? LinuxGroupManagementStrings.unavailable
            : (state?.groups.isEmpty == true ? LinuxGroupManagementStrings.noGroups
                : (state?.selectedGroup == nil ? LinuxGroupManagementStrings.selectGroup : nil)))
        setMessage(progress, state?.operation.map(LinuxGroupManagementStrings.progress))
        setMessage(error, state?.error?.message)
        setMessage(confirmed, state?.changeConfirmed == true ? LinuxGroupManagementStrings.confirmed : nil)
        setMessage(groupID, state?.selectedGroup.map(LinuxGroupManagementStrings.groupID))
        setMessage(readOnly, state?.selectedGroup != nil && !managementVisible ? LinuxGroupManagementStrings.readOnly : nil)
        renderGroups(state?.groups ?? [])
        renderMembers(state?.members ?? [])
        let created = mayDisplayInvite ? state?.createdInvite : nil
        setMessage(invite, created?.link)
        setMessage(inviteExpiry, created.map { LinuxGroupManagementStrings.expires($0.expiresAt) })
        renderPermissions()
        if needsRefresh, isIdle {
            needsRefresh = false
            perform { $0.refresh() }
        }
        if renderedBusy != isBusy {
            renderedBusy = isBusy
            onBusyChange?()
        }
    }

    private func renderPermissions() {
        guard !isDestroyed, refresh != nil else { return }
        let state = model?.state
        let canManage = canOperate && state?.canManage == true
        if !canOperate, let root = gtk_widget_get_root(widget), let focus = gtk_root_get_focus(root),
           gtk_widget_is_ancestor(focus, widget) != 0 { gtk_root_set_focus(root, nil) }
        gtk_widget_set_sensitive(refresh, isIdle ? 1 : 0)
        gtk_widget_set_sensitive(createForm, canOperate && state?.canCreate == true ? 1 : 0)
        gtk_widget_set_sensitive(management, canManage ? 1 : 0)
        gtk_widget_set_sensitive(memberForm, canManage ? 1 : 0)
        let user = text(userID)
        let allowedRole = selectedRole(memberRole).map { state?.canSetRole(userID: user, role: $0) == true } == true
        gtk_widget_set_sensitive(setRole, canManage && allowedRole ? 1 : 0)
        gtk_widget_set_sensitive(copyInvite, canOperate && mayDisplayInvite && state?.canCopyInvite == true ? 1 : 0)
        for (group, button) in zip(renderedGroups, groupButtons) {
            gtk_widget_set_sensitive(button, isIdle ? 1 : 0)
            if group.groupID == state?.selectedGroupID?.rawValue { gtk_widget_add_css_class(button, "suggested-action") }
            else { gtk_widget_remove_css_class(button, "suggested-action") }
        }
        for (member, row) in zip(renderedMembers, memberWidgets) {
            gtk_widget_set_visible(row.controls, managementVisible ? 1 : 0)
            gtk_widget_set_sensitive(row.role, canManage ? 1 : 0)
            gtk_widget_set_sensitive(row.remove, canManage ? 1 : 0)
            let allowed = selectedRole(row.role).map { state?.canSetRole(userID: member.userID, role: $0) == true } == true
            gtk_widget_set_sensitive(row.set, canManage && allowed ? 1 : 0)
        }
    }

    private func renderGroups(_ rows: [SyncAPI.GroupMembership]) {
        guard rows != renderedGroups else { return }
        renderedGroups = rows
        groupButtons.removeAll()
        while let child = gtk_widget_get_first_child(groups) { gtk_box_remove(mp_box(groups), child) }
        for group in rows {
            let select = button("select-" + group.groupID, title: LinuxGroupManagementStrings.group(group), in: groups, kind: .refresh) { model in
                if let id = ULID(group.groupID) { model.selectGroup(id) }
            }
            groupButtons.append(select)
        }
    }

    private func renderMembers(_ rows: [SyncAPI.Member]) {
        guard rows != renderedMembers || memberInputReset != inputReset else { return }
        memberInputReset = inputReset
        renderedMembers = rows
        memberWidgets.removeAll()
        while let child = gtk_widget_get_first_child(members) { gtk_box_remove(mp_box(members), child) }
        for member in rows {
            let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
            gtk_box_append(mp_box(members), row)
            let label = Self.label("member-" + member.userID, in: row)
            gtk_label_set_text(mp_label(label), LinuxGroupManagementStrings.member(member))
            gtk_label_set_selectable(mp_label(label), 1)
            let controls = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
            gtk_box_append(mp_box(row), controls)
            let role = Self.roles("role-" + member.userID, title: LinuxGroupManagementStrings.role,
                in: controls, roles: [.viewer, .editor, .owner], selected: member.role)
            let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            gtk_box_append(mp_box(controls), actions)
            let set = button("set-role-" + member.userID, title: LinuxGroupManagementStrings.setRole, in: actions,
                allowed: { $0.canManage }) { [weak self] model in
                    if let value = self?.selectedRole(role) { model.setRole(userID: member.userID, role: value) }
                }
            let remove = button("remove-" + member.userID, title: LinuxGroupManagementStrings.remove, in: actions,
                allowed: { $0.canManage }) { $0.removeMember(userID: member.userID) }
            GTK.onSignal(role, "changed") { [weak self] in self?.renderPermissions() }
            memberWidgets.append((controls, role, set, remove))
        }
    }

    private func requestDelete() {
        guard canOperate, let state = model?.state, state.canManage else { return }
        confirmingGroup = state.selectedGroup
        render()
        gtk_widget_grab_focus(cancelDelete)
    }

    private func button(_ name: String, title: String, in box: GTK.Widget,
                        kind: IntentKind = .change,
                        allowed: @escaping (GroupManagementState) -> Bool = { _ in true },
                        intent: @escaping (GroupManagementModel) -> Void) -> GTK.Widget {
        let button = GTK.button(title) { [weak self] in
            guard let self, self.isIdle, let state = self.model?.state, allowed(state) else { return }
            // Refresh/selection may adopt an account change; mutations still
            // require the Account and group projections to agree.
            guard kind == .refresh || self.canOperate else { return }
            self.perform(intent)
        }
        Self.identify(button, name, title: title)
        gtk_box_append(mp_box(box), button)
        return button
    }

    private func perform(_ intent: (GroupManagementModel) -> Void) {
        guard let model else { return }
        let request = UUID()
        pendingIntent = request
        intent(model)
        render()
        // A no-op need not publish. Release after queued model admission.
        GTK.onMainLoop { [weak self, weak model] in
            guard let self, self.isShown, !self.isDestroyed, let model,
                  self.model === model, self.pendingIntent == request else { return }
            self.pendingIntent = nil
            self.render()
        }
    }

    private func text(_ entry: GTK.Widget) -> String { String(cString: mp_entry_text(entry)) }
    private func selectedRole(_ combo: GTK.Widget) -> SyncAPI.Role? {
        gtk_combo_box_get_active_id(mp_combo_box(combo)).flatMap { SyncAPI.Role(rawValue: String(cString: $0)) }
    }
    private func setMessage(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }
    private static func identify(_ widget: GTK.Widget, _ name: String, title: String) {
        gtk_widget_set_name(widget, "settings-groups-" + name)
        mp_accessible_label(widget, title)
    }
    private static func label(_ name: String, in box: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, "settings-groups-" + name)
        gtk_box_append(mp_box(box), label)
        return label
    }
    private static func entry(_ name: String, title: String, in box: GTK.Widget) -> GTK.Widget {
        gtk_box_append(mp_box(box), GTK.label(title))
        let entry = gtk_entry_new()!
        identify(entry, name, title: title)
        gtk_box_append(mp_box(box), entry)
        return entry
    }
    private static func roles(_ name: String, title: String, in box: GTK.Widget,
                              roles: [SyncAPI.Role], selected: SyncAPI.Role) -> GTK.Widget {
        gtk_box_append(mp_box(box), GTK.label(title))
        let combo = gtk_combo_box_text_new()!
        identify(combo, name, title: title)
        for role in roles { gtk_combo_box_text_append(mp_combo_box_text(combo), role.rawValue, LinuxGroupManagementStrings.role(role)) }
        gtk_combo_box_set_active_id(mp_combo_box(combo), selected.rawValue)
        gtk_box_append(mp_box(box), combo)
        return combo
    }
}
#endif
