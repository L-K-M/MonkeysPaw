/// Disjoint prompt paths after one quiet debounce window. Paths are relative
/// to the library root; no file reads or reloads are implied by notification.
///
/// `created`, `modified`, and `deleted` must be pairwise disjoint; debug builds
/// assert this invariant.
public struct LibraryChangeSet: Equatable, Sendable {
    public let created: Set<RelativePath>
    public let modified: Set<RelativePath>
    public let deleted: Set<RelativePath>

    public init(created: Set<RelativePath> = [], modified: Set<RelativePath> = [], deleted: Set<RelativePath> = []) {
        assert(created.isDisjoint(with: modified) && created.isDisjoint(with: deleted)
               && modified.isDisjoint(with: deleted), "LibraryChangeSet path sets must be disjoint")
        self.created = created
        self.modified = modified
        self.deleted = deleted
    }

    public var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }
}

/// Ordered watcher output: debounced prompt changes or immediate root health.
public enum LibraryWatchUpdate: Equatable, Sendable {
    case changes(LibraryChangeSet)
    case rootUnavailable(FileStoreError)
}
