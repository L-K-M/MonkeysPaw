/// Driver-owned monitoring of the same canonical root as its FileStore.
/// File events describe regular files using store-relative POSIX paths. Drivers
/// exclude symlinks and paths outside the root, but do not filter prompts or
/// debounce. A rename produces a deletion at the old path and creation at
/// the new path. Directory changes include affected descendant files.
/// One ordered callback carries file events and root unavailability. After an
/// available baseline, missing/non-directory/non-enumerable roots report once
/// per unavailable transition, on the normal driver callback thread. Root loss
/// retains the last good file baseline and emits no per-file deletions. A later
/// good scan resets the transition; clients may stop and require restart.
public protocol FileStoreWatcher {
    /// Idempotent while running; takes a baseline without emitting it. Missing
    /// roots are watched through existing ancestors without creating them.
    /// A failed start leaves the watcher stopped. The driver owns the callback
    /// thread; callers must not assume it is the UI thread.
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws
    /// Idempotent. Release monitors and discard events from the stopped run.
    func stop()
}

public enum FileStoreWatchEvent: Equatable, Sendable {
    case file(FileStoreEvent)
    case rootUnavailable(FileStoreError)
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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }
}
