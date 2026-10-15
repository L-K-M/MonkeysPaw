/// Path-free reasons for refusing a library folder. Existing composition
/// results map losslessly through rejectedByStore; platforms may refine them.
public enum LibraryTargetError: Equatable, Sendable {
    case notAbsolute
    case missing
    case notDirectory
    case unreadable
    case symlink
    case outsideSandboxHome
    case rejectedByStore(FileStoreError)
}

/// Shared result of the desktop composition roots' library replacement.
/// Errors carry neither paths, prompt content nor underlying tool error text.
public enum LibrarySwitchOutcome: Equatable, Sendable {
    case switched
    case settingsNotSaved(SettingsError)
    case deliveryInFlight
    /// The current graph is retained, with repeat disabled until a durable retry.
    case repeatInvalidationFailed
    case invalidTarget(LibraryTargetError)
    /// The graph changed, but its watcher or initial rebuild could not start.
    case libraryUnavailable(FileStoreError)
}
