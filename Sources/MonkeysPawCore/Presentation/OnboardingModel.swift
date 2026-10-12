import Foundation

/// First-run steps 1, 2 and 4 (§11.4). Construct/release on the UI thread;
/// intents and publications use MainThread. Setup itself remains in SetupModel.
/// Composition retains one instance so recovery survives closing its window.
public final class OnboardingModel {
    public enum Step: Equatable, Sendable {
        case setup
        case libraryFolder
        case seedOffer
        /// No step is currently eligible, including suppressed read-only steps.
        case complete
    }

    public struct State: Equatable, Sendable {
        public let step: Step
        public let isReadOnly: Bool
        public let settingsError: SettingsError?
        public let libraryStatus: LibraryStatusModel.State
        public let lastSwitchMessage: LibrarySwitchOutcome?
        public let seedSummary: SeedSummary?
        public let seedFailure: SeedFailure?
    }

    /// One owner: the native onboarding view. Shared settings/status observers
    /// remain independent of this hook.
    public var onChange: (() -> Void)?
    public private(set) var state: State

    private let settings: SettingsModel
    private let library: LibraryLocationControl
    private let status: LibraryStatusModel
    private let mainThread: MainThread
    private let isLibraryEmpty: () throws -> Bool
    private let hasConfiguredSyncServer: () -> Bool
    private let seedIfEmpty: () throws -> SeedSummary
    private var settingsObserver: UUID?
    private var statusObserver: UUID?
    private var isPerformingIntent = false
    private var recoveryFolderRequired: Bool
    private var lastSwitchMessage: LibrarySwitchOutcome?
    private var seedSummary: SeedSummary?
    private var seedingFailure: SeedFailure?

    /// Service closures must resolve the active graph at call time, including
    /// after a folder switch. isLibraryEmpty uses LibraryService.entries(), so
    /// malformed eligible prompts still block the offer. Until M6, inject false
    /// for hasConfiguredSyncServer. Calls are synchronous on the UI thread.
    public init(settings: SettingsModel, library: LibraryLocationControl,
                status: LibraryStatusModel, mainThread: MainThread,
                isLibraryEmpty: @escaping () throws -> Bool,
                hasConfiguredSyncServer: @escaping () -> Bool,
                seedIfEmpty: @escaping () throws -> SeedSummary) {
        self.settings = settings
        self.library = library
        self.status = status
        self.mainThread = mainThread
        self.isLibraryEmpty = isLibraryEmpty
        self.hasConfiguredSyncServer = hasConfiguredSyncServer
        self.seedIfEmpty = seedIfEmpty
        recoveryFolderRequired = status.needsLibraryFolderStep
        let initialStep: Step = settings.isReadOnly ? .complete
            : settings.needsSetupPresentation ? .setup
            : settings.needsLibraryFolderStep || status.needsLibraryFolderStep ? .libraryFolder : .complete
        state = State(step: initialStep, isReadOnly: settings.isReadOnly,
            settingsError: settings.error, libraryStatus: status.state,
            lastSwitchMessage: nil, seedSummary: nil, seedFailure: nil)

        settingsObserver = settings.addObserver { [weak self] _, _ in
            guard let self, !self.isPerformingIntent else { return }
            self.mainThread.run { [weak self] in self?.publish() }
        }
        statusObserver = status.addObserver { [weak self] health in
            guard let self else { return }
            // Status observers already run through MainThread. Latch recovery
            // until a folder completion succeeds, even if a graph becomes healthy
            // before its choice/progress can be saved.
            if health == .unavailableAtStartup { self.recoveryFolderRequired = true }
            guard !self.isPerformingIntent else { return }
            self.publish()
        }
        mainThread.run { [weak self] in self?.publish() }
    }

    deinit {
        if let settingsObserver { settings.removeObserver(settingsObserver) }
        if let statusObserver { status.removeObserver(statusObserver) }
    }

    /// Call after the existing Setup window has actually been presented.
    /// Composition continues recording its legacy Setup fact for downgrades.
    public func markSetupPresented() {
        mainThread.run {
            guard !self.isPerformingIntent, self.settings.needsSetupPresentation else { return }
            self.perform { self.settings.markSetupPresented() }
        }
    }

    public func useDefaultFolder() {
        mainThread.run {
            guard self.canCompleteFolder else { return }
            self.perform { self.switchLibrary(to: nil) }
        }
    }

    public func chooseFolder(_ path: String) {
        mainThread.run {
            guard self.canCompleteFolder else { return }
            self.perform {
                let saved = self.settings.libraryFolderPath ?? self.library.defaultLibraryPath
                // Unlike General's saved-folder shortcut, onboarding also needs
                // graph health: a failed startup must retry through composition.
                if self.status.libraryAvailable,
                   GeneralSettingsModel.sameFolder(path, self.library.activeLibraryPath),
                   GeneralSettingsModel.sameFolder(saved, path) {
                    self.lastSwitchMessage = nil
                    self.completeFolder()
                    return
                }
                self.switchLibrary(to: GeneralSettingsModel.sameFolder(path, self.library.defaultLibraryPath) ? nil : path)
            }
        }
    }

    public func acceptSeeds() {
        mainThread.run {
            guard self.canRecordSeedOffer else { self.publish(); return }
            self.perform {
                self.settings.markSeedsOffered()
                guard self.settings.error == nil, self.settings.firstRun.seedsOffered else { return }
                // The durable flag precedes every create. A partial failure is
                // shown once and cannot cause another copy after a restart.
                do {
                    self.seedSummary = try self.seedIfEmpty()
                    self.seedingFailure = nil
                } catch {
                    self.seedingFailure = SeedFailure(sanitizing: error)
                }
            }
        }
    }

    public func declineSeeds() {
        mainThread.run {
            guard self.canRecordSeedOffer else { self.publish(); return }
            self.perform { self.settings.markSeedsOffered() }
        }
    }

    /// Recheck server/emptiness predicates and changes made through the shared
    /// settings service. A non-empty library does not consume the offer flag.
    public func refresh() {
        mainThread.run { [weak self] in
            guard let self, !self.isPerformingIntent else { return }
            self.perform { self.settings.refresh() }
        }
    }

    private var canCompleteFolder: Bool {
        !isPerformingIntent && !settings.isReadOnly && !settings.needsSetupPresentation
            && status.state != .lostWhileRunning
            && (settings.needsLibraryFolderStep || recoveryFolderRequired)
    }

    private var canRecordSeedOffer: Bool {
        !isPerformingIntent && state.step == .seedOffer && settings.needsSeedOffer
            && !settings.needsSetupPresentation && !settings.needsLibraryFolderStep
            && !recoveryFolderRequired && status.libraryAvailable && !hasConfiguredSyncServer()
    }

    private func switchLibrary(to path: String?) {
        let outcome = library.switchLibrary(to: path)
        lastSwitchMessage = outcome == .switched ? nil : outcome
        guard outcome == .switched else { return }
        completeFolder()
    }

    private func completeFolder() {
        settings.completeLibraryFolderStep()
        guard settings.error == nil, settings.firstRun.libraryFolderCompleted else { return }
        // Recovery is session-local. Never clear the persisted completion flag.
        recoveryFolderRequired = false
    }

    private func perform(_ intent: () -> Void) {
        isPerformingIntent = true
        intent()
        isPerformingIntent = false
        publish()
    }

    private func publish() {
        var step = Step.complete
        var failure = seedingFailure
        if !settings.isReadOnly {
            if settings.needsSetupPresentation { step = .setup }
            else if settings.needsLibraryFolderStep || recoveryFolderRequired { step = .libraryFolder }
            else if settings.needsSeedOffer, status.libraryAvailable, !hasConfiguredSyncServer() {
                do {
                    if try isLibraryEmpty() { step = .seedOffer }
                } catch { failure = SeedFailure(sanitizing: error) }
            }
        }
        let next = State(step: step, isReadOnly: settings.isReadOnly,
            settingsError: settings.error, libraryStatus: status.state,
            lastSwitchMessage: lastSwitchMessage, seedSummary: seedSummary, seedFailure: failure)
        guard next != state else { return }
        state = next
        onChange?()
    }
}
