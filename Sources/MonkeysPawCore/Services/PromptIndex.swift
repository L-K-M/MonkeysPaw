import Foundation

/// In-memory search (§5.4), with no watcher ownership or app wiring. One lock
/// serializes index updates and dependency access; LibraryService and UsageStore
/// are internally locked. Search snapshots state and the clock under the lock,
/// then parses, matches, scores and sorts without it.
/// Share the LibraryService/UsageStore instances used for identity migrations.
public final class PromptIndex: @unchecked Sendable {
    private struct Publication {
        let observers: [UUID]
        let changeObservers: [UUID]
        let change: PromptIndexChange
    }

    private let service: LibraryService
    private let usage: UsageStore
    private let clock: WallClock
    private let lock = NSLock()
    // String equality collapses canonically equivalent paths. RelativePath
    // compares UTF-8 bytes, so distinct POSIX files keep distinct index keys.
    private var prompts = [RelativePath: PromptRanking.Input]()
    private var useEvents = [PromptIdentity: [Date]]()
    private let observers = ChangeObservers<Void>()
    private let changeObservers = ChangeObservers<PromptIndexChange>()
    private var version: UInt64 = 0
    private var pathVersions: [RelativePath: UInt64] = [:]
    private var compatibilityObserver: UUID?

    public init(service: LibraryService, usage: UsageStore, clock: WallClock) {
        self.service = service
        self.usage = usage
        self.clock = clock
    }

    /// Successful rebuild/apply captures the latest subscribers at publication,
    /// then notifies on the caller's thread after unlocking. Failed publications
    /// and recordUse stay quiet. Models marshal through MainThread. Registration
    /// does not notify; removal cancels invocations not already in progress,
    /// including later subscribers in the same publication.
    @discardableResult
    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        observers.add(observer)
    }

    /// The editor uses the same removable registry contract with a captured
    /// change payload, rather than guessing which paths a later cache contains.
    @discardableResult
    func addObserver(_ observer: @escaping @Sendable (PromptIndexChange) -> Void) -> UUID {
        changeObservers.add(observer)
    }

    public func removeObserver(_ token: UUID) {
        observers.remove(token)
        changeObservers.remove(token)
    }

    /// Compatibility for native composition until its M3 migration. Replacing
    /// or clearing this one subscription never removes independent subscribers.
    @available(*, deprecated, message: "Use addObserver(_:) and removeObserver(_:)")
    public func setOnChange(_ callback: (@Sendable () -> Void)?) {
        locked {
            if let compatibilityObserver { observers.remove(compatibilityObserver) }
            compatibilityObserver = callback.map { observers.add($0) }
        }
    }

    /// Publish a complete rebuild only after all library and usage reads succeed.
    /// Invalid content stays visible exactly as LibraryService.entries() allows.
    public func rebuild() throws {
        let publication = try locked {
            var rebuilt = [RelativePath: PromptRanking.Input]()
            var events = [PromptIdentity: [Date]]()
            for entry in try service.entries() {
                rebuilt[RelativePath(entry.relativePath)] = PromptRanking.Input(entry)
                if events[entry.identity] == nil { events[entry.identity] = try usage.useEvents(for: entry.identity) }
            }
            let oldPaths = Set(prompts.keys)
            let newPaths = Set(rebuilt.keys)
            let modified = oldPaths.intersection(newPaths).filter { prompts[$0]?.entry.stamp != rebuilt[$0]?.entry.stamp }
            let changes = LibraryChangeSet(created: newPaths.subtracting(oldPaths), modified: Set(modified),
                                           deleted: oldPaths.subtracting(newPaths))
            prompts = rebuilt
            useEvents = events
            return capturePublication(changes)
        }
        publish(publication)
    }

    /// Apply a complete batch atomically in memory. Reload created/modified
    /// paths, silently dropping vanished files. Other I/O/conflict failures
    /// leave the last completed index intact and are reported to the caller.
    public func apply(_ set: LibraryChangeSet) throws {
        let publication = try locked {
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
            return capturePublication(set)
        }
        publish(publication)
    }

    public func search(_ query: String) -> [PromptSearchResult] {
        // COW snapshots retain immutable published entries and normalized fields.
        let (snapshot, events, now) = locked { (prompts, useEvents, clock.now()) }
        return PromptRanking.rank(snapshot.values, query: query, useEvents: events, at: now)
    }

    /// Shared immutable content for the browser's matcher, without reloading or
    /// normalizing files. The browser orders sections independently of ranking.
    func browseContents() -> [PromptRanking.Input] { locked { Array(prompts.values) } }

    /// Memory-only lookup for publishing a saved editor entry.
    func cachedEntry(at path: String) -> LibraryEntry? { locked { prompts[RelativePath(path)]?.entry } }

    func editingSnapshot(at path: String) -> (version: UInt64, stamp: FileStamp?) {
        locked { (version, prompts[RelativePath(path)]?.entry.stamp) }
    }

    /// Global publication counter, including when a destination is not yet known.
    var publicationVersion: UInt64 { locked { version } }

    /// Publish a completed metadata save without more I/O. A watcher may have
    /// already published a newer file or deletion; never replace that snapshot
    /// with the save's older result. Native editor work will own this hand-off.
    func acceptSaved(_ entry: LibraryEntry, replacing previous: LibraryEntry) {
        let publication: Publication? = locked {
            let path = RelativePath(previous.relativePath)
            guard RelativePath(entry.relativePath) == path,
                  let current = prompts[path]?.entry, current.identity == previous.identity,
                  current.stamp == previous.stamp else { return nil }
            prompts[path] = PromptRanking.Input(entry)
            let cached = usage.cachedUseEvents()
            // Keep known usage if the cache ever lacks this identity.
            useEvents[entry.identity] = cached[entry.identity] ?? useEvents[entry.identity] ?? []
            if entry.identity != previous.identity, !prompts.values.contains(where: { $0.entry.identity == previous.identity }) {
                useEvents[previous.identity] = nil
            }
            return capturePublication(LibraryChangeSet(modified: [path]))
        }
        if let publication { publish(publication) }
    }

    /// Publish a stamped file command without disk work on the UI thread.
    /// Reconcile each path independently: a newer destination publication must
    /// survive without keeping the old source row. Newer source recreations
    /// also survive, and unrelated publications cannot hide the command.
    func acceptCommand(_ entry: LibraryEntry?, at source: String, expectedVersion: UInt64,
                       expectedSourceStamp: FileStamp? = nil) {
        let publication: Publication? = locked {
            let sourcePath = RelativePath(source)
            let destination = entry.map { RelativePath($0.relativePath) } ?? sourcePath
            let previousIdentities = Set([prompts[sourcePath]?.entry.identity, prompts[destination]?.entry.identity].compactMap { $0 })
            var deleted: Set<RelativePath> = []
            var created: Set<RelativePath> = []
            var modified: Set<RelativePath> = []
            // A publication may have read the source before the physical move
            // but committed later. Its unchanged stamp is safe to replace;
            // a recreated source has a different incarnation and must survive.
            let sameSource = expectedSourceStamp.map { prompts[sourcePath]?.entry.stamp == $0 } == true
            if pathVersions[sourcePath, default: 0] <= expectedVersion || sameSource,
               entry == nil || destination != sourcePath {
                prompts.removeValue(forKey: sourcePath)
                // Keep a deletion publication even without a cached row: an
                // earlier command must not later resurrect this missing path.
                deleted.insert(sourcePath)
            }
            if let entry, pathVersions[destination, default: 0] <= expectedVersion || (destination == sourcePath && sameSource) {
                let existed = prompts[destination] != nil
                prompts[destination] = PromptRanking.Input(entry)
                useEvents[entry.identity] = usage.cachedUseEvents()[entry.identity] ?? useEvents[entry.identity] ?? []
                if existed { modified.insert(destination) }
                else { created.insert(destination) }
            }
            let changes = LibraryChangeSet(created: created, modified: modified, deleted: deleted)
            guard !changes.isEmpty else { return nil }
            for identity in previousIdentities where !prompts.values.contains(where: { $0.entry.identity == identity }) {
                useEvents[identity] = nil
            }
            return capturePublication(changes)
        }
        if let publication { publish(publication) }
    }

    /// Called only with the index lock held. Payload and subscriber membership
    /// belong to this commit even if a callback makes another publication.
    private func capturePublication(_ set: LibraryChangeSet) -> Publication {
        version &+= 1
        var stamps: [RelativePath: FileStamp] = [:]
        for path in set.created.union(set.modified).union(set.deleted) { pathVersions[path] = version }
        for path in set.created.union(set.modified) { stamps[path] = prompts[path]?.entry.stamp }
        return Publication(observers: observers.capture(), changeObservers: changeObservers.capture(),
                           change: PromptIndexChange(changes: set, stamps: stamps, version: version))
    }

    private func publish(_ publication: Publication) {
        observers.publish(publication.observers)
        changeObservers.publish(publication.changeObservers, event: publication.change)
    }

    /// Deliberate quiet update: persistence succeeds before cached events change.
    /// Search sees the new ranking; delivery models refresh their own results.
    public func recordUse(of identity: PromptIdentity) throws {
        let notify = try locked {
            let recorded = try usage.recordUseDeferringNotification(identity: identity, at: clock.now())
            useEvents[identity] = recorded.events
            return recorded.notify
        }
        notify()
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
