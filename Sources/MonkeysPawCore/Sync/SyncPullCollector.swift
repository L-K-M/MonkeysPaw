import Foundation

/// Collects only. It has no library, journal or state-store capability.
struct SyncPullCollector {
    private let client: SyncHTTPClient
    private let files: FileStore
    private let userID: ULID
    private let now: () -> ContinuousClock.Instant
    private let permit: SyncWorkPermit?

    init(client: SyncHTTPClient, files: FileStore, userID: ULID,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }, permit: SyncWorkPermit? = nil) {
        self.client = client
        self.files = files
        self.userID = userID
        self.now = now
        self.permit = permit
    }

    func collect(_ initial: SyncAPI.PullRequest, deadline supplied: ContinuousClock.Instant? = nil) async throws -> SyncCollectedPull {
        let budget = now().advanced(by: Limits.syncCollectionBudget)
        let deadline = min(budget, supplied ?? budget)
        try validate(initial)
        var request = initial
        var staging = SyncPullStaging(files: files)
        var scopes: [SyncScopeKey: ScopeProgress] = [:]
        var removed = Set<SyncScopeKey>()
        let initialKeys = try Set(initial.cursors.keys.map(SyncScopeKey.init))
        var databaseID: UUID?
        var restarts = 0

        do {
            while true {
                try check(deadline)
                let response: SyncAPI.PullResponse
                do { response = try await client.pull(request, deadline: deadline) }
                catch SyncHTTPClientError.snapshotExpired(let keys) {
                    try check(deadline)
                    guard !keys.isEmpty, Set(keys).count == keys.count,
                          keys.allSatisfy({ request.cursors[$0] != nil }) else { throw SyncPullCollectorError.invalidResponse }
                    guard restarts < Limits.syncCollectionRestartLimit else { throw SyncPullCollectorError.noProgress(.snapshotExpired) }
                    restarts += 1
                    // Discarded pages' advanced cursors would skip lost deltas.
                    var cursors = initial.cursors
                    for key in keys { cursors[key] = nil }
                    request = .init(databaseID: initial.databaseID, cursors: cursors)
                    try staging.discard()
                    staging = SyncPullStaging(files: files)
                    scopes.removeAll()
                    removed.removeAll()
                    databaseID = nil
                    continue
                } catch {
                    try check(deadline)
                    throw error
                }
                try check(deadline)
                let responseID = try validate(response, request: request)
                if let capturedID = databaseID, capturedID != responseID {
                    guard restarts < Limits.syncCollectionRestartLimit else { throw SyncPullCollectorError.noProgress(.databaseChanged) }
                    restarts += 1
                    // Snapshot continuations bind their old database. An empty
                    // request obtains a fresh manifest for every accessible scope.
                    request = .init(databaseID: nil, cursors: [:])
                    try staging.discard()
                    staging = SyncPullStaging(files: files)
                    scopes.removeAll()
                    removed.removeAll()
                    // The response that detected the change is never staged.
                    databaseID = nil
                    continue
                }
                databaseID = responseID

                for raw in response.removed {
                    let key = try SyncScopeKey(raw)
                    scopes[key] = nil
                    removed.insert(key)
                }
                var completedScope = false
                for page in response.scopes {
                    let key = try SyncScopeKey(page.identity)
                    removed.remove(key)
                    let previous = scopes[key]
                    completedScope = completedScope || (previous?.hasMore == true && !page.hasMore)
                    scopes[key] = try progress(page, previous: previous, index: staging.pageCount, requestCursor: request.cursors[key.rawValue])
                }
                let cursors = Dictionary(uniqueKeysWithValues: scopes.map { ($0.key.rawValue, $0.value.scope.cursor) })
                if response.scopes.contains(where: \.hasMore), !completedScope, sameCursors(cursors, request.cursors) {
                    throw SyncPullCollectorError.noProgress(.stalledContinuation)
                }
                try check(deadline)
                if let permit { try permit.mutate { try staging.append(response) } }
                else { try staging.append(response) }
                try check(deadline)
                if !response.scopes.contains(where: \.hasMore) {
                    removed.formUnion(initialKeys.subtracting(scopes.keys))
                    return SyncCollectedPull(databaseID: responseID, scopes: scopes.mapValues(\.scope), removed: removed, staging: staging)
                }
                request = .init(databaseID: response.databaseID, cursors: cursors)
            }
        } catch {
            try staging.discard()
            throw error
        }
    }

    private struct ScopeProgress {
        let scope: SyncCollectedScope
        let mode: SyncAPI.Mode
        let hasMore: Bool
        let lastSnapshotID: String?
        let lastDeltaSeq: Int64
    }

    private func progress(_ page: SyncAPI.SyncScope, previous: ScopeProgress?, index: Int, requestCursor: String?) throws -> ScopeProgress {
        let continuingSnapshot = previous?.mode == .snapshot && previous?.hasMore == true
        guard !continuingSnapshot || (page.mode == .snapshot && page.head == previous?.scope.snapshotHead) else {
            throw SyncPullCollectorError.invalidResponse
        }
        let newSnapshot = page.mode == .snapshot && !continuingSnapshot
        var lastID = newSnapshot ? nil : previous?.lastSnapshotID
        var lastSeq = newSnapshot ? page.head : previous?.lastDeltaSeq ?? 0
        for item in page.items {
            if page.mode == .snapshot {
                guard case .upsert(_, let prompt) = item else {
                    throw SyncPullCollectorError.invalidResponse
                }
                if let lastID, lastID >= prompt.id { throw SyncPullCollectorError.invalidResponse }
                lastID = prompt.id
            } else {
                guard item.seq > lastSeq else { throw SyncPullCollectorError.invalidResponse }
                lastSeq = item.seq
            }
        }
        if page.mode == .delta, !page.items.isEmpty, let requestCursor, sameCursor(page.cursor, requestCursor) {
            throw SyncPullCollectorError.invalidResponse
        }
        return ScopeProgress(scope: SyncCollectedScope(page: page,
            snapshotHead: newSnapshot ? page.head : previous?.scope.snapshotHead,
            firstPage: newSnapshot ? index : previous?.scope.firstPage ?? index),
            mode: page.mode, hasMore: page.hasMore, lastSnapshotID: lastID, lastDeltaSeq: lastSeq)
    }

    private func validate(_ request: SyncAPI.PullRequest) throws {
        do {
            try SyncAPI.PullRequest.schema.validate(.object(request.object))
            for raw in request.cursors.keys {
                if case .user(let id) = try SyncScopeKey(raw), id != userID { throw SyncPullCollectorError.invalidRequest }
            }
        } catch { throw SyncPullCollectorError.invalidRequest }
    }

    private func validate(_ response: SyncAPI.PullResponse, request: SyncAPI.PullRequest) throws -> UUID {
        do {
            let databaseID = try SyncIdentifiers.uuid(response.databaseID)
            let keys = Set(response.scopes.map { $0.identity.key })
            guard request.cursors.keys.allSatisfy({ keys.contains($0) || response.removed.contains($0) }) else {
                throw SyncPullCollectorError.invalidResponse
            }
            for raw in response.removed {
                guard case .group = try SyncScopeKey(raw) else { throw SyncPullCollectorError.invalidResponse }
            }
            for page in response.scopes {
                let key = try SyncScopeKey(page.identity)
                if case .user(let id) = key, id != userID { throw SyncPullCollectorError.invalidResponse }
                if page.mode == .delta, request.cursors[key.rawValue] == nil || request.databaseID != response.databaseID {
                    throw SyncPullCollectorError.invalidResponse
                }
                for item in page.items {
                    switch item {
                    case .upsert(_, let prompt):
                        _ = try SyncIdentifiers.ulid(prompt.id)
                        let path = try SyncPathValidator.validate(prompt.path, scope: key.pathScope)
                        guard path.path.utf8.elementsEqual(prompt.path.utf8) else { throw SyncPullCollectorError.invalidResponse }
                    case .delete(_, let id), .moveOut(_, let id): _ = try SyncIdentifiers.ulid(id)
                    }
                }
            }
            return databaseID
        } catch { throw SyncPullCollectorError.invalidResponse }
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        try permit?.check()
        if Task.isCancelled { throw SyncHTTPClientError.transport(.cancelled) }
        guard now() < deadline else { throw SyncPullCollectorError.noProgress(.collectionDeadline) }
    }

    private func sameCursor(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    private func sameCursors(_ lhs: [String: String], _ rhs: [String: String]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { key, cursor in rhs[key].map { sameCursor(cursor, $0) } ?? false }
    }
}
