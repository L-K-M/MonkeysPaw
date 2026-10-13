import Foundation

/// App-data usage state (§5.4), at usage/<identity-key> without an extension.
/// Version 1 is sorted-key JSON: {"events":[Unix seconds],"version":1}.
/// Doubles preserve Date precision; events stay in recording order. Atomic
/// FileStore replacement retains the last usageEventCap events on each write.
/// Corrupt/unsupported state is an error, never silently reset or merged.
/// One lock serializes every operation, including each read/append/write
/// cycle, so the store is safe to share across threads as @unchecked Sendable.
public final class UsageStore: PromptKeyedStore, SyncKeyedStore, @unchecked Sendable {
    private struct Payload: Codable {
        let events: [Double]
        let version: Int
    }

    private let files: FileStore
    private let clock: WallClock
    private let lock = NSLock()
    private let observers = ChangeObservers<Void>()
    // Populated by the index's validated reads and successful writes. Browsing
    // never scans app data or performs usage I/O on a presentation refresh.
    private var cachedEvents: [PromptIdentity: [Date]] = [:]
    private var syncWriteGates = SyncKeyedWriteGates()

    public init(files: FileStore, clock: WallClock) {
        self.files = files
        self.clock = clock
    }

    /// Uses the injected clock when at is omitted. Return the retained events
    /// only after persistence succeeds, so the index can update without a read.
    @discardableResult
    public func recordUse(identity: PromptIdentity, at date: Date? = nil) throws -> [Date] {
        let recorded = try recordUseDeferringNotification(identity: identity, at: date)
        recorded.notify()
        return recorded.events
    }

    /// The index must commit its cache and unlock before usage subscribers can
    /// re-enter it through an inline MainThread. Persistence remains serialized.
    func recordUseDeferringNotification(identity: PromptIdentity, at date: Date?) throws
        -> (events: [Date], notify: () -> Void) {
        let (events, subscribers) = try locked {
            try syncWriteGates.requireEditable()
            let timestamp = date ?? clock.now()
            guard timestamp.timeIntervalSince1970.isFinite else { throw LibraryError.invalidTimestamp }
            let path = try path(for: identity)
            let events = Array((try readEvents(at: path) + [timestamp]).suffix(Limits.usageEventCap))
            let payload = Payload(events: events.map(\.timeIntervalSince1970), version: 1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try files.write(try encoder.encode(payload), at: path)
            cachedEvents[identity] = events
            return (events, observers.capture())
        }
        return (events, { [observers] in observers.publish(subscribers) })
    }

    public func useEvents(for identity: PromptIdentity) throws -> [Date] {
        try locked {
            let events = try readEvents(at: path(for: identity))
            cachedEvents[identity] = events
            return events
        }
    }

    /// Latest validated in-memory events; missing keys have not been loaded.
    /// PromptIndex rebuild/apply loads every indexed identity before publishing.
    func cachedUseEvents() -> [PromptIdentity: [Date]] {
        // Unlike the I/O helper this operation cannot throw.
        lock.lock()
        defer { lock.unlock() }
        return cachedEvents
    }

    /// Recent changes independently of index content, after commit/unlock.
    /// Reads and keyed-state migration stay quiet; content publication picks up
    /// migrated keys. Failed writes never notify.
    @discardableResult
    func addObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        observers.add(observer)
    }

    func removeObserver(_ token: UUID) { observers.remove(token) }

    @discardableResult
    public func migrateKey(from source: PromptIdentity, to destination: PromptIdentity) throws -> PromptKeyMigration {
        try locked {
            try syncWriteGates.requireEditable()
            let sourcePath = try path(for: source)
            let destinationPath = try path(for: destination)
            guard source != destination, try files.stamp(at: sourcePath) != nil else { return .unchanged }
            guard try files.stamp(at: destinationPath) == nil else { throw LibraryError.keyedStateConflict }
            do { try files.move(from: sourcePath, to: destinationPath) }
            catch FileStoreError.alreadyExists { throw LibraryError.keyedStateConflict }
            cachedEvents[destination] = cachedEvents.removeValue(forKey: source)
            return .migrated
        }
    }

    private func path(for identity: PromptIdentity) throws -> String {
        "usage/" + (try identity.storageKey)
    }

    var syncKind: SyncKeyedStoreKind { .usage }

    func bindSyncWriteGate(_ gate: SyncLibraryWriteGate) {
        lock.lock()
        defer { lock.unlock() }
        syncWriteGates.bind(gate)
    }

    func isSyncMigrationUnstarted(_ migration: SyncKeyedMigration) throws -> Bool {
        try locked {
            guard case .file(let move) = migration.change else { return false }
            return try move.isUnstarted(files: files)
        }
    }

    func prepareSyncMigration(from source: PromptIdentity, to destination: PromptIdentity,
                              rebindingHeadTo: Data?, originalBytes: Data?) throws -> [SyncKeyedMigration] {
        try locked {
            let from = try path(for: source)
            let to = try path(for: destination)
            guard let bytes = try SyncDurability.readIfPresent(from, files: files) else { return [] }
            _ = try readEvents(at: from)
            guard try files.stamp(at: to) == nil else { throw LibraryError.keyedStateConflict }
            return [SyncKeyedMigration(store: .usage,
                change: .file(SyncKeyedFileMove(source: from, destination: to, bytes: bytes)))]
        }
    }

    func applySyncMigration(_ migration: SyncKeyedMigration, operations: SyncFileOperations) throws {
        try locked {
            guard case .file(let move) = migration.change else { throw SyncError.invalidState }
            try move.apply(files: files, operations: operations)
            let source = try SyncIdentifiers.promptIdentity(String(move.source.dropFirst("usage/".count)))
            let destination = try SyncIdentifiers.promptIdentity(String(move.destination.dropFirst("usage/".count)))
            cachedEvents[source] = nil
            cachedEvents[destination] = try readEvents(at: move.destination)
        }
    }

    private func readEvents(at path: String) throws -> [Date] {
        let bytes: Data
        do { bytes = try files.read(at: path) }
        catch FileStoreError.notFound { return [] }
        let payload = try JSONDecoder().decode(Payload.self, from: bytes)
        guard payload.version == 1, payload.events.count <= Limits.usageEventCap,
              payload.events.allSatisfy(\.isFinite) else { throw LibraryError.operationFailed }
        return payload.events.map(Date.init(timeIntervalSince1970:))
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        do { return try work() }
        catch let error as FileStoreError { throw error }
        catch let error as LibraryError { throw error }
        catch { throw LibraryError.operationFailed }
    }
}
