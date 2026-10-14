import Foundation

public struct UpdateRateLimit: Equatable, Sendable {
    public let statusCode: Int
    public let until: Date
}

/// Fixed, sanitized outcomes. No response bodies, raw versions or URLs escape.
public enum UpdateCheckFailure: Error, Equatable, Sendable {
    case unversionedBuild
    case invalidCurrentVersion
    case malformedResponse
    case rateLimited(UpdateRateLimit)
    case offline
    case transport(HTTPTransportError)
    case httpStatus(Int)
}

public enum UpdateCheckResult: Equatable, Sendable {
    case notChecked
    case updateAvailable(ReleaseVersion)
    case upToDate
    case noRelease
    case unavailable(UpdateCheckFailure)
}

public struct UpdateSnapshot: Equatable, Sendable {
    public let currentVersion: ReleaseVersion?
    public let result: UpdateCheckResult
    public let isChecking: Bool
    public let lastAutomaticAttempt: Date?
    public let lastSuccessfulCheck: Date?
    public let rateLimit: UpdateRateLimit?
    public let stateError: UpdateStateError?
    public let canOpenRelease: Bool
    public let releasePageOpeningFailed: Bool
}

/// Composition explicitly starts automatic checks only for a versioned,
/// non-test runtime. Construction and Settings refresh never send HTTP.
/// One worker queue owns state, I/O, generations and the single network task;
/// timers, browser operations and all publications use the injected UI loop.
public final class UpdateService: @unchecked Sendable {
    private enum Origin { case automatic, manual }
    private struct Flight {
        let id: UUID
        let origin: Origin
        var discarded = false
    }

    private let client: GitHubReleaseClient
    private let settings: SettingsService
    private let store: UpdateStateStore
    private let clock: WallClock
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private let releasePage: ReleasePageOpening
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.updates")
    private let observers = ChangeObservers<UpdateSnapshot>()
    private let currentVersion: ReleaseVersion?
    private var record = UpdateStateRecord()
    private var stateError: UpdateStateError?
    private var result = UpdateCheckResult.notChecked
    private var release: GitHubReleaseClient.Release?
    private var openingFailed = false
    private var flight: Flight?
    private var networkTask: Task<Void, Never>?
    private var timerGeneration = UUID()
    private var monitoring = false
    private var retired = false

    /// Pass the full packaged version (hyphenated prerelease included). Nil is
    /// an unversioned development/test build, never a guessed 0.0.0 fallback.
    public init(transport: HTTPTransporting, currentVersion: String?, settings: SettingsService,
                stateStore: UpdateStateStore, clock: WallClock, scheduler: Scheduler,
                mainThread: MainThread, releasePage: ReleasePageOpening) {
        client = GitHubReleaseClient(transport: transport)
        self.currentVersion = currentVersion.flatMap(ReleaseVersion.init)
        self.settings = settings
        store = stateStore
        self.clock = clock
        self.scheduler = scheduler
        self.mainThread = mainThread
        self.releasePage = releasePage
        if self.currentVersion == nil {
            result = .unavailable(currentVersion == nil ? .unversionedBuild : .invalidCurrentVersion)
        }
    }

    deinit { networkTask?.cancel() }

    public func startAutomaticChecks() {
        queue.async {
            guard !self.retired else { return }
            self.monitoring = true
            self.reconcilePolicy()
        }
    }

    /// Call after committed shared preference changes. Disabling cancels and
    /// ignores automatic work; it never cancels an explicit manual request.
    public func refreshAutomaticPolicy() {
        queue.async {
            guard !self.retired else { return }
            self.reconcilePolicy()
        }
    }

    /// Permanent graph/shutdown retirement. Timer closures are weak and their
    /// generations retire even when the platform Scheduler cannot remove them.
    public func stop() {
        queue.async {
            self.retired = true
            self.monitoring = false
            self.timerGeneration = UUID()
            self.discardFlight()
        }
    }

    func checkNow() {
        queue.async {
            guard !self.retired, self.flight == nil, let current = self.currentVersion else { return }
            self.loadRecord()
            let now = self.clock.now()
            if let limit = self.record.rateLimit, now < limit.until {
                self.result = .unavailable(.rateLimited(limit))
                self.release = nil
                self.publish()
                return
            }
            self.timerGeneration = UUID()
            self.begin(.manual, current: current)
        }
    }

    func readStatus(_ completion: @escaping (UpdateSnapshot) -> Void) {
        queue.async {
            self.loadRecord()
            let snapshot = self.snapshot
            self.mainThread.run { completion(snapshot) }
        }
    }

    @discardableResult
    func addObserver(_ observer: @escaping @Sendable (UpdateSnapshot) -> Void) -> UUID {
        observers.add(observer)
    }

    func removeObserver(_ token: UUID) { observers.remove(token) }

    func openReleasePage() {
        queue.async { [self] in
            guard !self.retired, let release = self.release,
                  self.result == .updateAvailable(release.version) else { return }
            self.mainThread.run { [weak self, releasePage = self.releasePage] in
                guard let self else { return }
                releasePage.openReleasePage(release.page) { [weak self] outcome in
                    self?.queue.async { [weak self] in
                        guard let self, !self.retired, self.release == release else { return }
                        self.openingFailed = outcome == .failed
                        self.publish()
                    }
                }
            }
        }
    }

    private func reconcilePolicy() {
        timerGeneration = UUID()
        loadRecord()
        let allowed = settings.snapshot.allowsAutomaticUpdateChecks && currentVersion != nil && stateError == nil
        if !allowed, flight?.origin == .automatic { discardFlight() }
        publish()
        guard monitoring, allowed, flight == nil, let current = currentVersion else { return }
        let now = clock.now()
        let due = max(record.nextAutomaticCheck ?? now, record.rateLimit?.until ?? now)
        if now < due { schedule(at: due); return }

        do {
            guard let claimed = try store.claimAutomaticAttempt(at: now) else {
                loadRecord()
                schedule(at: max(record.nextAutomaticCheck ?? now.addingTimeInterval(Limits.updateCheckInterval),
                                 record.rateLimit?.until ?? now))
                return
            }
            record = claimed
            begin(.automatic, current: current)
        } catch {
            stateError = error as? UpdateStateError ?? .writeFailed(.ioFailure)
            publish()
        }
    }

    private func begin(_ origin: Origin, current: ReleaseVersion) {
        let id = UUID()
        flight = Flight(id: id, origin: origin)
        openingFailed = false
        // Install the task before observers can disable/re-enter this service.
        networkTask = Task { [weak self, client, settings, clock] in
            let outcome: Result<GitHubReleaseClient.Release?, UpdateCheckFailure>
            do {
                if origin == .automatic, !settings.snapshot.allowsAutomaticUpdateChecks {
                    throw UpdateCheckFailure.transport(.cancelled)
                }
                outcome = .success(try await client.latestRelease(currentVersion: current, now: { clock.now() }))
            } catch let failure as UpdateCheckFailure { outcome = .failure(failure) }
            catch { outcome = .failure(.offline) }
            self?.queue.async { [weak self] in self?.finish(id: id, outcome: outcome) }
        }
        publish()
    }

    private func finish(id: UUID, outcome: Result<GitHubReleaseClient.Release?, UpdateCheckFailure>) {
        guard let flight, flight.id == id else { return }
        self.flight = nil
        networkTask = nil
        guard !retired else { return }
        if flight.discarded || (flight.origin == .automatic && !settings.snapshot.allowsAutomaticUpdateChecks) {
            publish()
            scheduleNext()
            return
        }

        release = nil
        switch outcome {
        case .success(let latest):
            if let latest, let currentVersion, latest.version > currentVersion {
                release = latest
                result = .updateAvailable(latest.version)
            } else { result = latest == nil ? .noRelease : .upToDate }
            do { record = try store.recordSuccess(at: clock.now()); stateError = nil }
            catch { stateError = error as? UpdateStateError ?? .writeFailed(.ioFailure) }
        case .failure(let failure):
            result = .unavailable(failure)
            if case .rateLimited(let limit) = failure {
                record.rateLimit = limit
                do { record = try store.recordRateLimit(limit, at: clock.now()); stateError = nil }
                catch { stateError = error as? UpdateStateError ?? .writeFailed(.ioFailure) }
            }
        }
        publish()
        // A manual failure must not immediately provoke a second automatic request.
        scheduleNext(minimumDelay: flight.origin == .manual ? Limits.updateCheckInterval : 0)
    }

    private func scheduleNext(minimumDelay: TimeInterval = 0) {
        guard monitoring, !retired, settings.snapshot.allowsAutomaticUpdateChecks,
              currentVersion != nil, stateError == nil, flight == nil else { return }
        let now = clock.now()
        let due = max(now.addingTimeInterval(minimumDelay),
                      max(record.nextAutomaticCheck ?? now.addingTimeInterval(Limits.updateCheckInterval),
                          record.rateLimit?.until ?? now))
        schedule(at: due)
    }

    private func schedule(at due: Date) {
        let generation = UUID()
        timerGeneration = generation
        // Re-evaluate long server waits and clock changes daily, without traffic.
        let seconds = min(Limits.updateCheckInterval, max(0, due.timeIntervalSince(clock.now())))
        mainThread.run { [weak self, scheduler] in
            scheduler.after(.seconds(seconds)) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, !self.retired, self.timerGeneration == generation else { return }
                    self.reconcilePolicy()
                }
            }
        }
    }

    private func discardFlight() {
        flight?.discarded = true
        networkTask?.cancel()
        // Keep the slot until even a noncooperative transport has returned.
    }

    private func loadRecord() {
        do {
            var loaded = try store.read(at: clock.now())
            // Preserve an in-memory backoff when persisting it failed.
            if let known = record.rateLimit, known.until > (loaded.rateLimit?.until ?? .distantPast) {
                loaded.rateLimit = known
            }
            record = loaded
            // Reading successfully does not prove a failed write was repaired.
            if case .writeFailed = stateError {} else { stateError = nil }
        } catch { stateError = error as? UpdateStateError ?? .readFailed(.ioFailure) }
    }

    private var snapshot: UpdateSnapshot {
        UpdateSnapshot(currentVersion: currentVersion, result: result, isChecking: flight != nil,
            lastAutomaticAttempt: record.lastAutomaticAttempt, lastSuccessfulCheck: record.lastSuccessfulCheck,
            rateLimit: record.rateLimit, stateError: stateError, canOpenRelease: release != nil,
            releasePageOpeningFailed: openingFailed)
    }

    private func publish() {
        let snapshot = self.snapshot
        let tokens = observers.capture()
        mainThread.run { [observers] in observers.publish(tokens, event: snapshot) }
    }
}
