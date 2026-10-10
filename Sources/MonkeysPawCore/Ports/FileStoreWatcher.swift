/// Driver-owned monitoring of the same canonical root as its FileStore.
/// Events describe regular files using store-relative POSIX paths. Drivers
/// exclude symlinks and paths outside the root, but do not filter prompts or
/// debounce. A rename produces a deletion at the old path and creation at
/// the new path. Directory changes include affected descendant files.
public protocol FileStoreWatcher {
    /// Idempotent while running; takes a baseline without emitting it. Missing
    /// roots are watched through existing ancestors without creating them.
    /// A failed start leaves the watcher stopped. The driver owns the callback
    /// thread; callers must not assume it is the UI thread.
    func start(_ onEvent: @escaping (FileStoreEvent) -> Void) throws
    /// Idempotent. Release monitors and discard events from the stopped run.
    func stop()
}

public struct FileStoreEvent: Equatable, Sendable {
    public enum Kind: Sendable {
        case created, modified, deleted
    }

    public let relativePath: String
    public let kind: Kind

    public init(relativePath: String, kind: Kind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}
