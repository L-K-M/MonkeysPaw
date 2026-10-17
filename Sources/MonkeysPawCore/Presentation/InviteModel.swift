import Foundation

protocol InviteProviding {
    func stage(_ input: String, server: String?) throws -> SyncStagedInvite
    func accept(_ staged: SyncStagedInvite, as mode: InviteAcceptance, username: String,
                password: inout String, deviceName: String) async throws -> SyncInviteAcceptance
    func create(groupID: ULID, role: SyncAPI.InviteRole) async throws -> SyncInviteCreation
    func copy(_ created: SyncInviteCreation) throws
}

extension SyncInviteService: InviteProviding {}

/// Construct/read/observe/retire on UI. Network and staging run off UI;
/// publication and explicit Clipboard copying use only the MainThread port.
public final class InviteModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Result {
        case staged(SyncStagedInvite), created(SyncInviteCreation), accepted(SyncInviteAcceptance)
    }

    public private(set) var state = InviteState()
    public var onChange: (() -> Void)?
    private let service: InviteProviding
    private let mainThread: MainThread
    private var staged: SyncStagedInvite?
    private var active = true
    private var request: UUID?
    private var visibility: UInt64 = 0
    private var publication: UInt64 = 0
    private var observers: [UUID: (InviteState) -> Void] = [:]
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public convenience init(service: SyncInviteService, mainThread: MainThread) {
        self.init(service: service as InviteProviding, mainThread: mainThread)
    }

    init(service: InviteProviding, mainThread: MainThread) {
        self.service = service
        self.mainThread = mainThread
    }

    @discardableResult
    public func addObserver(_ observer: @escaping (InviteState) -> Void) -> UUID {
        let id = UUID()
        if active { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }
    public func drain() async { await acceptedTask()?.value }

    /// Consume full links and bare tokens synchronously, even while busy/retired.
    public func stage(_ input: inout String, server: String? = nil) {
        let supplied = SecretValue(input)
        input = ""
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            self.staged = nil
            self.state = InviteState()
            self.perform(.staging) { service in .staged(try service.stage(supplied.withValue { $0 }, server: server)) }
        }
    }

    /// No URL activation, stage, refresh or Copy action ever calls this intent.
    public func accept(as mode: InviteAcceptance, username: String = "", password: inout String, deviceName: String = "") {
        let supplied = SecretValue(password)
        password = ""
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            guard let staged = self.staged else { self.change { $0.error = .noInvite }; return }
            // Drop the staged bearer before sending; uncertain/failed requests
            // require explicit re-entry rather than automatic single-use retry.
            self.staged = nil
            self.state.hasStagedInvite = false
            self.state.inputReset = UUID()
            self.perform(.accepting) { service in
                var transient = supplied.withValue { $0 }
                return .accepted(try await service.accept(staged, as: mode, username: username,
                    password: &transient, deviceName: deviceName))
            }
        }
    }

    public func create(groupID: ULID, role: SyncAPI.InviteRole) {
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            self.staged = nil
            self.state = InviteState()
            self.perform(.creating) { .created(try await $0.create(groupID: groupID, role: role)) }
        }
    }

    public func copyCreatedLink() {
        mainThread.run { [weak self] in
            guard let self, self.active, self.request == nil else { return }
            guard let created = self.state.created else { self.change { $0.error = .noInvite }; return }
            do { try self.service.copy(created); self.change { $0.error = nil } }
            catch { self.change { $0.error = error as? InviteIssue ?? .account(.invalidResponse) } }
        }
    }

    /// Hide/close clears one-time links and staged tokens, including queued
    /// results. Already accepted service work still finishes its compensation.
    public func dismiss() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.visibility &+= 1
            self.staged = nil
            self.change {
                let operation = $0.operation
                $0 = InviteState()
                $0.operation = operation
            }
        }
    }

    public func retire() {
        active = false
        request = nil
        staged = nil
        state = InviteState()
        observers.removeAll()
        onChange = nil
    }

    private func perform(_ operation: InviteOperation, intent: @escaping (InviteProviding) async throws -> Result) {
        guard active, request == nil else { return }
        let id = UUID(), epoch = visibility
        request = id
        let previous = state
        state.operation = operation
        state.error = nil
        let next = Task.detached { [service, mainThread, weak self] in
            let result: Result?
            let issue: InviteIssue?
            do { result = try await intent(service); issue = nil }
            catch { result = nil; issue = error as? InviteIssue ?? .account(.invalidResponse) }
            mainThread.run { [weak self] in self?.complete(result, issue: issue, request: id, visibility: epoch) }
        }
        // Admission precedes callbacks: a reentrant close revokes this epoch
        // instead of letting the original intent start after the close.
        taskLock.lock(); task = next; taskLock.unlock()
        publish(from: previous)
    }

    private func complete(_ result: Result?, issue: InviteIssue?, request id: UUID, visibility epoch: UInt64) {
        guard active, request == id else { return }
        request = nil
        guard visibility == epoch else { change { $0.operation = nil }; return }
        change { current in
            current.operation = nil
            current.error = issue
            switch result {
            case .staged(let value):
                staged = value
                current.destination = value.destination
                current.hasStagedInvite = true
            case .created(let value): current.created = value
            case .accepted(let value):
                current.accepted = true
                current.error = value.issue
                current.cleanup = AccountCleanup(value.cleanup)
                current.inputReset = UUID()
            case nil: break
            }
        }
    }

    private func acceptedTask() -> Task<Void, Never>? {
        taskLock.lock(); defer { taskLock.unlock() }; return task
    }

    private func change(_ body: (inout InviteState) -> Void) {
        guard active else { return }
        let previous = state
        body(&state)
        publish(from: previous)
    }

    private func publish(from previous: InviteState) {
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

    public var description: String { "<invite model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
