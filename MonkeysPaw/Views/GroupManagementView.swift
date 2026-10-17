import MonkeysPawCore
import SwiftUI

/// Borrows the Account graph's model; only native drafts and confirmation live here.
final class GroupManagementViewState: ObservableObject {
    private enum IntentKind { case refresh, change }
    enum Confirmation: Equatable {
        case rename(SyncAPI.GroupMembership, String)
        case delete(SyncAPI.GroupMembership)

        var group: SyncAPI.GroupMembership {
            switch self {
            case .rename(let group, _), .delete(let group): return group
            }
        }
        var message: String {
            switch self {
            case .rename(_, let name): return GroupManagementStrings.renameWarning(name)
            case .delete: return GroupManagementStrings.deleteWarning
            }
        }
        var title: String {
            switch self {
            case .rename: return GroupManagementStrings.rename
            case .delete: return GroupManagementStrings.confirmDelete
            }
        }
    }

    @Published private(set) var state: GroupManagementState? = nil
    @Published var createName = ""
    @Published var name = ""
    @Published var userID = ""
    @Published var memberRole: SyncAPI.Role = .editor
    @Published var inviteRole: SyncAPI.InviteRole = .viewer
    @Published private(set) var memberRoles: [String: SyncAPI.Role] = [:]
    @Published private(set) var confirmation: Confirmation? = nil
    @Published private(set) var showsManagement = false
    @Published private var pendingIntent: UUID? = nil
    var onBusyChange: (() -> Void)?

    private let makeModel: () -> GroupManagementModel?
    private let mainThread: MainThread
    private var model: GroupManagementModel?
    private var observer: UUID?
    private var isShown = false
    @Published private var account: AccountState? = nil
    @Published private var accountIntentPending = false
    private var needsRefresh = false
    private var renderedBusy = false
    private var mayDisplayInvite = false

    init(mainThread: MainThread, makeModel: @escaping () -> GroupManagementModel?) {
        self.mainThread = mainThread
        self.makeModel = makeModel
    }

    deinit {
        let model = model
        let observer = observer
        mainThread.run {
            if let observer { model?.removeObserver(observer) }
            model?.dismiss()
        }
    }

    private var isIdle: Bool {
        isShown && pendingIntent == nil && !accountIntentPending
            && account?.isBusy == false && model?.state.isBusy == false
    }
    var isBusy: Bool {
        isShown && model != nil && (needsRefresh || pendingIntent != nil || model?.state.isBusy == true)
    }
    var canRefresh: Bool { isIdle }
    var canOperate: Bool {
        isIdle && account?.connection == state?.connection && account?.enabled == state?.enabled
    }
    var canCreate: Bool { canOperate && state?.canCreate == true }
    var canManage: Bool { canOperate && state?.canManage == true }
    var canCopyInvite: Bool { canOperate && mayDisplayInvite && state?.canCopyInvite == true }
    var createdInvite: SyncInviteCreation? { isShown && mayDisplayInvite ? state?.createdInvite : nil }
    var message: String? {
        guard state?.enabled == true else { return GroupManagementStrings.unavailable }
        if state?.groups.isEmpty == true { return GroupManagementStrings.noGroups }
        return state?.selectedGroup == nil ? GroupManagementStrings.selectGroup : nil
    }

    func show() {
        guard !isShown else { refreshBinding(); return }
        isShown = true
        refreshBinding()
    }

    func hide() {
        isShown = false
        detach()
        account = nil
        accountIntentPending = false
        updateBusy()
    }

    func refreshBinding() {
        guard isShown else { return }
        let next = makeModel()
        guard next !== model else { return }
        detach()
        model = next
        needsRefresh = next != nil
        if let next {
            observer = next.addObserver { [weak self, weak next] _ in
                guard let self, let next, self.isShown, self.model === next else { return }
                self.render(next.state)
            }
            render(next.state)
        }
        updateBusy()
    }

    func updateAccount(_ next: AccountState?, pendingIntent: UUID?) {
        let changed = account?.connection != next?.connection || account?.enabled != next?.enabled
        let completed = account?.isBusy == true && next?.isBusy == false
        account = next
        accountIntentPending = pendingIntent != nil
        if changed || completed { needsRefresh = true }
        if changed {
            mayDisplayInvite = false
            confirmation = nil
            model?.dismiss()
        }
        refreshWhenReady()
        updateBusy()
    }

    func refresh() { perform(.refresh) { $0.refresh() } }
    func selectGroup(_ group: SyncAPI.GroupMembership) {
        guard let id = ULID(group.groupID) else { return }
        perform(.refresh) { $0.selectGroup(id) }
    }
    func create() {
        guard canCreate else { return }
        let name = createName
        perform { $0.create(name: name) }
    }
    func requestRename() {
        guard hasCurrentBinding(), canManage, let group = state?.selectedGroup else { return }
        confirmation = .rename(group, name)
    }
    func requestDelete() {
        guard hasCurrentBinding(), canManage, let group = state?.selectedGroup else { return }
        confirmation = .delete(group)
    }
    func cancelConfirmation() { confirmation = nil }
    func confirm() {
        guard hasCurrentBinding(), canManage, let confirmation,
              confirmation.group == state?.selectedGroup else { return }
        self.confirmation = nil
        switch confirmation {
        case .rename(_, let name): perform { $0.rename(name: name) }
        case .delete: perform { $0.deleteGroup() }
        }
    }

    func role(for member: SyncAPI.Member) -> SyncAPI.Role { memberRoles[member.userID] ?? member.role }
    func setDraftRole(_ role: SyncAPI.Role, for member: SyncAPI.Member) {
        guard hasCurrentBinding(), canManage else { return }
        memberRoles[member.userID] = role
    }
    func canSetRole(userID: String, role: SyncAPI.Role) -> Bool {
        canManage && state?.canSetRole(userID: userID, role: role) == true
    }
    func setRole(userID: String, role: SyncAPI.Role) {
        guard canSetRole(userID: userID, role: role) else { return }
        perform { $0.setRole(userID: userID, role: role) }
    }
    func removeMember(_ member: SyncAPI.Member) {
        guard canManage else { return }
        perform { $0.removeMember(userID: member.userID) }
    }
    func createInvite() {
        guard canManage else { return }
        let role = inviteRole
        perform { [self] in
            mayDisplayInvite = true
            $0.createInvite(role: role)
        }
    }
    func copyInvite() {
        guard canCopyInvite else { return }
        perform { $0.copyCreatedInvite() }
    }

    private func perform(_ kind: IntentKind = .change, _ intent: (GroupManagementModel) -> Void) {
        guard hasCurrentBinding(), isIdle, let model else { return }
        guard kind == .refresh || canOperate else { return }
        let request = UUID()
        pendingIntent = request
        updateBusy()
        intent(model)
        // No-op intents need no publication. Release after queued Core admission.
        mainThread.run { [weak self, weak model] in
            guard let self, let model, self.model === model, self.pendingIntent == request else { return }
            self.pendingIntent = nil
            self.refreshWhenReady()
            self.updateBusy()
        }
    }

    private func hasCurrentBinding() -> Bool {
        let previous = model
        refreshBinding()
        return previous != nil && previous === model
    }

    private func render(_ next: GroupManagementState) {
        let previous = state
        if previous?.inputReset != next.inputReset {
            resetDrafts()
            name = next.selectedGroup?.name ?? ""
        } else if name == (previous?.selectedGroup?.name ?? "") {
            name = next.selectedGroup?.name ?? ""
        }
        if previous?.members != next.members { memberRoles.removeAll() }
        state = next
        if !next.isBusy { showsManagement = next.canManage }
        if confirmation?.group != next.selectedGroup || !canOperate { confirmation = nil }
        refreshWhenReady()
        updateBusy()
    }

    private func refreshWhenReady() {
        guard needsRefresh, isIdle else { return }
        needsRefresh = false
        // Opening a fresh, signed-out Account is entirely local.
        guard account?.connection != nil || state?.connection != nil else { return }
        perform(.refresh) { $0.refresh() }
    }

    private func updateBusy() {
        guard renderedBusy != isBusy else { return }
        renderedBusy = isBusy
        onBusyChange?()
    }

    private func resetDrafts() {
        createName = ""
        name = ""
        userID = ""
        memberRole = .editor
        inviteRole = .viewer
        memberRoles.removeAll()
        confirmation = nil
        mayDisplayInvite = false
    }

    private func detach() {
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model?.dismiss()
        model = nil
        pendingIntent = nil
        needsRefresh = false
        state = nil
        showsManagement = false
        resetDrafts()
    }
}

struct GroupManagementView: View {
    @ObservedObject var presentation: GroupManagementViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GroupManagementStrings.groups).font(.headline)
            if let message = presentation.message { Text(message) }
            status
            Button(GroupManagementStrings.refresh, action: presentation.refresh)
                .disabled(!presentation.canRefresh)
                .accessibilityIdentifier("settings-groups-refresh")
            groupList
            createForm
            if let group = presentation.state?.selectedGroup {
                Text(GroupManagementStrings.group(group)).font(.headline)
                Text(GroupManagementStrings.groupID(group)).textSelection(.enabled)
                if presentation.showsManagement { management }
                else { Text(GroupManagementStrings.readOnly) }
                memberList
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let operation = presentation.state?.operation {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(GroupManagementStrings.progress(operation))
                }
                .accessibilityElement(children: .combine)
            }
            if presentation.state?.changeConfirmed == true { Text(GroupManagementStrings.confirmed) }
            if let error = presentation.state?.error {
                Text(error.message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-groups-error")
            }
        }
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(presentation.state?.groups ?? [], id: \.groupID) { group in
                Button(GroupManagementStrings.group(group)) { presentation.selectGroup(group) }
                    .disabled(!presentation.canRefresh)
                    .accessibilityIdentifier("settings-groups-select-" + group.groupID)
                    .accessibilityValue(group.groupID)
            }
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(GroupManagementStrings.createName, text: $presentation.createName)
                .accessibilityLabel(GroupManagementStrings.createName)
            Button(GroupManagementStrings.create, action: presentation.create)
                .accessibilityIdentifier("settings-groups-create")
        }
        .disabled(!presentation.canCreate)
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(GroupManagementStrings.name, text: $presentation.name)
                .accessibilityLabel(GroupManagementStrings.name)
            HStack {
                Button(GroupManagementStrings.rename, action: presentation.requestRename)
                Button(GroupManagementStrings.delete, action: presentation.requestDelete)
            }
            if let confirmation = presentation.confirmation {
                GroupManagementConfirmationView(presentation: presentation, confirmation: confirmation)
            }
            inviteForm
        }
        .disabled(!presentation.canManage)
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GroupManagementStrings.members).font(.headline)
            ForEach(presentation.state?.members ?? [], id: \.userID) { member in
                memberRow(member)
            }
            if presentation.showsManagement { memberForm }
        }
    }

    private func memberRow(_ member: SyncAPI.Member) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GroupManagementStrings.member(member)).textSelection(.enabled)
            if presentation.showsManagement {
                Picker(GroupManagementStrings.role, selection: Binding(
                    get: { presentation.role(for: member) },
                    set: { presentation.setDraftRole($0, for: member) })) {
                    ForEach(SyncAPI.Role.allCases, id: \.self) { role in
                        Text(GroupManagementStrings.role(role)).tag(role)
                    }
                }
                .disabled(!presentation.canManage)
                HStack {
                    Button(GroupManagementStrings.setRole) {
                        presentation.setRole(userID: member.userID, role: presentation.role(for: member))
                    }
                    .disabled(!presentation.canSetRole(userID: member.userID, role: presentation.role(for: member)))
                    Button(GroupManagementStrings.remove) { presentation.removeMember(member) }
                        .disabled(!presentation.canManage)
                }
            }
        }
    }

    private var memberForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GroupManagementStrings.userIDGuidance)
            TextField(GroupManagementStrings.userID, text: $presentation.userID)
                .accessibilityLabel(GroupManagementStrings.userID)
            Picker(GroupManagementStrings.role, selection: $presentation.memberRole) {
                ForEach(SyncAPI.Role.allCases, id: \.self) { role in
                    Text(GroupManagementStrings.role(role)).tag(role)
                }
            }
            Button(GroupManagementStrings.setRole) {
                presentation.setRole(userID: presentation.userID, role: presentation.memberRole)
            }
            .disabled(!presentation.canSetRole(userID: presentation.userID, role: presentation.memberRole))
        }
        .disabled(!presentation.canManage)
    }

    private var inviteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(GroupManagementStrings.inviteRole, selection: $presentation.inviteRole) {
                Text(GroupManagementStrings.role(.viewer)).tag(SyncAPI.InviteRole.viewer)
                Text(GroupManagementStrings.role(.editor)).tag(SyncAPI.InviteRole.editor)
            }
            Button(GroupManagementStrings.createInvite, action: presentation.createInvite)
            Text(GroupManagementStrings.inviteGuidance)
            if let created = presentation.createdInvite {
                Text(created.link)
                Text(GroupManagementStrings.expires(created.expiresAt))
            }
            Button(GroupManagementStrings.copyInvite, action: presentation.copyInvite)
                .disabled(!presentation.canCopyInvite)
        }
    }
}

private struct GroupManagementConfirmationView: View {
    @ObservedObject var presentation: GroupManagementViewState
    let confirmation: GroupManagementViewState.Confirmation
    @FocusState private var cancelIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirmation.message)
            HStack {
                Button(GroupManagementStrings.cancel, action: presentation.cancelConfirmation)
                    .focused($cancelIsFocused)
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.title, action: presentation.confirm)
            }
        }
        .accessibilityIdentifier("settings-groups-confirmation")
        .onAppear { cancelIsFocused = true }
    }
}
