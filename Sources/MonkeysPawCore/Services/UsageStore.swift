import Foundation

/// App-data usage state (§5.4), at usage/<identity-key> without an extension.
/// Version 1 is sorted-key JSON: {"events":[Unix seconds],"version":1}.
/// Doubles preserve Date precision; events stay in recording order. Atomic
/// FileStore replacement retains the last usageEventCap events on each write.
/// Corrupt/unsupported state is an error, never silently reset or merged.
/// One lock serializes every operation, including each read/append/write
/// cycle, so the store is safe to share across threads as @unchecked Sendable.
public final class UsageStore: PromptKeyedStore, @unchecked Sendable {
    private struct Payload: Codable {
        let events: [Double]
        let version: Int
    }

    private let files: FileStore
    private let clock: WallClock
    private let lock = NSLock()

    public init(files: FileStore, clock: WallClock) {
        self.files = files
        self.clock = clock
    }

    /// Uses the injected clock when at is omitted. Return the retained events
    /// only after persistence succeeds, so the index can update without a read.
    @discardableResult
    public func recordUse(identity: PromptIdentity, at date: Date? = nil) throws -> [Date] {
        try locked {
            let timestamp = date ?? clock.now()
            guard timestamp.timeIntervalSince1970.isFinite else { throw LibraryError.invalidTimestamp }
            let path = try path(for: identity)
            let events = Array((try readEvents(at: path) + [timestamp]).suffix(Limits.usageEventCap))
            let payload = Payload(events: events.map(\.timeIntervalSince1970), version: 1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try files.write(try encoder.encode(payload), at: path)
            return events
        }
    }

    public func useEvents(for identity: PromptIdentity) throws -> [Date] {
        try locked { try readEvents(at: path(for: identity)) }
    }

    @discardableResult
    public func migrateKey(from source: PromptIdentity, to destination: PromptIdentity) throws -> PromptKeyMigration {
        try locked {
            let sourcePath = try path(for: source)
            let destinationPath = try path(for: destination)
            guard source != destination, try files.stamp(at: sourcePath) != nil else { return .unchanged }
            guard try files.stamp(at: destinationPath) == nil else { throw LibraryError.keyedStateConflict }
            do { try files.move(from: sourcePath, to: destinationPath) }
            catch FileStoreError.alreadyExists { throw LibraryError.keyedStateConflict }
            return .migrated
        }
    }

    private func path(for identity: PromptIdentity) throws -> String {
        "usage/" + (try identity.storageKey)
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
