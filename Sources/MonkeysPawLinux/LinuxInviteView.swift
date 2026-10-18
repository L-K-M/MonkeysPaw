#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// One staged invite, bound to the active Account graph. No URI is rendered.
final class LinuxInviteView {
    private enum EntryKind { case text, password }
    let widget: GTK.Widget
    private let makeModel: () -> InviteModel?
    private var model: InviteModel?
    private weak var account: AccountModel?
    private var observer: UUID?
    private var accountObserver: UUID?
    private var connection: AccountConnection?
    private var pending: UUID?
    private var inputReset: UUID?
    private var isShown = false
    private var isDestroyed = false
    private var refreshedAcceptance = false
    private let input: GTK.Widget
    private let server: GTK.Widget
    private let destination: GTK.Widget
    private let warning: GTK.Widget
    private let message: GTK.Widget
    private let registration: GTK.Widget
    private let username: GTK.Widget
    private let password: GTK.Widget
    private let device: GTK.Widget
    private var stageButton: GTK.Widget!
    private var joinButton: GTK.Widget!
    private var registerButton: GTK.Widget!

    init(makeModel: @escaping () -> InviteModel?) {
        self.makeModel = makeModel
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_name(widget, "settings-invite")
        gtk_box_append(mp_box(widget), GTK.label(LinuxInviteStrings.title))
        gtk_box_append(mp_box(widget), GTK.label(LinuxInviteStrings.explicitAccept))
        input = Self.entry("input", title: LinuxInviteStrings.input, kind: .password, in: widget)
        server = Self.entry("server", title: LinuxInviteStrings.server, in: widget)
        destination = Self.label("destination", in: widget)
        warning = Self.label("warning", in: widget)
        message = Self.label("message", in: widget)
        registration = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(widget), registration)
        username = Self.entry("username", title: LinuxInviteStrings.username, in: registration)
        password = Self.entry("password", title: LinuxInviteStrings.password, kind: .password, in: registration)
        device = Self.entry("device", title: LinuxInviteStrings.device, in: registration)
        mp_entry_set_text(device, LinuxInviteStrings.defaultDevice)
        stageButton = button("stage", title: LinuxInviteStrings.stage, in: widget) { [weak self] model in
            guard let self else { return }
            var text = String(cString: mp_entry_text(self.input))
            mp_entry_set_text(self.input, "")
            model.stage(&text, server: String(cString: mp_entry_text(self.server)))
        }
        joinButton = button("join", title: LinuxInviteStrings.join, in: widget) { model in
            var password = ""
            model.accept(as: .existingAccount, password: &password)
        }
        registerButton = button("register", title: LinuxInviteStrings.register, in: registration) { [weak self] model in
            guard let self else { return }
            var supplied = String(cString: mp_entry_text(self.password))
            mp_entry_set_text(self.password, "")
            model.accept(as: .newAccount, username: String(cString: mp_entry_text(self.username)),
                password: &supplied, deviceName: String(cString: mp_entry_text(self.device)))
        }
        gtk_box_reorder_child_after(mp_box(widget), stageButton, server)
        gtk_box_reorder_child_after(mp_box(widget), joinButton, message)
        GTK.onSignal(widget, "unmap") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            self.clearInputs()
        }
        render()
    }

    deinit {
        if let observer { model?.removeObserver(observer) }
        if let accountObserver { account?.removeObserver(accountObserver) }
        model?.dismiss()
    }

    func show(account: AccountModel?) {
        guard !isDestroyed, !isShown else { return }
        isShown = true
        self.account = account
        connection = account?.state.connection
        model = makeModel()
        observer = model?.addObserver { [weak self] state in
            guard let self, self.isShown, !self.isDestroyed else { return }
            if state.accepted, !self.refreshedAcceptance {
                self.refreshedAcceptance = true
                self.account?.refresh()
            }
            self.render()
        }
        accountObserver = account?.addObserver { [weak self] state in
            guard let self, self.isShown, !self.isDestroyed else { return }
            if !state.isBusy, self.connection != state.connection {
                self.connection = state.connection
                self.clearInputs()
                if self.model?.state.accepted != true { self.model?.dismiss() }
            }
            self.render()
        }
        render()
    }

    func stage(_ supplied: inout String) {
        defer { supplied = "" }
        guard isShown, !isDestroyed, let model else { return }
        refreshedAcceptance = false
        clearInputs()
        model.stage(&supplied)
    }

    func retire(_ reason: LinuxAccountSettingsPage.Retirement) {
        guard !isDestroyed else { return }
        isShown = false
        if let observer { model?.removeObserver(observer) }
        if let accountObserver { account?.removeObserver(accountObserver) }
        observer = nil
        accountObserver = nil
        model?.dismiss()
        model = nil
        account = nil
        pending = nil
        inputReset = nil
        refreshedAcceptance = false
        if reason != .destroyed { clearInputs() }
        isDestroyed = reason == .destroyed
        render()
    }

    private var canOperate: Bool {
        isShown && !isDestroyed && pending == nil && model?.state.isBusy == false && account?.state.isBusy != true
    }

    private func render() {
        guard !isDestroyed else { return }
        let state = model?.state
        if !canOperate { releaseFocus() }
        if inputReset != state?.inputReset {
            inputReset = state?.inputReset
            mp_entry_set_text(input, "")
            mp_entry_set_text(password, "")
        }
        gtk_label_set_text(mp_label(destination), state?.destination.map(LinuxInviteStrings.destination) ?? "")
        gtk_label_set_text(mp_label(warning), state?.destination?.usesHTTP == true ? LinuxInviteStrings.http : "")
        let status = state?.error?.message ?? (state?.accepted == true ? LinuxInviteStrings.accepted
            : state?.isBusy == true ? LinuxInviteStrings.busy : model == nil ? LinuxInviteStrings.unavailable : "")
        gtk_label_set_text(mp_label(message), status + (state?.cleanup.isComplete == false ? "\n" + LinuxInviteStrings.cleanup : ""))
        for control in [input, server, stageButton!] { gtk_widget_set_sensitive(control, canOperate ? 1 : 0) }
        let canAccept = canOperate && state?.canAccept == true
        gtk_widget_set_sensitive(joinButton, canAccept && state?.destination?.canJoin == true ? 1 : 0)
        gtk_widget_set_sensitive(registration, canAccept ? 1 : 0)
    }

    private func clearInputs() {
        releaseFocus()
        for control in [input, server, username, password] { mp_entry_set_text(control, "") }
        mp_entry_set_text(device, LinuxInviteStrings.defaultDevice)
    }

    private func releaseFocus() {
        if let root = gtk_widget_get_root(widget), let focus = gtk_root_get_focus(root),
           gtk_widget_is_ancestor(focus, widget) != 0 { gtk_root_set_focus(root, nil) }
    }

    private func button(_ name: String, title: String, in box: GTK.Widget,
                        intent: @escaping (InviteModel) -> Void) -> GTK.Widget {
        let control = GTK.button(title) { [weak self] in
            guard let self, self.canOperate, let model = self.model else { return }
            let request = UUID()
            self.pending = request
            self.refreshedAcceptance = false
            intent(model)
            self.render()
            GTK.onMainLoop { [weak self, weak model] in
                guard let self, let model, self.model === model, self.pending == request else { return }
                self.pending = nil
                self.render()
            }
        }
        gtk_widget_set_name(control, "settings-invite-" + name)
        mp_accessible_label(control, title)
        gtk_box_append(mp_box(box), control)
        return control
    }

    private static func label(_ name: String, in box: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, "settings-invite-" + name)
        gtk_box_append(mp_box(box), label)
        return label
    }

    private static func entry(_ name: String, title: String, kind: EntryKind = .text, in box: GTK.Widget) -> GTK.Widget {
        gtk_box_append(mp_box(box), GTK.label(title))
        let control = kind == .password ? gtk_password_entry_new()! : gtk_entry_new()!
        gtk_widget_set_name(control, "settings-invite-" + name)
        mp_accessible_label(control, title)
        gtk_box_append(mp_box(box), control)
        return control
    }
}
#endif
