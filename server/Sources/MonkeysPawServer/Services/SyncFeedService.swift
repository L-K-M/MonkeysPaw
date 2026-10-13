import Foundation
import MonkeysPawCore

enum SyncFeedError: Error, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// TODO S14: materialize/continue frozen snapshots instead of failing this request.
    case snapshotRequired(scopes: [String])
    case responseTooLarge

    var description: String { "SyncFeedError(<redacted>)" }
    var debugDescription: String { description }
}

struct SyncFeedService: Sendable {
    private let repository: SyncFeedRepository

    init(database: ServerDatabase) { repository = .init(database: database) }

    func pull(request: SyncAPI.PullRequest, session: SessionIdentity) async throws -> SyncAPI.PullResponse {
        try AccountValidation.dto(request)
        let cursors = try request.cursors.mapValues(FeedCursor.init)
        return try await repository.read { feed, accounts, devices in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let databaseID = try await feed.databaseID()
            let scopes = try await feed.scopes(userID: actor.id)
            let keys = Set(scopes.map { $0.identity.key })
            let removed = request.cursors.keys.filter { !keys.contains($0) }.sorted()
            let snapshots = scopes.filter { scope in
                guard request.databaseID == databaseID, case .sequence(let cursor) = cursors[scope.identity.key],
                      cursor > 0, cursor <= scope.head, cursor >= scope.floor - 1 else { return true }
                return false
            }
            guard snapshots.isEmpty else { throw SyncFeedError.snapshotRequired(scopes: snapshots.map { $0.identity.key }) }

            var pages: [FeedPage] = []
            for scope in scopes {
                guard case .sequence(let cursor) = cursors[scope.identity.key] else { throw SyncFeedPersistenceError.invalidRecord }
                let next = try await feed.nextSequence(key: scope.identity.key, after: cursor, through: scope.head)
                pages.append(.init(scope: scope, cursor: cursor, next: next))
            }
            let encoder = JSONEncoder()
            // Reserve metadata at its widest possible cursor and boolean spellings.
            let envelope = SyncAPI.PullResponse(databaseID: databaseID, scopes: scopes.map {
                .init(identity: $0.identity, mode: .delta, head: $0.head, cursor: String($0.head), hasMore: false, items: [])
            }, removed: removed)
            var bytes = try encoder.encode(envelope).count
            guard bytes <= ServerLimits.syncPageBytes else { throw SyncFeedError.responseTooLarge }
            var emitted = 0
            var consumed = 0

            paging: while consumed < ServerLimits.syncPageMaxChanges {
                // One turn per scope; older pending rows win partial rounds and later pages.
                let pending = pages.indices.compactMap { index in pages[index].next.map { (index, $0) } }
                    .sorted { $0.1 < $1.1 }
                if pending.isEmpty { break }
                for (index, seq) in pending {
                    let page = pages[index]
                    let item = try await feed.item(key: page.scope.identity.key, seq: seq)
                    let collapse = page.items.last?.promptID == item.promptID
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
                    pages[index].cursor = seq
                    consumed += 1
                    pages[index].next = try await feed.nextSequence(key: page.scope.identity.key, after: seq, through: page.scope.head)
                    if consumed == ServerLimits.syncPageMaxChanges { break paging }
                }
            }

            let response = SyncAPI.PullResponse(databaseID: databaseID, scopes: pages.map(\.response), removed: removed)
            let finalBytes = try encoder.encode(response).count
            guard finalBytes <= ServerLimits.syncPageBytes, finalBytes <= SyncAPI.responseEnvelopeMaxBytes else {
                throw SyncFeedError.responseTooLarge
            }
            assert(finalBytes <= bytes, "Feed JSON exceeded its serialized byte reservation")
            return response
        }
    }
}

private enum FeedCursor {
    case sequence(Int64)
    case snapshot

    init(_ value: String) throws {
        if value.hasPrefix("snap:"), value.utf8.count > 5 {
            self = .snapshot
            return
        }
        guard let seq = Int64(value), seq >= 0, String(seq) == value else { throw AccountError.malformedRequest }
        self = .sequence(seq)
    }
}

private struct FeedPage {
    let scope: FeedScopeRecord
    var cursor: Int64
    var next: Int64?
    var items: [SyncAPI.FeedItem] = []
    var lastItemBytes = 0

    var response: SyncAPI.SyncScope {
        .init(identity: scope.identity, mode: .delta, head: scope.head, cursor: String(cursor), hasMore: next != nil, items: items)
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
