/// General/onboarding state. Call synchronous intents on the UI thread;
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
    public var isReadOnly: Bool { state.isReadOnly }
    public var needsSetupPresentation: Bool { !isReadOnly && !firstRun.setupPresented }
    public var needsLibraryFolderStep: Bool { !isReadOnly && !firstRun.libraryFolderCompleted }
    public var needsSeedOffer: Bool { !isReadOnly && !firstRun.seedsOffered }

    private let settings: SettingsService

    public init(settings: SettingsService) {
        self.settings = settings
        state = settings.snapshot
        error = state.readOnlyError
    }

    /// Republish after another settings consumer changes the shared service.
    /// Clear transient intent errors; the store's read-only error stays visible.
    public func refresh() {
        state = settings.snapshot
        error = state.readOnlyError
        onChange?()
    }

    public func setLibraryFolder(_ path: String) {
        perform { try settings.setLibraryFolder(path) }
    }

    public func clearLibraryFolder() {
        perform { try settings.setLibraryFolder(nil) }
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

    private func perform(_ intent: () throws -> Void) {
        do {
            try intent()
            error = nil
        } catch let failure as SettingsError { self.error = failure }
        catch { self.error = .writeFailed(.ioFailure) }
        state = settings.snapshot
        onChange?()
    }
}
