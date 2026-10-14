import Foundation

enum SyncPullCollectorError: Error, Equatable {
    enum NoProgress: Equatable { case snapshotExpired, databaseChanged, stalledContinuation, collectionDeadline }
    case noProgress(NoProgress)
    case invalidRequest
    case invalidResponse
    case stagingFailed(FileStoreError)
}

struct SyncCollectedScope {
    let identity: SyncAPI.ScopeIdentity
    let head: Int64
    let cursor: String
    /// Nil for a delta-only scope; otherwise the complete frozen snapshot head.
    let snapshotHead: Int64?
    let firstPage: Int
}

struct SyncCollectedItem: Equatable, CustomStringConvertible, CustomReflectable {
    let scope: SyncScopeKey
    let item: SyncAPI.FeedItem
    var seq: Int64 { item.seq }
    var description: String { "<collected sync item>" }
    var customMirror: Mirror { Mirror(self, children: ["item": description]) }
}

struct SyncCollectedPage: CustomStringConvertible, CustomReflectable {
    let scope: SyncScopeKey
    let mode: SyncAPI.Mode
    let items: [SyncCollectedItem]
    var description: String { "<collected sync page>" }
    var customMirror: Mirror { Mirror(self, children: ["page": description]) }
}

/// Only complete collections escape the collector. Consumers read snapshots
/// first, then fold all delta items by global seq before planning any mutation.
/// This handle owns transient private pages; discard after journal preparation.
final class SyncCollectedPull: CustomStringConvertible, CustomReflectable {
    let databaseID: UUID
    let scopes: [SyncScopeKey: SyncCollectedScope]
    let removed: Set<SyncScopeKey>
    var cursors: [SyncScopeKey: String] { scopes.mapValues(\.cursor) }
    private let staging: SyncPullStaging

    init(databaseID: UUID, scopes: [SyncScopeKey: SyncCollectedScope], removed: Set<SyncScopeKey>, staging: SyncPullStaging) {
        self.databaseID = databaseID
        self.scopes = scopes
        self.removed = removed
        self.staging = staging
    }

    /// At most one capped response is loaded at a time. Removed scopes and
    /// superseded snapshots/deltas never reach the consumer.
    func forEachPage(mode: SyncAPI.Mode, _ consume: (SyncCollectedPage) throws -> Void) throws {
        for index in 0..<staging.pageCount {
            let response = try staging.read(index)
            guard response.databaseID == databaseID.uuidString.lowercased() else { throw SyncPullCollectorError.invalidResponse }
            for page in response.scopes where page.mode == mode {
                let key = try SyncScopeKey(page.identity)
                guard let scope = scopes[key], index >= scope.firstPage else { continue }
                try consume(SyncCollectedPage(scope: key, mode: mode,
                    items: page.items.map { SyncCollectedItem(scope: key, item: $0) }))
            }
        }
    }

    func discard() throws { try staging.discard() }
    var description: String { "<collected sync pull>" }
    var customMirror: Mirror { Mirror(self, children: ["pull": description]) }
}

/// No page-path array or accumulated prompt bodies: filenames derive from a
/// unique collection ID and an integer. FileStore supplies rooted 0600 writes.
final class SyncPullStaging {
    private let files: FileStore
    private let id = UUID().uuidString.lowercased()
    private(set) var pageCount = 0
    private var discarded = false

    init(files: FileStore) { self.files = files }
    deinit { try? discard() }

    func append(_ response: SyncAPI.PullResponse) throws {
        guard !discarded else { throw SyncPullCollectorError.invalidResponse }
        let bytes = try JSONEncoder().encode(response)
        guard bytes.count <= Limits.syncResponseCap else { throw SyncPullCollectorError.invalidResponse }
        let path = path(pageCount)
        // A failed publication can still leave a file. Include it in cleanup.
        pageCount += 1
        try operation { try files.writePrivate(bytes, at: path) }
    }

    func read(_ index: Int) throws -> SyncAPI.PullResponse {
        guard !discarded else { throw SyncPullCollectorError.invalidResponse }
        let bytes = try operation { try files.read(at: path(index)) }
        guard bytes.count <= Limits.syncResponseCap else { throw SyncPullCollectorError.invalidResponse }
        do { return try JSONDecoder().decode(SyncAPI.PullResponse.self, from: bytes) }
        catch { throw SyncPullCollectorError.invalidResponse }
    }

    func discard() throws {
        guard !discarded else { return }
        var failure: SyncPullCollectorError?
        for index in 0..<pageCount {
            do { try operation { try files.delete(at: path(index)) } }
            catch SyncPullCollectorError.stagingFailed(.notFound) { continue }
            catch { failure = error as? SyncPullCollectorError ?? .stagingFailed(.ioFailure) }
        }
        if let failure { throw failure }
        discarded = true
    }

    private func path(_ index: Int) -> String { "sync/pull-" + id + "-" + String(index) + ".json" }

    private func operation<Value>(_ body: () throws -> Value) throws -> Value {
        do { return try body() }
        catch let error as FileStoreError { throw SyncPullCollectorError.stagingFailed(error) }
        catch { throw SyncPullCollectorError.stagingFailed(.ioFailure) }
    }
}

extension SyncCollectedScope {
    init(page: SyncAPI.SyncScope, snapshotHead: Int64?, firstPage: Int) {
        identity = page.identity
        head = page.head
        cursor = page.cursor
        self.snapshotHead = snapshotHead
        self.firstPage = firstPage
    }
}
