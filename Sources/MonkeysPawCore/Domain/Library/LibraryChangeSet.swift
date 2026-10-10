/// Disjoint prompt paths after one quiet debounce window. Paths are relative
/// to the library root; no file reads or reloads are implied by notification.
public struct LibraryChangeSet: Equatable, Sendable {
    public let created: Set<String>
    public let modified: Set<String>
    public let deleted: Set<String>

    public init(created: Set<String> = [], modified: Set<String> = [], deleted: Set<String> = []) {
        assert(created.isDisjoint(with: modified) && created.isDisjoint(with: deleted)
               && modified.isDisjoint(with: deleted), "LibraryChangeSet path sets must be disjoint")
        self.created = created
        self.modified = modified
        self.deleted = deleted
    }

    public var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }
}
