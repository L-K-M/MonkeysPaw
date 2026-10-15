import AppKit
import MonkeysPawCore
import SwiftUI

/// Borrows the active graph. Only native secure controls own typed bearer text.
final class InviteViewState: ObservableObject {
    @Published private(set) var state: InviteState? = nil
    @Published var server = ""
    @Published var username = ""
    @Published var deviceName = SettingsInviteStrings.defaultDevice
    @Published private(set) var inputReset = UUID()
    @Published private var pendingIntent: UUID? = nil
    @Published private var accountIsBusy = false
    let linkInput = AccountPasswordInput()
    let passwordInput = AccountPasswordInput()

    private let mainThread: MainThread
    private let makeModel: () -> InviteModel?
    private let makeAccount: () -> AccountModel?
    private var model: InviteModel?
    private var account: AccountModel?
    private var observer: UUID?
    private var accountObserver: UUID?
    private var connection: AccountConnection?
    private var hasRenderedAccount = false
    private var pendingLink: SecretValue?
    private var pendingStage: UUID?
    private var isShown = false

    init(mainThread: MainThread, makeModel: @escaping () -> InviteModel?, makeAccount: @escaping () -> AccountModel?) {
        self.mainThread = mainThread
        self.makeModel = makeModel
        self.makeAccount = makeAccount
    }

    deinit {
        let model = model, account = account
        let observer = observer, accountObserver = accountObserver
        let link = linkInput, password = passwordInput
        mainThread.run {
            if let observer { model?.removeObserver(observer) }
            if let accountObserver { account?.removeObserver(accountObserver) }
            model?.dismiss()
            link.clear()
            password.clear()
        }
    }

    var canOperate: Bool { isShown && pendingIntent == nil && !accountIsBusy && model?.state.isBusy == false }
    var canAccept: Bool { canOperate && state?.canAccept == true }
    var canJoin: Bool { canAccept && state?.destination?.canJoin == true }

    func show() {
        isShown = true
        refreshBinding()
    }

    func hide() {
        isShown = false
        detach()
    }

    func refreshBinding() {
        guard isShown else { return }
        let nextAccount = makeAccount(), nextModel = makeModel()
        guard nextModel !== model || nextAccount !== account else { return }
        detach()
        model = nextModel
        account = nextAccount
        guard let nextModel else { return }
        observer = nextModel.addObserver { [weak self, weak nextModel] snapshot in
            guard let self, let nextModel, self.isShown, self.model === nextModel else { return }
            self.render(snapshot)
            self.stagePendingLink()
        }
        accountObserver = nextAccount?.addObserver { [weak self, weak nextAccount] snapshot in
            guard let self, let nextAccount, self.isShown, self.account === nextAccount else { return }
            self.renderAccount(snapshot)
        }
        render(nextModel.state)
        if let nextAccount { renderAccount(nextAccount.state) }
    }

    /// URL callbacks consume immediately, then wait for the initial Account
    /// snapshot/startup so its first connection publication cannot erase a link.
    func stage(_ supplied: inout String) {
        let link = SecretValue(supplied)
        supplied = ""
        guard hasCurrentBinding() else { return }
        clearInputs()
        pendingLink = link
        stagePendingLink()
    }

    func reviewInput() {
        var supplied = linkInput.consume()
        let server = server
        passwordInput.clear()
        perform { $0.stage(&supplied, server: server) }
    }

    func join() {
        passwordInput.clear()
        guard canJoin else { return }
        perform {
            var password = ""
            $0.accept(as: .existingAccount, password: &password)
        }
    }

    func register() {
        var supplied = passwordInput.consume()
        guard canAccept else { return }
        let username = username, deviceName = deviceName
        perform { $0.accept(as: .newAccount, username: username, password: &supplied, deviceName: deviceName) }
    }

    private func stagePendingLink() {
        guard isShown, !accountIsBusy, model?.state.isBusy == false,
              pendingLink != nil, pendingStage == nil else { return }
        let request = UUID()
        pendingStage = request
        // Finish the Account observer batch first: composition may admit its
        // startup from that same publication. Recheck after the UI hop.
        Task.detached { [mainThread, weak self] in
            mainThread.run { [weak self] in
                guard let self, self.pendingStage == request else { return }
                self.pendingStage = nil
                guard self.hasCurrentBinding(), self.isShown, self.account?.state.isBusy != true,
                      self.model?.state.isBusy == false, let link = self.pendingLink else { return }
                self.pendingLink = nil
                var supplied = link.withValue { $0 }
                self.model?.stage(&supplied)
            }
        }
    }

    private func perform(_ intent: (InviteModel) -> Void) {
        guard hasCurrentBinding(), canOperate, let model else { return }
        let request = UUID()
        pendingIntent = request
        pendingLink = nil
        intent(model)
        mainThread.run { [weak self, weak model] in
            guard let self, let model, self.model === model, self.pendingIntent == request else { return }
            self.pendingIntent = nil
        }
    }

    private func hasCurrentBinding() -> Bool {
        let previous = model
        refreshBinding()
        return previous != nil && previous === model
    }

    private func render(_ next: InviteState) {
        if state?.inputReset != next.inputReset {
            linkInput.clear()
            passwordInput.clear()
            inputReset = UUID()
        }
        state = next
    }

    private func renderAccount(_ next: AccountState) {
        accountIsBusy = next.isBusy
        guard !next.isBusy else { return }
        if hasRenderedAccount, connection != next.connection {
            pendingLink = nil
            clearInputs()
            if model?.state.accepted != true { model?.dismiss() }
        }
        hasRenderedAccount = true
        connection = next.connection
        stagePendingLink()
    }

    private func clearInputs() {
        linkInput.clear()
        passwordInput.clear()
        inputReset = UUID()
        server = ""
        username = ""
        deviceName = SettingsInviteStrings.defaultDevice
    }

    private func detach() {
        if let observer { model?.removeObserver(observer) }
        if let accountObserver { account?.removeObserver(accountObserver) }
        observer = nil
        accountObserver = nil
        model?.dismiss()
        model = nil
        account = nil
        pendingLink = nil
        pendingStage = nil
        pendingIntent = nil
        hasRenderedAccount = false
        connection = nil
        accountIsBusy = false
        clearInputs()
        state = nil
    }
}

struct SettingsInviteSecureField: NSViewRepresentable {
    let input: AccountPasswordInput
    let reset: UUID
    let isEditable: Bool
    let title: String
    let identifier: String

    func makeCoordinator() -> AccountPasswordInput { input }
    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField(frame: .zero)
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.setAccessibilityIdentifier(identifier)
        context.coordinator.update(field, reset: reset, isEditable: isEditable)
        return field
    }
    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.update(field, reset: reset, isEditable: isEditable)
    }
    static func dismantleNSView(_ field: NSSecureTextField, coordinator: AccountPasswordInput) {
        coordinator.detach(field)
    }
}

struct SettingsInviteView: View {
    @ObservedObject var presentation: InviteViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsInviteStrings.title).font(.headline)
            Text(SettingsInviteStrings.explicitAccept)
            SettingsInviteSecureField(input: presentation.linkInput, reset: presentation.inputReset,
                isEditable: presentation.canOperate, title: SettingsInviteStrings.input, identifier: "settings-invite-input")
                .frame(height: 24)
            TextField(SettingsInviteStrings.server, text: $presentation.server)
                .accessibilityLabel(SettingsInviteStrings.server)
                .disabled(!presentation.canOperate)
            Button(SettingsInviteStrings.stage, action: presentation.reviewInput).disabled(!presentation.canOperate)
            destination
            status
            Button(SettingsInviteStrings.join, action: presentation.join).disabled(!presentation.canJoin)
            registration
        }
    }

    @ViewBuilder private var destination: some View {
        if let destination = presentation.state?.destination {
            Text(SettingsInviteStrings.destination(destination)).textSelection(.enabled)
                .accessibilityIdentifier("settings-invite-destination")
            if destination.usesHTTP { Text(SettingsInviteStrings.http).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var status: some View {
        if let issue = presentation.state?.error { Text(issue.message).foregroundStyle(.red) }
        else if presentation.state?.accepted == true { Text(SettingsInviteStrings.accepted) }
        else if presentation.state?.isBusy == true { Text(SettingsInviteStrings.busy) }
        else if presentation.state == nil { Text(SettingsInviteStrings.unavailable) }
        if presentation.state?.cleanup.isComplete == false {
            Text(SettingsInviteStrings.cleanup).foregroundStyle(.red)
        }
    }

    private var registration: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(SettingsInviteStrings.username, text: $presentation.username)
                .accessibilityLabel(SettingsInviteStrings.username)
            SettingsInviteSecureField(input: presentation.passwordInput, reset: presentation.inputReset,
                isEditable: presentation.canAccept, title: SettingsInviteStrings.password, identifier: "settings-invite-password")
                .frame(height: 24)
            TextField(SettingsInviteStrings.device, text: $presentation.deviceName)
                .accessibilityLabel(SettingsInviteStrings.device)
            Button(SettingsInviteStrings.register, action: presentation.register)
        }
        .disabled(!presentation.canAccept)
    }
}
