/// A narrow editing intent, separate from browser rendering. The M3 editor
/// adapter will intercept a dirty prompt and edit its buffer (§11.7); until
/// then LibraryService implements stamped, synchronous front-matter saves.
public protocol PromptFavoriteEditing {
    func toggleFavorite(of entry: LibraryEntry) -> PromptFavoriteOutcome
}
