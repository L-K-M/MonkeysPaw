import Foundation

/// Shared settings/onboarding state. Call synchronous intents on the UI thread;
/// onChange runs inline there, with no asynchronous service callbacks (§4.2).
/// Read-only settings suppress onboarding queries because progress cannot
/// persist; the UI shows the read-only error instead of repeating first run.
public final class SettingsModel {
    /// This hook has one owner, the front end's view. Assignment replaces it.
    public var onChange: (() -> Void)?
    public private(set) var state: SettingsSnapshot
    public private(set) var error: SettingsError?

    /// Nil is the default marker; composition supplies the resolved path.
    public var libraryFolderPath: String? { state.document.libraryFolderPath }
    public var firstRun: FirstRunProgress { state.document.firstRun }
    public var deliveryPreferences: DeliveryPreferences { state.document.delivery }
    public var automaticUpdateChecks: AutomaticUpdateChecks { state.document.automaticUpdateChecks }
    public var creepy: CreepyMode { state.document.creepy }
    public var allowsAutomaticUpdateChecks: Bool { state.allowsAutomaticUpdateChecks }
    public var isReadOnly: Bool { state.isReadOnly }
    public var needsSetupPresentation: Bool { !isReadOnly && !firstRun.setupPresented }
    public var needsLibraryFolderStep: Bool { !isReadOnly && !firstRun.libraryFolderCompleted }
    public var needsSeedOffer: Bool { !isReadOnly && !firstRun.seedsOffered }
    public var needsTourPresentation: Bool { !isReadOnly && !firstRun.tourCompleted }

    private let settings: SettingsService
    private var observers: [UUID: (SettingsSnapshot, SettingsError?) -> Void] = [:]

    public init(settings: SettingsService) {
        self.settings = settings
        state = settings.snapshot
        error = state.readOnlyError
    }

    /// Independent presentation subscribers do not replace the view's hook.
    /// Subscribe/remove on the UI thread. Observers receive real changes inline;
    /// removal applies after any notification already in progress.
    @discardableResult
    public func addObserver(_ observer: @escaping (SettingsSnapshot, SettingsError?) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Republish after another settings consumer changes the shared service.
    /// Clear transient intent errors; the store's read-only error stays visible.
    public func refresh() {
        let previousState = state
        let previousError = error
        state = settings.snapshot
        error = state.readOnlyError
        publish(from: previousState, error: previousError)
    }

    public func setLibraryFolder(_ path: String) {
        perform { try settings.setLibraryFolder(path) }
    }

    public func clearLibraryFolder() {
        perform { try settings.setLibraryFolder(nil) }
    }

    public func setLinuxDefaultPasteChord(_ chord: PasteChord) {
        perform { try settings.setLinuxDefaultPasteChord(chord) }
    }

    public func setClipboardRestore(_ mode: ClipboardRestoreMode) {
        perform { try settings.setClipboardRestore(mode) }
    }

    public func setAutomaticUpdateChecks(_ mode: AutomaticUpdateChecks) {
        perform { try settings.setAutomaticUpdateChecks(mode) }
    }

    public func setCreepy(_ mode: CreepyMode) {
        perform { try settings.setCreepy(mode) }
    }

    public func markSetupPresented() {
        perform { try settings.markSetupPresented() }
    }

    public func completeLibraryFolderStep() {
        perform { try settings.completeLibraryFolderStep() }
    }

    public func markSeedsOffered() {
        perform { try settings.markSeedsOffered() }
    }

    public func completeTour() {
        perform { try settings.completeTour() }
    }

    private func perform(_ intent: () throws -> Void) {
        let previousState = state
        let previousError = error
        do {
            try intent()
            error = nil
        } catch let failure as SettingsError { self.error = failure }
        catch { self.error = .writeFailed(.ioFailure) }
        state = settings.snapshot
        publish(from: previousState, error: previousError)
    }

    private func publish(from previousState: SettingsSnapshot, error previousError: SettingsError?) {
        if state != previousState || error != previousError {
            let snapshot = state
            let failure = error
            for observer in Array(observers.values) { observer(snapshot, failure) }
        }
        // Preserve the existing view hook's per-intent/refresh notification.
        onChange?()
    }
}
