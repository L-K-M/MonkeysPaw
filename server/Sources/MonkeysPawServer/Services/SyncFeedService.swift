import Crypto
import Foundation
import MonkeysPawCore

enum SyncFeedError: Error, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case snapshotTooLarge
    case responseTooLarge

    var description: String { "SyncFeedError(<redacted>)" }
    var debugDescription: String { description }
}

struct SyncFeedService: Sendable {
    private let repository: SyncFeedRepository
    private let clock: @Sendable () -> Date

    init(database: ServerDatabase, clock: @escaping @Sendable () -> Date = { Date() }) {
        repository = .init(database: database)
        self.clock = clock
    }

    func pull(request: SyncAPI.PullRequest, session: SessionIdentity) async throws -> SyncAPI.PullResponse {
        try AccountValidation.dto(request)
        let cursors = try request.cursors.mapValues(FeedCursor.init)
        for (key, cursor) in cursors {
            if case .snapshot(let snapshot) = cursor {
                guard snapshot.scopeKey == key, snapshot.databaseID == request.databaseID else { throw AccountError.malformedRequest }
            }
        }
        if let response = try await repository.read({ feed, accounts, devices in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            return try await page(feed: feed, actorID: actor.id, request: request, cursors: cursors, creation: .existingOnly)
        }) { return response }
        return try await repository.write { feed, accounts, devices in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            guard let response = try await page(feed: feed, actorID: actor.id, request: request, cursors: cursors, creation: .allowed) else {
                throw SyncFeedPersistenceError.invalidRecord
            }
            return response
        }
    }

    private func page(feed: SyncFeedRepository.Transaction, actorID: String, request: SyncAPI.PullRequest,
                      cursors: [String: FeedCursor], creation: SnapshotCreation) async throws -> SyncAPI.PullResponse? {
        let now = clock()
        let databaseID = try await feed.databaseID()
        let scopes = try await feed.scopes(userID: actorID)
        let keys = Set(scopes.map { $0.identity.key })
        let removed = request.cursors.keys.filter { !keys.contains($0) }.sorted()
        let protected = Set(scopes.filter { needsSnapshot($0, databaseID: databaseID, request: request, cursors: cursors) }.map { scope in
            let head: Int64
            if case .snapshot(let cursor) = cursors[scope.identity.key] { head = cursor.head } else { head = scope.head }
            return SnapshotID(databaseID: databaseID, scopeKey: scope.identity.key, head: head)
        })
        let hasSignedCursor = cursors.values.contains {
            if case .snapshot(let cursor) = $0 { return cursor.databaseID == databaseID }
            return false
        }
        let signingKey = protected.isEmpty && !hasSignedCursor ? nil : try await feed.snapshots.signingKey()
        if let signingKey {
            for cursor in cursors.values {
                if case .snapshot(let snapshot) = cursor, snapshot.databaseID == databaseID {
                    try snapshot.validate(using: signingKey)
                }
            }
        }
        var pages: [FeedPage] = []
        var expired: [String] = []
        var needsWrite = false
        for scope in scopes {
            let key = scope.identity.key
            if case .snapshot(let cursor) = cursors[key] {
                // A restored/reset database may no longer have the old signing key.
                // Its UUID invalidates the entire incomplete snapshot regardless.
                guard cursor.databaseID == databaseID else { expired.append(key); continue }
                let id = SnapshotID(databaseID: databaseID, scopeKey: key, head: cursor.head)
                guard cursor.head <= scope.head, let snapshot = try await feed.snapshots.snapshot(id, now: now),
                      snapshot.generation == cursor.generation else { expired.append(key); continue }
                guard cursor.position < snapshot.prompts.count else { throw AccountError.malformedRequest }
                let frozenScope = FeedScopeRecord(identity: scope.identity, head: cursor.head, floor: scope.floor)
                pages.append(.init(scope: frozenScope, snapshot: snapshot, position: cursor.position))
            } else if protected.contains(.init(databaseID: databaseID, scopeKey: key, head: scope.head)) {
                let id = SnapshotID(databaseID: databaseID, scopeKey: key, head: scope.head)
                let snapshot: FrozenSnapshot
                if let cached = try await feed.snapshots.snapshot(id, now: now) { snapshot = cached }
                else if creation == .allowed {
                    snapshot = try await feed.snapshots.materialize(id, identity: scope.identity, now: now, protecting: protected)
                } else { needsWrite = true; continue }
                pages.append(.init(scope: scope, snapshot: snapshot))
            } else {
                guard case .sequence(let cursor) = cursors[key] else { throw SyncFeedPersistenceError.invalidRecord }
                let next = try await feed.nextSequence(key: scope.identity.key, after: cursor, through: scope.head)
                pages.append(.init(scope: scope, cursor: cursor, next: next))
            }
        }
        if !expired.isEmpty { throw PromptError(.snapshotExpired(scopes: expired.sorted())) }
        if needsWrite { return nil }
        let encoder = JSONEncoder()
        // Reserve metadata at its widest possible cursor and boolean spellings.
        let envelope = SyncAPI.PullResponse(databaseID: databaseID, scopes: pages.map {
            $0.response(databaseID: databaseID, signingKey: signingKey, reservation: .metadata)
        }, removed: removed)
        var bytes = try encoder.encode(envelope).count
        guard bytes <= ServerLimits.syncPageBytes else { throw SyncFeedError.responseTooLarge }
        var emitted = 0
        var consumed = 0

        paging: while consumed < ServerLimits.syncPageMaxChanges {
            // One turn per scope; older pending rows win partial rounds and later pages.
            let pending = pages.indices.compactMap { index in pages[index].pendingSequence.map { (index, $0) } }
                .sorted { $0.1 == $1.1 ? pages[$0.0].scope.identity.key < pages[$1.0].scope.identity.key : $0.1 < $1.1 }
            if pending.isEmpty { break }
            for (index, seq) in pending {
                let page = pages[index]
                let item: SyncAPI.FeedItem
                if let snapshot = page.snapshot { item = .upsert(seq: seq, prompt: snapshot.prompts[page.position]) }
                else { item = try await feed.item(key: page.scope.identity.key, seq: seq) }
                let collapse = page.snapshot == nil && page.items.last?.promptID == item.promptID
                if !collapse && emitted == ServerLimits.syncPageMaxItems { break paging }
                let itemBytes = try encoder.encode(item).count
                let growth = collapse ? itemBytes - page.lastItemBytes : itemBytes + (page.items.isEmpty ? 0 : 1)
                guard bytes + growth <= ServerLimits.syncPageBytes else {
                    if consumed == 0 { throw SyncFeedError.responseTooLarge }
                    break paging
                }

                bytes += growth
                if collapse { pages[index].items[page.items.count - 1] = item }
                else {
                    pages[index].items.append(item)
                    emitted += 1
                }
                pages[index].lastItemBytes = itemBytes
                consumed += 1
                if page.snapshot != nil { pages[index].position += 1 }
                else {
                    pages[index].cursor = seq
                    pages[index].next = try await feed.nextSequence(key: page.scope.identity.key, after: seq, through: page.scope.head)
                }
                if consumed == ServerLimits.syncPageMaxChanges { break paging }
            }
        }

        let response = SyncAPI.PullResponse(databaseID: databaseID, scopes: pages.map {
            $0.response(databaseID: databaseID, signingKey: signingKey, reservation: .none)
        }, removed: removed)
        let finalBytes = try encoder.encode(response).count
        guard finalBytes <= ServerLimits.syncPageBytes, finalBytes <= SyncAPI.responseEnvelopeMaxBytes else {
            throw SyncFeedError.responseTooLarge
        }
        assert(finalBytes <= bytes, "Feed JSON exceeded its serialized byte reservation")
        return response
    }

    private func needsSnapshot(_ scope: FeedScopeRecord, databaseID: String, request: SyncAPI.PullRequest,
                               cursors: [String: FeedCursor]) -> Bool {
        guard request.databaseID == databaseID, case .sequence(let cursor) = cursors[scope.identity.key],
              cursor > 0, cursor <= scope.head, cursor >= scope.floor - 1 else { return true }
        return false
    }
}

private enum SnapshotCreation { case existingOnly, allowed }

private enum FeedCursor: Sendable {
    case sequence(Int64)
    case snapshot(SnapshotCursor)

    init(_ value: String) throws {
        if value.hasPrefix("snap:") {
            self = .snapshot(try SnapshotCursor(value))
            return
        }
        guard let seq = Int64(value), seq >= 0, String(seq) == value else { throw AccountError.malformedRequest }
        self = .sequence(seq)
    }
}

private struct FeedPage {
    let scope: FeedScopeRecord
    var cursor: Int64 = 0
    var next: Int64?
    var snapshot: FrozenSnapshot?
    var position = 0
    var items: [SyncAPI.FeedItem] = []
    var lastItemBytes = 0

    var pendingSequence: Int64? {
        if let snapshot { return position < snapshot.prompts.count ? scope.head : nil }
        return next
    }

    enum Reservation { case none, metadata }

    func response(databaseID: String, signingKey: SymmetricKey?, reservation: Reservation) -> SyncAPI.SyncScope {
        let more = pendingSequence != nil
        let value: String
        if let snapshot, let signingKey, more {
            value = SnapshotCursor(databaseID: databaseID, scopeKey: scope.identity.key, head: scope.head,
                                   generation: snapshot.generation, position: reservation == .metadata ? snapshot.prompts.count : position)
                .value(using: signingKey)
        } else { value = String(snapshot != nil || reservation == .metadata ? scope.head : cursor) }
        return .init(identity: scope.identity, mode: snapshot == nil ? .delta : .snapshot, head: scope.head,
                     cursor: value, hasMore: reservation == .metadata ? false : more, items: reservation == .metadata ? [] : items)
    }
}

private extension SyncAPI.FeedItem {
    var promptID: String {
        switch self {
        case .upsert(_, let prompt): return prompt.id
        case .delete(_, let id), .moveOut(_, let id): return id
        }
    }
}
