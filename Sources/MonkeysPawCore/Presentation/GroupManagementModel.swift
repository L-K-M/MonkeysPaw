import Foundation

protocol GroupManagementProviding {
    var snapshot: SyncAccountSnapshot { get }
    func execute(_ command: SyncGroupCommand, expectedAccount: SyncAccount?) async -> SyncGroupResult
    func copy(_ created: SyncInviteCreation) throws
}

extension SyncGroupService: GroupManagementProviding {}

/// Construct/read/observe/retire on UI. Account work runs off UI; every intent
/// and publication uses MainThread. Native views own their editable drafts.
public final class GroupManagementModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public private(set) var state = GroupManagementState()
    public var onChange: (() -> Void)?

    private let service: GroupManagementProviding
    private let mainThread: MainThread
    private var account: SyncAccount?
    private var active = true
    private var request: UUID?
    private var visibility: UInt64 = 0
    private var publication: UInt64 = 0
    private var observers: [UUID: (GroupManagementState) -> Void] = [:]
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public convenience init(service: SyncGroupService, mainThread: MainThread) {
        self.init(service: service as GroupManagementProviding, mainThread: mainThread)
    }

    init(service: GroupManagementProviding, mainThread: MainThread) {
        self.service = service
        self.mainThread = mainThread
        mainThread.run { [weak self] in
            self?.perform(.loading) { SyncGroupResult(snapshot: $0.snapshot) }
        }
    }

    @discardableResult
    public func addObserver(_ observer: @escaping (GroupManagementState) -> Void) -> UUID {
        let id = UUID()
        if active { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }
    /// Retire on UI, then await admitted work before replacing the account graph.
    public func drain() async { await acceptedTask()?.value }

    public func refresh() {
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            self.execute(.refreshing, command: .refresh(self.state.selectedGroupID))
        }
    }

    public func selectGroup(_ id: ULID?) {
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            guard id == nil || self.state.groups.contains(where: { $0.groupID == id?.rawValue }) else {
                self.change { $0.error = .invalidSelection }
                return
            }
            self.execute(.refreshing, command: .refresh(id))
        }
    }

    public func create(name: String) {
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            guard self.state.canCreate else { self.change { $0.error = .account(.signedOut) }; return }
            guard self.validName(name) else { return }
            self.execute(.creating, command: .create(name))
        }
    }

    public func rename(name: String) {
        mainThread.run { [weak self] in
            guard let self, let group = self.managedGroup(), self.validName(name) else { return }
            self.execute(.renaming, command: .rename(group, name))
        }
    }

    /// Native views obtain confirmation before invoking group deletion.
    public func deleteGroup() {
        mainThread.run { [weak self] in
            guard let self, let group = self.managedGroup() else { return }
            self.execute(.deleting, command: .delete(group))
        }
    }

    public func setRole(userID: String, role: SyncAPI.Role) {
        mainThread.run { [weak self] in
            guard let self, let group = self.managedGroup() else { return }
            guard let user = try? SyncIdentifiers.ulid(userID) else {
                self.change { $0.error = .invalidUserID }
                return
            }
            guard self.state.canSetRole(userID: userID, role: role) else {
                self.change { $0.error = .forbidden }
                return
            }
            self.execute(.settingRole, command: .setRole(group, user, role))
        }
    }

    public func removeMember(userID: String) {
        mainThread.run { [weak self] in
            guard let self, let group = self.managedGroup() else { return }
            guard let user = try? SyncIdentifiers.ulid(userID), self.state.members.contains(where: { $0.userID == userID }) else {
                self.change { $0.error = .invalidUserID }
                return
            }
            self.execute(.removingMember, command: .removeMember(group, user))
        }
    }

    public func createInvite(role: SyncAPI.InviteRole) {
        mainThread.run { [weak self] in
            guard let self, let group = self.managedGroup() else { return }
            self.execute(.creatingInvite, command: .createInvite(group, role))
        }
    }

    public func copyCreatedInvite() {
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            guard self.state.canCopyInvite, let created = self.state.createdInvite else {
                self.change { $0.error = .invalidSelection }
                return
            }
            do { try self.service.copy(created); self.change { $0.error = nil } }
            catch {
                self.change {
                    $0.createdInvite = nil
                    $0.error = error as? InviteIssue == .accountChanged ? .accountChanged : .account(.invalidResponse)
                }
            }
        }
    }

    /// Hide/close revokes one-time links and their pending results, without
    /// cancelling an admitted server transaction or its authoritative refresh.
    public func dismiss() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.visibility &+= 1
            self.change { $0.createdInvite = nil; $0.inputReset = UUID() }
        }
    }

    public func retire() {
        active = false
        request = nil
        account = nil
        state = GroupManagementState()
        state.operation = nil
        observers.removeAll()
        onChange = nil
    }

    private func managedGroup() -> ULID? {
        guard active, request == nil else { return nil }
        guard state.canManage, let id = state.selectedGroupID else {
            change { $0.error = .forbidden }
            return nil
        }
        return id
    }

    private func validName(_ name: String) -> Bool {
        do { try SyncAPISchema.name.validate(.string(name)); return true }
        catch { change { $0.error = .invalidName }; return false }
    }

    private func execute(_ operation: GroupManagementOperation, command: SyncGroupCommand) {
        let expected = account
        perform(operation) { await $0.execute(command, expectedAccount: expected) }
    }

    private func perform(_ operation: GroupManagementOperation,
                         intent: @escaping (GroupManagementProviding) async -> SyncGroupResult) {
        guard active, request == nil else { return }
        let id = UUID(), epoch = visibility
        request = id
        let previous = state
        state.operation = operation
        state.createdInvite = nil
        state.error = nil
        state.changeConfirmed = false
        let next = Task.detached { [service, mainThread, weak self] in
            let result = await intent(service)
            mainThread.run { [weak self] in self?.complete(result, request: id, visibility: epoch) }
        }
        // Admission precedes reentrant native close/retire callbacks.
        taskLock.lock(); task = next; taskLock.unlock()
        publish(from: previous)
    }

    private func complete(_ result: SyncGroupResult, request id: UUID, visibility epoch: UInt64) {
        guard active, request == id else { return }
        request = nil
        let changedAccount = account != result.snapshot.account
        account = result.snapshot.account
        change { current in
            var next = result.state
            let changedAccess = changedAccount || current.selectedGroupID != next.selectedGroupID
                || current.selectedGroup?.role != next.selectedGroup?.role || current.accountKind != next.accountKind
            next.inputReset = changedAccess ? UUID() : current.inputReset
            if visibility != epoch || !next.canManage { next.createdInvite = nil }
            current = next
        }
    }

    private func acceptedTask() -> Task<Void, Never>? {
        taskLock.lock(); defer { taskLock.unlock() }; return task
    }

    private func change(_ body: (inout GroupManagementState) -> Void) {
        guard active else { return }
        let previous = state
        body(&state)
        publish(from: previous)
    }

    private func publish(from previous: GroupManagementState) {
        guard active, state != previous else { return }
        publication &+= 1
        let version = publication, snapshot = state
        for id in Array(observers.keys) {
            mainThread.run { [weak self] in
                guard let self, self.active, self.publication == version, let observer = self.observers[id] else { return }
                observer(snapshot)
            }
        }
        if active, publication == version { onChange?() }
    }

    public var description: String { "<group management model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
