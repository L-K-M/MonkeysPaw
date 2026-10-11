/// Installs the built-in catalog through real first saves (§5.2, §11.4).
/// Onboarding owns the no-server condition and the separate "seeds offered" state.
public final class SeedService {
    private let library: LibraryService

    public init(library: LibraryService) { self.library = library }

    /// Only eligible prompt files count as non-empty, including invalid prompts.
    /// An occupied destination is skipped atomically. Other LibraryService errors
    /// remain typed (FileStoreError, LibraryError, PromptWriteError, ULIDGenerationError).
    /// No batch rollback: after a partial failure/crash the next run seeds nothing.
    /// Calls are synchronous; callers serialize onboarding for their library.
    public func seedIfEmpty() throws -> SeedSummary {
        guard try library.entries().isEmpty else {
            return SeedSummary(seededCount: 0, skippedExistingCount: 0)
        }
        var seeded = 0
        var skipped = 0
        for seed in SeedCatalog.prompts {
            let document = PromptCodec.parseFile(seed.bytes, filename: LibraryPath.filename(seed.relativePath))
            do {
                try library.create(document, at: seed.relativePath)
                seeded += 1
            } catch FileStoreError.alreadyExists {
                skipped += 1
            }
        }
        return SeedSummary(seededCount: seeded, skippedExistingCount: skipped)
    }
}
