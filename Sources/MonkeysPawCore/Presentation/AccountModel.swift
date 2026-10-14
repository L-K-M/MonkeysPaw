import Foundation

protocol AccountProviding {
    var snapshot: SyncAccountSnapshot { get }
    func login(server: String, username: String, password: inout String, deviceName: String) async throws -> SyncAccountSnapshot
    func startup() async throws -> SyncAccountSnapshot
    func refresh() async throws -> SyncAccountSnapshot
    func revokeDevice(_ id: ULID) async throws -> SyncAccountSnapshot
    func signOut() async throws -> SyncAccountCleanup
    func heldPrompts() throws -> [SyncHeldPrompt]
    func includeHeld(_ identities: Set<PromptIdentity>) async throws -> SyncAccountSnapshot
}

extension SyncAccountService: AccountProviding {}

/// Construct, read, subscribe, remove and retire on the UI thread. Async account
/// work runs off UI; every intent/publication uses the injected MainThread.
public final class AccountModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Admission { case ordinary, initialLoad }
    public private(set) var state = AccountState()
    /// One native view owns this hook; independent subscribers use addObserver.
    public var onChange: (() -> Void)?

    private let account: AccountProviding
    private let mainThread: MainThread
    private var active = true
    private var request: UUID?
    private var publication: UInt64 = 0
    private var observers: [UUID: (AccountState) -> Void] = [:]
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public convenience init(account: SyncAccountService, mainThread: MainThread) {
        self.init(account: account as AccountProviding, mainThread: mainThread)
    }

    init(account: AccountProviding, mainThread: MainThread) {
        self.account = account
        self.mainThread = mainThread
        mainThread.run { [weak self] in
            self?.perform(.loading, admission: .initialLoad) { $0.snapshot }
        }
    }

    @discardableResult
    public func addObserver(_ observer: @escaping (AccountState) -> Void) -> UUID {
        let id = UUID()
        if active { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Composition awaits admitted work before replacing the account graph.
    /// Retirement/closing never cancels compensation or sign-out cleanup.
    public func drain() async { await acceptedTask()?.value }

    public func retire() {
        active = false
        request = nil
        observers.removeAll()
        onChange = nil
    }

    /// Startup is explicit; opening Account only reads the current snapshot.
    public func startup() {
        mainThread.run { [weak self] in
            self?.perform(.loading) { try await $0.startup() }
        }
    }

    public func refresh() {
        mainThread.run { [weak self] in
            self?.perform(.refreshing) { account in
                if account.snapshot.enabled { return try await account.refresh() }
                return account.snapshot
            }
        }
    }

    /// Consume native secure input synchronously, including busy/retired paths.
    /// No password draft is stored on this model or returned in any state.
    public func login(server: String, username: String, password: inout String, deviceName: String) {
        let supplied = SecretValue(password)
        password = ""
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            if self.state.isBusy {
                self.change { $0.passwordInputReset = UUID() }
                return
            }
            self.perform(.signingIn) { account in
                var transient = supplied.withValue { $0 }
                return try await account.login(server: server, username: username,
                    password: &transient, deviceName: deviceName)
            }
        }
    }

    /// Hide/close calls this even when the reusable model stays alive.
    public func clearPasswordInput() {
        mainThread.run { [weak self] in
            self?.change { $0.passwordInputReset = UUID() }
        }
    }

    public func revokeDevice(_ id: ULID) {
        mainThread.run { [weak self] in
            guard let self, self.active, !self.state.isBusy else { return }
            guard self.state.devices.contains(where: { $0.id == id.rawValue }) else {
                self.change { $0.error = .invalidSelection }
                return
            }
            self.perform(.revokingDevice) { account in
                let snapshot = try await account.revokeDevice(id)
                if snapshot.enabled { return try await account.refresh() }
                return snapshot
            }
        }
    }

    public func signOut() {
        mainThread.run { [weak self] in
            self?.perform(.signingOut) { account in
                let cleanup = try await account.signOut()
                var snapshot = account.snapshot
                snapshot.cleanup = cleanup
                return snapshot
            }
        }
    }

    public func decideHeld(_ identities: Set<PromptIdentity>, decision: AccountHeldDecision) {
        mainThread.run { [weak self] in
            guard let self, self.active, !self.state.isBusy else { return }
            guard self.state.enabled, !identities.isEmpty,
                  identities.isSubset(of: Set(self.state.heldPrompts.map(\.identity))) else {
                self.change { $0.error = .invalidSelection }
                return
            }
            switch decision {
            case .keepLocal:
                self.change { $0.keptLocal.formUnion(identities); $0.error = nil }
            case .include:
                self.perform(.includingHeld) { try await $0.includeHeld(identities) }
            }
        }
    }

    private func perform(_ operation: AccountOperation, admission: Admission = .ordinary,
                         intent: @escaping (AccountProviding) async throws -> SyncAccountSnapshot) {
        guard active, request == nil, admission == .initialLoad || !state.isBusy else { return }
        let id = UUID()
        request = id
        let previous = state
        state.operation = operation
        state.error = nil
        state.reservedFolders = []
        if operation == .signingIn { state.passwordInputReset = UUID() }
        // Store the admitted task before notifying reentrant composition code.
        let nextTask = Task.detached { [account, mainThread, weak self] in
            var snapshot: SyncAccountSnapshot
            var issue: AccountIssue?
            var reserved: [RelativePath] = []
            var failedCleanup: SyncAccountCleanup?
            do { snapshot = try await intent(account) }
            catch let failure as SyncAccountServiceError {
                issue = AccountIssue(failure.issue)
                if case .reservedFolders(let paths) = failure.issue { reserved = paths }
                if failure.cleanup != SyncAccountCleanup() { failedCleanup = failure.cleanup }
                snapshot = account.snapshot
            } catch {
                issue = .invalidResponse
                snapshot = account.snapshot
            }
            var holds: [AccountHeldPrompt] = []
            do { holds = try account.heldPrompts().map(AccountHeldPrompt.init) }
            catch let failure as SyncAccountServiceError {
                if issue == nil { issue = AccountIssue(failure.issue) }
            } catch { if issue == nil { issue = .invalidMetadata } }
            // Drop service error payloads before a queued UI completion exists.
            var result = AccountState()
            result.connection = snapshot.account.map(AccountConnection.init)
            result.devices = snapshot.me?.devices ?? []
            result.groups = snapshot.me?.groups ?? []
            result.secretTier = snapshot.tier
            result.enabled = snapshot.enabled
            result.cleanup = AccountCleanup(failedCleanup ?? snapshot.cleanup)
            result.heldPrompts = holds.sorted { $0.path < $1.path }
            result.operation = nil
            result.error = issue
            result.reservedFolders = reserved.sorted()
            let completed = result
            mainThread.run { [weak self] in self?.complete(completed, request: id, operation: operation) }
        }
        taskLock.lock(); task = nextTask; taskLock.unlock()
        publish(from: previous)
    }

    private func complete(_ result: AccountState, request id: UUID, operation: AccountOperation) {
        guard active, request == id else { return }
        request = nil
        change { current in
            var next = result
            next.passwordInputReset = operation == .signingIn ? UUID() : current.passwordInputReset
            if current.connection?.serverURL == next.connection?.serverURL,
               current.connection?.userID == next.connection?.userID {
                next.keptLocal = current.keptLocal.intersection(Set(next.heldPrompts.map(\.identity)))
            }
            current = next
        }
    }

    private func acceptedTask() -> Task<Void, Never>? {
        taskLock.lock(); defer { taskLock.unlock() }; return task
    }

    private func change(_ body: (inout AccountState) -> Void) {
        guard active else { return }
        let previous = state
        body(&state)
        publish(from: previous)
    }

    private func publish(from previous: AccountState) {
        guard active, state != previous else { return }
        publication &+= 1
        let version = publication
        let snapshot = state
        for id in Array(observers.keys) {
            mainThread.run { [weak self] in
                guard let self, self.active, self.publication == version,
                      let observer = self.observers[id] else { return }
                observer(snapshot)
            }
        }
        if active, publication == version { onChange?() }
    }

    public var description: String { "<account model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
