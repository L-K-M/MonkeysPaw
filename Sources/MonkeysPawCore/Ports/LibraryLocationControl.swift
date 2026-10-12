/// UI-thread composition operations for General and onboarding (§11.1, §11.4).
/// Only the platform composition root replaces drivers and the library graph.
public protocol LibraryLocationControl {
    /// The running graph's folder, even when saving its choice failed.
    var activeLibraryPath: String { get }
    var defaultLibraryPath: String { get }

    /// Nil selects the platform default. Refused/invalid targets retain the
    /// graph; settingsNotSaved and libraryUnavailable follow its replacement.
    /// Persistence uses the same SettingsModel supplied to the presentation models.
    func switchLibrary(to path: String?) -> LibrarySwitchOutcome

    /// Reveal the active folder through the platform's file manager.
    func revealLibrary()
}
