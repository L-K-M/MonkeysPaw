/// Field-specific intents preserve every unrelated preference and flag (§11).
/// File access and atomic publication belong to the injected SettingsStore.
public final class SettingsService: Sendable {
    private enum Step { case setup, libraryFolder, seeds, tour }

    private let store: SettingsStore

    public init(store: SettingsStore) { self.store = store }

    public var snapshot: SettingsSnapshot { store.snapshot }

    /// Nil selects the platform default; no filesystem resolution occurs here.
    public func setLibraryFolder(_ path: String?) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: path, firstRun: document.firstRun,
                delivery: document.delivery, automaticUpdateChecks: document.automaticUpdateChecks,
                creepy: document.creepy, carbonShortcuts: document.carbonShortcuts)
        }
    }

    public func setLinuxDefaultPasteChord(_ chord: PasteChord) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: document.libraryFolderPath, firstRun: document.firstRun,
                delivery: DeliveryPreferences(linuxDefaultPasteChord: chord,
                    clipboardRestore: document.delivery.clipboardRestore),
                automaticUpdateChecks: document.automaticUpdateChecks, creepy: document.creepy,
                carbonShortcuts: document.carbonShortcuts)
        }
    }

    public func setClipboardRestore(_ mode: ClipboardRestoreMode) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: document.libraryFolderPath, firstRun: document.firstRun,
                delivery: DeliveryPreferences(linuxDefaultPasteChord: document.delivery.linuxDefaultPasteChord,
                    clipboardRestore: mode), automaticUpdateChecks: document.automaticUpdateChecks,
                creepy: document.creepy, carbonShortcuts: document.carbonShortcuts)
        }
    }

    public func setAutomaticUpdateChecks(_ mode: AutomaticUpdateChecks) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: document.libraryFolderPath, firstRun: document.firstRun,
                delivery: document.delivery, automaticUpdateChecks: mode, creepy: document.creepy,
                carbonShortcuts: document.carbonShortcuts)
        }
    }

    public func setCreepy(_ mode: CreepyMode) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: document.libraryFolderPath, firstRun: document.firstRun,
                delivery: document.delivery, automaticUpdateChecks: document.automaticUpdateChecks,
                creepy: mode, carbonShortcuts: document.carbonShortcuts)
        }
    }

    /// ShortcutService calls this only after the native action is confirmed.
    func setCarbonShortcut(_ action: HotkeyAction, accelerator: Accelerator?) throws {
        try store.update { document in
            try SettingsDocument(libraryFolderPath: document.libraryFolderPath, firstRun: document.firstRun,
                delivery: document.delivery, automaticUpdateChecks: document.automaticUpdateChecks,
                creepy: document.creepy,
                carbonShortcuts: document.carbonShortcuts.replacing(action, with: accelerator))
        }
    }

    public func markSetupPresented() throws { try complete(.setup) }
    public func completeLibraryFolderStep() throws { try complete(.libraryFolder) }
    public func markSeedsOffered() throws { try complete(.seeds) }
    public func completeTour() throws { try complete(.tour) }

    private func complete(_ step: Step) throws {
        try store.update { document in
            let progress = document.firstRun
            return try SettingsDocument(libraryFolderPath: document.libraryFolderPath,
                firstRun: FirstRunProgress(
                    setupPresented: progress.setupPresented || step == .setup,
                    libraryFolderCompleted: progress.libraryFolderCompleted || step == .libraryFolder,
                    seedsOffered: progress.seedsOffered || step == .seeds,
                    tourCompleted: progress.tourCompleted || step == .tour),
                delivery: document.delivery, automaticUpdateChecks: document.automaticUpdateChecks,
                creepy: document.creepy, carbonShortcuts: document.carbonShortcuts)
        }
    }
}
