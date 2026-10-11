import Foundation

/// In-memory search (§5.4), with no watcher ownership or app wiring. One lock
/// serializes index updates and dependency access; LibraryService and UsageStore
/// are internally locked. Search snapshots state and the clock under the lock,
/// then parses, matches, scores and sorts without it.
/// Share the LibraryService/UsageStore instances used for identity migrations.
public final class PromptIndex: @unchecked Sendable {
    private struct IndexedPrompt {
        let entry: LibraryEntry
        let content: PromptSearchContent
    }

    private let service: LibraryService
    private let usage: UsageStore
    private let clock: WallClock
    private let lock = NSLock()
    // String equality collapses canonically equivalent paths. M2b paths are
    // byte-exact, so distinct POSIX files must have distinct index keys.
    private var prompts = [Data: IndexedPrompt]()
    private var useEvents = [PromptIdentity: [Date]]()
    private var onChange: (@Sendable () -> Void)?

    public init(service: LibraryService, usage: UsageStore, clock: WallClock) {
        self.service = service
        self.usage = usage
        self.clock = clock
    }

    /// Single owner: assignment replaces the previous hook. Every successful
    /// rebuild/apply invokes it once on the caller's thread, after releasing the
    /// lock; failed publishes and recordUse stay quiet. Callers may re-enter
    /// search and models must marshal through MainThread.
    public func setOnChange(_ callback: (@Sendable () -> Void)?) {
        locked { onChange = callback }
    }

    /// Publish a complete rebuild only after all library and usage reads succeed.
    /// Invalid content stays visible exactly as LibraryService.entries() allows.
    public func rebuild() throws {
        let callback = try locked {
            var rebuilt = [Data: IndexedPrompt]()
            var events = [PromptIdentity: [Date]]()
            for entry in try service.entries() {
                rebuilt[Data(entry.relativePath.utf8)] = indexed(entry)
                if events[entry.identity] == nil { events[entry.identity] = try usage.useEvents(for: entry.identity) }
            }
            prompts = rebuilt
            useEvents = events
            return onChange
        }
        callback?()
    }

    /// Apply a complete batch atomically in memory. Reload created/modified
    /// paths, silently dropping vanished files. Other I/O/conflict failures
    /// leave the last completed index intact and are reported to the caller.
    public func apply(_ set: LibraryChangeSet) throws {
        let callback = try locked {
            var updated = prompts
            var events = useEvents
            for path in set.deleted { updated.removeValue(forKey: Data(path.utf8)) }
            let changed = set.created.union(set.modified).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for path in changed {
                guard let entry = try currentEntry(at: path) else {
                    updated.removeValue(forKey: Data(path.utf8))
                    continue
                }
                updated[Data(path.utf8)] = indexed(entry)
                events[entry.identity] = try usage.useEvents(for: entry.identity)
            }
            let identities = Set(updated.values.map { $0.entry.identity })
            prompts = updated
            useEvents = events.filter { identities.contains($0.key) }
            return onChange
        }
        callback?()
    }

    public func search(_ query: String) -> [PromptSearchResult] {
        // COW snapshots retain immutable published entries and normalized fields.
        let (snapshot, events, now) = locked { (prompts, useEvents, clock.now()) }
        let parsed = PromptSearchQuery(query)
        let results = snapshot.values.compactMap { prompt -> PromptSearchResult? in
            guard let match = prompt.content.match(parsed) else { return nil }
            let frecency = PromptRanking.frecency(events: events[prompt.entry.identity] ?? [], at: now)
            let boost = prompt.entry.document.frontMatter.favorite ? Limits.favoriteBoost : 1
            let score = parsed.isEmpty ? frecency : match.score * (1 + frecency) * boost
            return PromptSearchResult(entry: prompt.entry, score: score, matchedFields: match.fields)
        }
        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if parsed.isEmpty {
                let leftFavorite = lhs.entry.document.frontMatter.favorite
                let rightFavorite = rhs.entry.document.frontMatter.favorite
                if leftFavorite != rightFavorite { return leftFavorite }
            }
            let leftTitle = lhs.entry.document.frontMatter.title
            let rightTitle = rhs.entry.document.frontMatter.title
            if !leftTitle.utf8.elementsEqual(rightTitle.utf8) {
                return leftTitle.utf8.lexicographicallyPrecedes(rightTitle.utf8)
            }
            return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
    }

    /// Deliberate quiet update: persistence succeeds before cached events change.
    /// Search sees the new ranking; delivery models refresh their own results.
    public func recordUse(of identity: PromptIdentity) throws {
        try locked { useEvents[identity] = try usage.recordUse(identity: identity, at: clock.now()) }
    }

    private func indexed(_ entry: LibraryEntry) -> IndexedPrompt {
        IndexedPrompt(entry: entry, content: PromptSearchContent(entry))
    }

    private func currentEntry(at path: String) throws -> LibraryEntry? {
        do { return try service.load(at: path) }
        catch FileStoreError.notFound { return nil }
        catch LibraryError.conflict {
            // LibraryService maps deletion between stamp/read to conflict.
            // Retry once to distinguish a vanished path from a still-racing file.
            do { return try service.load(at: path) }
            catch FileStoreError.notFound { return nil }
        }
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
