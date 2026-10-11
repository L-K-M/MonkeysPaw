/// Settings intents keep unrelated first-run progress intact (§11.4).
/// File access and atomic publication belong to the injected SettingsStore.
public final class SettingsService: Sendable {
    private enum Step { case setup, libraryFolder, seeds }

    private let store: SettingsStore

    public init(store: SettingsStore) { self.store = store }

    public var snapshot: SettingsSnapshot { store.snapshot }

    /// Nil selects the platform default; no filesystem resolution occurs here.
    public func setLibraryFolder(_ path: String?) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: path, firstRun: document.firstRun)
        }
    }

    public func markSetupPresented() throws { try complete(.setup) }
    public func completeLibraryFolderStep() throws { try complete(.libraryFolder) }
    public func markSeedsOffered() throws { try complete(.seeds) }

    private func complete(_ step: Step) throws {
        try store.update { document in
            let progress = document.firstRun
            return try SettingsDocument(libraryFolderPath: document.libraryFolderPath,
                firstRun: FirstRunProgress(
                    setupPresented: progress.setupPresented || step == .setup,
                    libraryFolderCompleted: progress.libraryFolderCompleted || step == .libraryFolder,
                    seedsOffered: progress.seedsOffered || step == .seeds))
        }
    }
}
