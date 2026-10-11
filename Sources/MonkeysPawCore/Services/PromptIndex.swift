import Foundation

/// In-memory search (§5.4), with no watcher ownership or app wiring. One lock
/// serializes index updates and dependency access; LibraryService and UsageStore
/// are internally locked. Search snapshots state and the clock under the lock,
/// then parses, matches, scores and sorts without it.
/// Share the LibraryService/UsageStore instances used for identity migrations.
public final class PromptIndex: @unchecked Sendable {
    private let service: LibraryService
    private let usage: UsageStore
    private let clock: WallClock
    private let lock = NSLock()
    // String equality collapses canonically equivalent paths. RelativePath
    // compares UTF-8 bytes, so distinct POSIX files keep distinct index keys.
    private var prompts = [RelativePath: PromptRanking.Input]()
    private var useEvents = [PromptIdentity: [Date]]()
    private var onChange: (@Sendable () -> Void)?

    public init(service: LibraryService, usage: UsageStore, clock: WallClock) {
        self.service = service
        self.usage = usage
        self.clock = clock
    }

    /// Single owner: clear the hook before installing a replacement; debug
    /// builds assert this contract. Successful rebuild/apply captures the current
    /// hook under the publish lock and invokes it once after unlocking, on the
    /// caller's thread. Failed publishes and recordUse stay quiet. Callers may
    /// re-enter search and models must marshal through MainThread.
    public func setOnChange(_ callback: (@Sendable () -> Void)?) {
        locked {
            assert(onChange == nil || callback == nil)
            onChange = callback
        }
    }

    /// Publish a complete rebuild only after all library and usage reads succeed.
    /// Invalid content stays visible exactly as LibraryService.entries() allows.
    public func rebuild() throws {
        let callback = try locked {
            var rebuilt = [RelativePath: PromptRanking.Input]()
            var events = [PromptIdentity: [Date]]()
            for entry in try service.entries() {
                rebuilt[RelativePath(entry.relativePath)] = PromptRanking.Input(entry)
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
            for path in set.deleted { updated.removeValue(forKey: path) }
            let changed = set.created.union(set.modified).sorted()
            for path in changed {
                guard let entry = try currentEntry(at: path.string) else {
                    updated.removeValue(forKey: path)
                    continue
                }
                updated[path] = PromptRanking.Input(entry)
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
        return PromptRanking.rank(snapshot.values, query: query, useEvents: events, at: now)
    }

    /// Deliberate quiet update: persistence succeeds before cached events change.
    /// Search sees the new ranking; delivery models refresh their own results.
    public func recordUse(of identity: PromptIdentity) throws {
        try locked { useEvents[identity] = try usage.recordUse(identity: identity, at: clock.now()) }
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
