import Foundation

/// Graph-scoped orchestration. Timers come from Scheduler; all file/network
/// work runs in an async task. MainThread is used only to publish reports.
public final class SyncService {
    private struct Session {
        let binding: SyncLibraryIdentity
        let client: SyncHTTPClient
        let device: String
    }
    private let files: FileStore
    private let states: SyncStateStore
    private let accounts: SyncAccountStore
    private let mutations: SyncLibraryMutations
    private let journal: SyncApplyJournal
    private let pending: SyncPendingOperationStore
    private let scheduler: Scheduler
    private let main: MainThread
    private let clock: WallClock
    private let freshID: () throws -> ULID
    private let now: () -> ContinuousClock.Instant
    private let lock = NSRecursiveLock()
    private var session: Session?
    private var coordinator: SyncCoordinator?
    private var task: Task<Void, Never>?
    private var running = false
    private var retired = false
    private var health: SyncRootHealth = .available
    private var epoch: UInt64 = 0
    private var pollToken: UInt64 = 0
    private var saveToken: UInt64 = 0
    private var retryToken: UInt64 = 0
    private var publication: UInt64 = 0
    private var dirty = false
    private var automaticReruns = 0
    private var backoff: Duration?
    private var retryAt: ContinuousClock.Instant?
    private var observers: [UUID: (SyncReport) -> Void] = [:]
    private var current = SyncReport()

    deinit { coordinator?.permit.revoke(); task?.cancel() }

    public init(library: LibraryService, libraryOperations: SyncFileOperations,
                dataFiles: FileStore, dataOperations: SyncFileOperations,
                states: SyncStateStore, accounts: SyncAccountStore,
                scheduler: Scheduler, mainThread: MainThread, clock: WallClock, entropy: EntropySource) throws {
        files = dataFiles
        self.states = states
        self.accounts = accounts
        mutations = SyncLibraryMutations(library: library, operations: libraryOperations)
        journal = try SyncApplyJournal(files: dataFiles, operations: dataOperations,
            mutations: mutations, states: states, accounts: accounts)
        pending = SyncPendingOperationStore(files: dataFiles, operations: dataOperations)
        self.scheduler = scheduler
        main = mainThread
        self.clock = clock
        freshID = { try ULID.generate(at: clock.now(), entropy: entropy.bytes(count: Limits.ulidEntropyBytes)) }
        now = { ContinuousClock.now }
    }

    /// Tests inject monotonic time and stable IDs, independently of UTC UI time.
    init(files: FileStore, states: SyncStateStore, accounts: SyncAccountStore,
         mutations: SyncLibraryMutations, journal: SyncApplyJournal, pending: SyncPendingOperationStore,
         scheduler: Scheduler, mainThread: MainThread, clock: WallClock,
         freshID: @escaping () throws -> ULID, now: @escaping () -> ContinuousClock.Instant) {
        self.files = files
        self.states = states
        self.accounts = accounts
        self.mutations = mutations
        self.journal = journal
        self.pending = pending
        self.scheduler = scheduler
        main = mainThread
        self.clock = clock
        self.freshID = freshID
        self.now = now
    }

    public var report: SyncReport { locked { current } }

    @discardableResult public func observe(_ observer: @escaping (SyncReport) -> Void) -> UUID {
        locked {
            let id = UUID()
            observers[id] = observer
            publish()
            return id
        }
    }

    public func removeObserver(_ id: UUID) { locked { observers[id] = nil } }

    /// Account work shares this graph's journal and library mutation gate.
    /// A different account retires possibly-sent requests to private evidence;
    /// same-account authentication recovers the exact request with the new token.
    func prepareAccount(binding: SyncLibraryIdentity, client: SyncHTTPClient, device: String,
                        intent: SyncAccountIntent) async throws {
        stop()
        await drain()
        let resume = try locked { () throws -> Bool in
            try requireAccountGraph(root: binding.root)
            try requireAccountCommit(journal.replay())
            let owned = try accounts.binding(for: binding.root)
            let inventory = try SyncGroupFolders.inventory(binding: binding, availability: .available, mutations: mutations)
            try SyncGroupFolders.preflight(inventory, ownership: owned)
            if intent == .startup, let owned, owned.owner != binding.account { throw SyncError.bindingMismatch }

            guard let request = try pending.recoverForAccountTransition() else { return false }
            if request.binding != binding {
                guard intent == .login else { throw SyncError.bindingMismatch }
                try pending.retainHeld(request)
                try pending.clear()
                return false
            }
            session = Session(binding: binding, client: client, device: device)
            current.needsSignIn = false
            coordinator = try makeCoordinator()
            return true
        }
        if resume { try await recoverJournal() }

        try locked {
            try requireAccountGraph(root: binding.root)
            var old = try states.loadForAccountTransition()
            let owned = try accounts.binding(for: binding.root)
            if let owned, owned.owner != binding.account {
                guard intent == .login else { throw SyncError.bindingMismatch }
                let previous = SyncLibraryIdentity(account: owned.owner, root: binding.root)
                guard old == nil || old?.binding.root != binding.root || old?.binding == previous else {
                    throw SyncError.bindingMismatch
                }
                // A state for another root is not deletion evidence here.
                if let existing = old, existing.binding.root != binding.root {
                    try states.clear()
                    old = nil
                }
                let inventory = try SyncGroupFolders.inventory(binding: previous, availability: .available, mutations: mutations)
                if let plan = try SyncGroupFolders.accountChange(to: binding.account, state: old, ownership: owned,
                    inventory: inventory, at: clock.now(), freshID: freshID, mutations: mutations) {
                    try requireAccountCommit(journal.apply(plan))
                }
            } else if owned == nil {
                guard old == nil || old?.binding.root != binding.root || old?.binding.account == binding.account else {
                    throw SyncError.bindingMismatch
                }
                let inventory = try SyncGroupFolders.inventory(binding: binding, availability: .available, mutations: mutations)
                try SyncGroupFolders.preflight(inventory, ownership: nil)
                try accounts.updateBinding(for: binding.root) { previous in
                    guard previous == nil else { throw SyncError.bindingMismatch }
                    return try SyncLibraryBinding(root: binding.root, owner: binding.account)
                }
            }
            let state = try states.loadForAccountTransition()
            if intent == .startup, state?.binding.root == binding.root, state?.binding.account != binding.account {
                throw SyncError.bindingMismatch
            }
            if state?.binding != binding { try states.reset(for: binding) }
        }
    }

    /// Logout never retries a pending network write. Local apply recovery and
    /// durable request retention precede clearing state; failures keep recovery.
    func prepareSignOut(root: SyncLibraryRoot) async throws {
        stop()
        await drain()
        try locked {
            guard !running, !retired else { throw SyncPushError.busy }
            if journal.pending != nil || mutations.pendingPermit != nil || mutations.hasUnreadableJournal {
                try requireAccountGraph(root: root)
                try requireAccountCommit(journal.replay())
            }
            if let request = try pending.recoverForAccountTransition() {
                try pending.retainHeld(request)
                try pending.clear()
            }
            try states.clear()
            session = nil
            coordinator = nil
            current.needsSignIn = false
            current.blockingIssue = nil
            current.counts = SyncCounts()
            current.details = []
            current.lastSuccess = nil
            publish()
        }
    }

    private func requireAccountGraph(root: SyncLibraryRoot) throws {
        guard !running, !retired else { throw SyncPushError.busy }
        guard health == .available else { throw SyncReconciliationError.unavailableLibrary }
        guard journal.pending == nil || journal.pending?.nextState.binding.root == root else {
            throw SyncError.bindingMismatch
        }
    }

    private func requireAccountCommit(_ outcome: SyncApplyOutcome) throws {
        guard outcome == .committed else { throw SyncCoordinatorError.recoveryRequired }
    }

    /// Y11 calls this only after authenticating and committing account/ownership.
    /// Same-account reauthentication creates a new epoch and resumes exact intents.
    func start(binding: SyncLibraryIdentity, client: SyncHTTPClient, device: String) throws {
        try locked {
            guard !retired, !running else { throw SyncPushError.busy }
            coordinator?.permit.revoke()
            invalidateTimers()
            epoch &+= 1
            session = Session(binding: binding, client: client, device: device)
            coordinator = try makeCoordinator()
            current.enabled = true
            current.needsSignIn = false
            current.offline = false
            current.retrying = false
            current.blockingIssue = health == .unavailable ? .rootUnavailable : nil
            current.phase = .idle
            current.lastSuccess = nil
            current.counts = SyncCounts()
            current.details = []
            backoff = nil
            retryAt = nil
            dirty = true
            automaticReruns = 0
            publish()
            if health == .available { armPoll(); launch() }
        }
    }

    public func syncNow() {
        locked {
            guard eligible else { return }
            // An explicit intent bypasses transient backoff, but never 401 or a
            // blocking state/protocol/recovery error.
            retryToken &+= 1
            retryAt = nil
            saveToken &+= 1
            dirty = true
            automaticReruns = 0
            launch()
        }
    }

    public func localSave() { locked { debounceSave() } }

    /// Always refresh the index/editor independently of this scheduling intent.
    /// Each event is checked; a mixed own/external batch still schedules a pass.
    /// Call off UI, alongside the native watcher's checked stamp/hash read.
    public func filesChanged(_ changes: [SyncFileChange]) {
        let active = locked { coordinator }
        guard !changes.isEmpty else { return }
        if changes.allSatisfy({ active?.permit.owns($0, library: mutations) == true }) { return }
        localSave()
    }

    @discardableResult public func stop() -> SyncStopResult {
        locked {
            current.enabled = false
            return stopWork()
        }
    }

    /// Sign-out retires authentication even if local journal cleanup fails.
    /// Deferred graph recovery must never retry HTTP with this credential.
    func stopAccountSession() {
        locked {
            current.enabled = false
            _ = stopWork()
            session = nil
            coordinator = nil
        }
    }

    func requireSignIn() {
        locked {
            current.enabled = false
            current.needsSignIn = true
            _ = stopWork()
        }
    }

    @discardableResult public func retire() -> SyncStopResult {
        locked {
            current.enabled = false
            let result = stopWork()
            if result == .stopped { retired = true }
            return result
        }
    }

    /// Await only off the UI thread before replacing any graph capability.
    /// The caller must still check retire's result for a pending apply journal.
    public func drain() async {
        let active = locked { task }
        await active?.value
    }

    /// After stop/drain, recover on the original root before attempting retire
    /// again. A 401 still requires Y11 reauthentication; this cannot bypass it.
    public func recoverJournal() async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            locked {
                do {
                    guard !running, !retired, health == .available, !current.needsSignIn else {
                        throw SyncPushError.busy
                    }
                    invalidateTimers()
                    epoch &+= 1
                    guard let active = try makeCoordinator() else { throw SyncError.invalidAccount }
                    coordinator = active
                    current.enabled = false
                    running = true
                    let generation = epoch
                    task = Task { [weak self, active] in
                        let result: Result<Void, Error>
                        do { try await active.recoverJournal(); result = .success(()) }
                        catch { result = .failure(error) }
                        self?.locked {
                            guard let self else { return }
                            self.running = false
                            self.task = nil
                            if self.epoch == generation, case .failure(let error) = result {
                                self.handle(error)
                                self.publish()
                            } else if self.epoch == generation {
                                self.current.blockingIssue = nil
                                self.publish()
                            }
                        }
                        completion.resume(with: result)
                    }
                } catch { completion.resume(throwing: error) }
            }
        }
    }

    @discardableResult public func rootHealthChanged(_ health: SyncRootHealth) -> SyncStopResult {
        locked {
            guard self.health != health else { return running ? .busy : recoveryState() }
            self.health = health
            if health == .unavailable {
                current.blockingIssue = .rootUnavailable
                return stopWork()
            }
            guard !retired else { return recoveryState() }
            current.blockingIssue = nil
            if running { dirty = current.enabled; return .busy }
            do { coordinator = try makeCoordinator() }
            catch { current.blockingIssue = .invalidState; publish(); return .recoveryRequired }
            publish()
            if current.enabled { dirty = true; armPoll(); launch() }
            return recoveryState()
        }
    }

    private var eligible: Bool {
        current.enabled && !retired && health == .available && !current.needsSignIn && current.blockingIssue == nil
    }

    private func makeCoordinator() throws -> SyncCoordinator? {
        guard let session else { return nil }
        return try SyncCoordinator(binding: session.binding, epoch: epoch, client: session.client,
            files: files, states: states, accounts: accounts, mutations: mutations, journal: journal, pending: pending,
            device: session.device, freshID: freshID, date: clock.now, now: now)
    }

    private func launch() {
        guard eligible, !running, dirty, coordinator != nil else { return }
        if let retryAt, now() < retryAt { return }
        guard let active = coordinator else { return }
        running = true
        dirty = false
        current.counts.pulled = 0
        current.counts.pushed = 0
        current.phase = .recovering
        publish()
        let generation = active.permit.epoch
        task = Task { [weak self, active] in
            do {
                let result = try await active.run(progress: { [weak self] result in
                    self?.locked {
                        guard let self, self.epoch == generation, self.eligible else { return }
                        self.current.counts = result.counts
                        self.current.details = result.details
                        self.publish()
                    }
                }) { [weak self] phase in self?.setPhase(phase, epoch: generation) }
                self?.finished(.success(result), epoch: generation)
            } catch { self?.finished(.failure(error), epoch: generation) }
        }
    }

    private func setPhase(_ phase: SyncPhase, epoch generation: UInt64) {
        locked {
            guard epoch == generation, eligible else { return }
            current.phase = phase
            publish()
        }
    }

    private func finished(_ result: Result<SyncPassResult, Error>, epoch generation: UInt64) {
        locked {
            running = false
            task = nil
            guard epoch == generation else {
                // A lost root may have recovered while the canceled task drained.
                if eligible && dirty {
                    do { coordinator = try makeCoordinator(); armPoll(); launch() }
                    catch { current.blockingIssue = .invalidState; publish() }
                }
                return
            }
            guard eligible else { return }
            current.phase = .idle
            switch result {
            case .success(let pass):
                current.counts = pass.counts
                current.details = pass.details
                current.offline = false
                current.retrying = false
                if !pass.rerun && pass.counts.fileErrors == 0 { backoff = nil }
                retryAt = nil
                retryToken &+= 1
                if pass.counts.fileErrors == 0 && !pass.rerun { current.lastSuccess = clock.now() }
                let triggered = dirty
                dirty = dirty || pass.rerun
                publish()
                // File errors/denials do not create an immediate retry loop.
                if pass.rerun, !triggered, automaticReruns >= Limits.syncImmediateRerunLimit {
                    current.retrying = true
                    retry(after: nil)
                    publish()
                } else if triggered || pass.rerun || pass.counts.fileErrors == 0 {
                    automaticReruns = pass.rerun && !triggered ? automaticReruns + 1 : 0
                    launch()
                }
            case .failure(let error):
                handle(error)
                publish()
            }
        }
    }

    private func handle(_ error: Error) {
        if let error = error as? SyncHTTPClientError {
            switch error {
            case .unauthorized:
                current.needsSignIn = true
                invalidateTimers()
                dirty = false
            case .transport(.networkFailure), .transport(.deadlineExceeded), .serverFailure, .rateLimited:
                current.offline = true
                retry(after: error)
            case .transport(.cancelled): break
            default: current.blockingIssue = .invalidProtocol; invalidateTimers()
            }
            return
        }
        if let error = error as? SyncPullCollectorError {
            if case .noProgress = error { current.retrying = true; retry(after: nil); return }
            current.blockingIssue = .invalidProtocol
        } else if let error = error as? SyncCoordinatorError {
            switch error {
            case .noProgress: current.retrying = true; retry(after: nil); return
            case .fileErrors:
                // Visibility/input holds remain repairable; a repeated unchanged
                // error is polled, never turned into an immediate retry loop.
                if let session, let state = try? states.load(for: session.binding) {
                    current.details = state.prompts.values.compactMap { record in
                        guard let error = record.lastError,
                              let path = try? SyncLocalScanner.rooted(record.path, scope: record.scope, groups: state.groups) else { return nil }
                        return SyncFileDetail(path: path, code: error.code.rawValue)
                    }.sorted { $0.path < $1.path }
                }
                current.counts.fileErrors = max(1, current.details.count)
                return
            case .recoveryRequired: current.blockingIssue = .recoveryRequired
            }
        } else if error is SyncReconciliationError || error is SyncConflictPolicyError {
            current.blockingIssue = .invalidProtocol
        } else if error is SyncPushError || error is LibraryError || error is SyncFileOperationError {
            current.blockingIssue = .recoveryRequired
        } else { current.blockingIssue = .invalidState }
        invalidateTimers()
    }

    private func debounceSave() {
        guard eligible else { return }
        saveToken &+= 1
        let token = saveToken
        let generation = epoch
        scheduler.after(Limits.syncDebounce) { [weak self] in
            self?.locked {
                guard let self, self.epoch == generation, self.saveToken == token, self.eligible else { return }
                self.dirty = true
                self.automaticReruns = 0
                self.launch()
            }
        }
    }

    private func armPoll() {
        pollToken &+= 1
        let token = pollToken
        let generation = epoch
        scheduler.after(Limits.syncInterval) { [weak self] in
            self?.locked {
                guard let self, self.epoch == generation, self.pollToken == token, self.eligible else { return }
                self.dirty = true
                self.automaticReruns = 0
                self.armPoll()
                self.launch()
            }
        }
    }

    private func retry(after error: SyncHTTPClientError?) {
        let delay = min((backoff ?? (Limits.syncBackoffMin / 2)) * 2, Limits.syncBackoffMax)
        backoff = delay
        let effective: Duration
        if case .rateLimited(let value) = error { effective = max(delay, .seconds(value.seconds)) }
        else { effective = delay }
        retryAt = now().advanced(by: effective)
        dirty = true
        retryToken &+= 1
        let token = retryToken
        let generation = epoch
        scheduler.after(effective) { [weak self] in
            self?.locked {
                guard let self, self.epoch == generation, self.retryToken == token, self.eligible else { return }
                self.retryAt = nil
                self.launch()
            }
        }
    }

    private func invalidateTimers() { pollToken &+= 1; saveToken &+= 1; retryToken &+= 1 }

    private func stopWork() -> SyncStopResult {
        invalidateTimers()
        epoch &+= 1
        let drained = coordinator?.permit.revoke() ?? true
        task?.cancel()
        dirty = false
        retryAt = nil
        current.phase = .idle
        publish()
        return running || !drained ? .busy : recoveryState()
    }

    private func recoveryState() -> SyncStopResult {
        guard journal.pending == nil, !mutations.hasUnreadableJournal else { return .recoveryRequired }
        let snapshot = pending.snapshot
        if snapshot.error != nil || snapshot.value != nil { return .recoveryRequired }
        return .stopped
    }

    private func publish() {
        publication &+= 1
        let version = publication
        let generation = epoch
        let report = current
        for id in observers.keys {
            main.run { [weak self] in
                self?.locked {
                    guard let self, self.epoch == generation, self.publication == version,
                          let observer = self.observers[id] else { return }
                    observer(report)
                }
            }
        }
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
