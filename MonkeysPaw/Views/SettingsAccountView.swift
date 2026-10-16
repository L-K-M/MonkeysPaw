import AppKit
import MonkeysPawCore
import SwiftUI

/// Borrows the active graph's model. Password text stays in the native field.
final class AccountSettingsViewState: ObservableObject {
    @Published private(set) var state: AccountState? = nil
    @Published var server = ""
    @Published var username = ""
    @Published var deviceName = SettingsAccountStrings.defaultDeviceName
    @Published private(set) var selectedHeld: Set<PromptIdentity> = []
    @Published private(set) var passwordInputReset = UUID()
    @Published private var pendingIntent: UUID? = nil
    let passwordInput = AccountPasswordInput()
    let invites: InviteViewState
    let groups: GroupManagementViewState

    private let makeModel: () -> AccountModel?
    private let mainThread: MainThread
    private let onOpen: () -> Void
    private var model: AccountModel?
    private var observer: UUID?
    private var isShown = false
    private var hasRenderedConnection = false
    private var renderedConnection: AccountConnection?

    init(mainThread: MainThread, makeModel: @escaping () -> AccountModel?, onOpen: @escaping () -> Void = {},
         makeInvite: @escaping () -> InviteModel? = { nil },
         makeGroups: @escaping () -> GroupManagementModel? = { nil }) {
        self.mainThread = mainThread
        self.makeModel = makeModel
        self.onOpen = onOpen
        invites = InviteViewState(mainThread: mainThread, makeModel: makeInvite, makeAccount: makeModel)
        groups = GroupManagementViewState(mainThread: mainThread, makeModel: makeGroups)
        groups.onBusyChange = { [weak self] in self?.objectWillChange.send() }
    }

    deinit {
        let model = model
        let observer = observer
        let input = passwordInput
        mainThread.run {
            if let observer { model?.removeObserver(observer) }
            model?.clearPasswordInput()
            input.clear()
        }
    }

    var canOperate: Bool { isShown && pendingIntent == nil && model?.state.isBusy == false && !groups.isBusy }
    var canSignOut: Bool { canOperate && state?.connection != nil }
    var canSelectHeld: Bool { canOperate && state?.enabled == true }
    var canDecideHeld: Bool { canSelectHeld && !selectedHeld.isEmpty }
    var connectionMessage: String {
        guard let state else { return SettingsAccountStrings.unavailable }
        guard let connection = state.connection else { return SettingsAccountStrings.signedOut }
        return SettingsAccountStrings.connection(connection, enabled: state.enabled)
    }
    var cleanupMessage: String? { state.flatMap { SettingsAccountStrings.cleanup($0.cleanup) } }

    func show() {
        guard !isShown else { refreshBinding(); return }
        isShown = true
        refreshBinding()
        invites.show()
        onOpen()
    }

    func hide() {
        isShown = false
        invites.hide()
        groups.hide()
        detach()
    }

    /// General's existing publication follows both immediate and drained folder
    /// switches. Recheck identity without owning the graph's switch/drain policy.
    func refreshBinding() {
        guard isShown else { return }
        invites.refreshBinding()
        let next = makeModel()
        guard next !== model else { groups.refreshBinding(); return }
        groups.hide()
        detach()
        model = next
        guard let next else { return }
        observer = next.addObserver { [weak self, weak next] _ in
            guard let self, let next, self.isShown, self.model === next else { return }
            self.render(next.state)
        }
        render(next.state)
        groups.show()
    }

    func login() {
        // Consume even a rejected click before any queued model admission.
        var supplied = passwordInput.consume()
        let server = server
        let username = username
        let deviceName = deviceName
        perform { $0.login(server: server, username: username, password: &supplied, deviceName: deviceName) }
    }

    func refresh() { perform { $0.refresh() } }
    func signOut() {
        guard canSignOut else { return }
        perform { $0.signOut() }
    }

    func canRevoke(_ device: SyncAPI.Device) -> Bool {
        canOperate && state?.enabled == true && device.revokedAt == nil
    }

    func revoke(_ device: SyncAPI.Device) {
        guard canRevoke(device), let id = ULID(device.id) else { return }
        perform { $0.revokeDevice(id) }
    }

    func selectHeld(_ identity: PromptIdentity, selected: Bool) {
        guard hasCurrentBinding(), canSelectHeld,
              state?.heldPrompts.contains(where: { $0.identity == identity }) == true else { return }
        if selected { selectedHeld.insert(identity) }
        else { selectedHeld.remove(identity) }
    }

    func decideHeld(_ decision: AccountHeldDecision) {
        guard canDecideHeld else { return }
        let selected = selectedHeld
        perform { $0.decideHeld(selected, decision: decision) }
    }

    private func perform(_ intent: (AccountModel) -> Void) {
        guard hasCurrentBinding(), canOperate, let model else { return }
        let request = UUID()
        pendingIntent = request
        groups.updateAccount(state, pendingIntent: request)
        intent(model)
        // Admission precedes this release even with a queued MainThread port.
        // A repeated Keep local is a no-op and need not publish another state.
        mainThread.run { [weak self, weak model] in
            guard let self, let model, self.model === model, self.pendingIntent == request else { return }
            self.pendingIntent = nil
            self.groups.updateAccount(self.state, pendingIntent: nil)
        }
    }

    private func hasCurrentBinding() -> Bool {
        let previous = model
        refreshBinding()
        // Rebinding refreshes the UI, but never transfers a stale click or
        // held-file selection to a different library/account graph.
        return previous != nil && previous === model
    }

    private func render(_ next: AccountState) {
        if !next.isBusy, !hasRenderedConnection || renderedConnection != next.connection {
            hasRenderedConnection = true
            renderedConnection = next.connection
            selectedHeld.removeAll()
            passwordInput.clear()
            server = next.connection?.serverURL.absoluteString ?? ""
            username = next.connection?.username ?? ""
            deviceName = next.connection?.deviceName ?? SettingsAccountStrings.defaultDeviceName
        }
        if state?.passwordInputReset != next.passwordInputReset {
            passwordInput.clear()
            passwordInputReset = UUID()
        }
        selectedHeld.formIntersection(Set(next.heldPrompts.map(\.identity)))
        state = next
        groups.updateAccount(next, pendingIntent: pendingIntent)
    }

    private func detach() {
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model?.clearPasswordInput()
        model = nil
        pendingIntent = nil
        hasRenderedConnection = false
        renderedConnection = nil
        selectedHeld.removeAll()
        passwordInput.clear()
        passwordInputReset = UUID()
        server = ""
        username = ""
        deviceName = SettingsAccountStrings.defaultDeviceName
        state = nil
    }
}

/// Like Assistant's secure control, updates can only clear native text. No
/// persisted credential or password draft can be assigned back to this field.
struct SettingsAccountPasswordField: NSViewRepresentable {
    let input: AccountPasswordInput
    let reset: UUID
    let isEditable: Bool

    func makeCoordinator() -> AccountPasswordInput { input }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField(frame: .zero)
        field.placeholderString = SettingsAccountStrings.password
        field.setAccessibilityLabel(SettingsAccountStrings.password)
        field.setAccessibilityIdentifier("settings-account-password")
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

final class AccountPasswordInput {
    private weak var field: NSSecureTextField?
    private var reset: UUID?

    func update(_ field: NSSecureTextField, reset: UUID, isEditable: Bool) {
        if self.field !== field {
            clear()
            self.field = field
            self.reset = nil
        }
        field.isEnabled = isEditable
        guard self.reset != reset else { return }
        self.reset = reset
        clear()
    }

    func consume() -> String {
        let supplied = field?.currentEditor()?.string ?? field?.stringValue ?? ""
        clear()
        return supplied
    }

    func clear() {
        field?.stringValue = ""
        field?.currentEditor()?.string = ""
    }

    func detach(_ field: NSSecureTextField) {
        field.stringValue = ""
        field.currentEditor()?.string = ""
        if self.field === field { self.field = nil; reset = nil }
    }
}

struct SettingsAccountView: View {
    @ObservedObject var presentation: AccountSettingsViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(presentation.connectionMessage).textSelection(.enabled)
                if let state = presentation.state { Text(state.secretStorageMessage) }
                loginForm
                status
                reservedFolders
                devices
                heldFiles
                Divider()
                SettingsInviteView(presentation: presentation.invites)
                Divider()
                if presentation.groups.isBusy { Text(GroupManagementStrings.busyAccount) }
                GroupManagementView(presentation: presentation.groups)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onDisappear { presentation.hide() }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(SettingsAccountStrings.server, text: $presentation.server)
                .accessibilityLabel(SettingsAccountStrings.server)
            TextField(SettingsAccountStrings.username, text: $presentation.username)
                .accessibilityLabel(SettingsAccountStrings.username)
            SettingsAccountPasswordField(input: presentation.passwordInput,
                reset: presentation.passwordInputReset, isEditable: presentation.canOperate)
                .frame(height: 24)
            TextField(SettingsAccountStrings.deviceName, text: $presentation.deviceName)
                .accessibilityLabel(SettingsAccountStrings.deviceName)
            HStack {
                Button(SettingsAccountStrings.signIn, action: presentation.login)
                Button(SettingsAccountStrings.refresh, action: presentation.refresh)
                Button(SettingsAccountStrings.signOut, action: presentation.signOut)
                    .disabled(!presentation.canSignOut)
            }
        }
        .disabled(!presentation.canOperate)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let operation = presentation.state?.operation {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(SettingsAccountStrings.progress(operation))
                }
                .accessibilityElement(children: .combine)
            }
            if let issue = presentation.state?.error { Text(issue.message).foregroundStyle(.red) }
            if let message = presentation.cleanupMessage {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var reservedFolders: some View {
        if let paths = presentation.state?.reservedFolders, !paths.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsAccountStrings.reservedFolders)
                ForEach(paths, id: \.self) { path in Text(path.string).textSelection(.enabled) }
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsAccountStrings.devices).font(.headline)
            ForEach(presentation.state?.devices ?? [], id: \.id) { device in
                HStack {
                    Text(SettingsAccountStrings.device(device))
                    Spacer()
                    Button(revokeTitle(device)) { presentation.revoke(device) }
                        .disabled(!presentation.canRevoke(device))
                }
            }
        }
    }

    @ViewBuilder private var heldFiles: some View {
        if let state = presentation.state, !state.heldPrompts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsAccountStrings.heldFiles).font(.headline)
                Text(SettingsAccountStrings.heldGuidance)
                ForEach(state.heldPrompts, id: \.identity) { prompt in
                    Toggle(SettingsAccountStrings.held(prompt, keptLocal: state.keptLocal.contains(prompt.identity)),
                        isOn: Binding(get: { presentation.selectedHeld.contains(prompt.identity) },
                            set: { presentation.selectHeld(prompt.identity, selected: $0) }))
                        .disabled(!presentation.canSelectHeld)
                }
                HStack {
                    Button(SettingsAccountStrings.keepLocal) { presentation.decideHeld(.keepLocal) }
                    Button(SettingsAccountStrings.include) { presentation.decideHeld(.include) }
                }
                .disabled(!presentation.canDecideHeld)
            }
        }
    }

    private func revokeTitle(_ device: SyncAPI.Device) -> String {
        device.isCurrent ? SettingsAccountStrings.revokeCurrent : SettingsAccountStrings.revoke
    }
}
