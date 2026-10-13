import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedSchedulingTests {
    @Test func partialRoundUsesOldestPendingSequenceRatherThanScopeOrder() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let low = try await fixture.group(owner: user)
            let high = try await fixture.group(owner: user, id: PersistenceTestRepository.otherGroup)
            let session = try await fixture.account.session(user)
            // Repository order is private, low, high; pending order is high, private, low.
            let identities: [PromptOwnership] = [.group(groupID: high.id), .user(ownerID: user.id), .group(groupID: low.id)]
            var cursors: [String: Int64] = [:]
            var sequences: [String: [Int64]] = [:]
            for (index, identity) in identities.enumerated() {
                let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
                cursors[identity.key] = baseline
                sequences[identity.key] = try await fixture.seedFeed(identity: identity, count: 70, startingID: 100 * (index + 1))
            }
            let request = try await fixture.feedRequest(cursors: cursors)
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            #expect(first.scopes.reduce(0) { $0 + $1.items.count } == 200)
            for (index, identity) in identities.enumerated() {
                let expected = try #require(sequences[identity.key])
                let page = try first.scope(identity.key)
                // 66 complete rounds, then the two oldest scopes get the remaining turns.
                let count = index < 2 ? 67 : 66
                #expect(page.items.map(\.seq) == Array(expected.prefix(count)))
                #expect(page.cursor == String(expected[count - 1]) && page.hasMore)
                let last = try second.scope(identity.key)
                #expect(last.items.map(\.seq) == Array(expected.dropFirst(count)))
                #expect(last.cursor == String(expected[69]) && !last.hasMore)
            }
        }
    }

    @Test func oldestTwoHundredScopesWinTheBoundaryEvenWhenTheirKeysSortLast() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id)
            var cursors: [String: Int64] = [personal.key: try #require(await fixture.seedFeed(identity: personal, count: 1).last)]
            let groups = (1...205).map {
                SyncAPI.Group(id: feedTestID(10_000 + $0), name: "Scope \($0)", createdBy: user.id, createdAt: user.createdAt)
            }
            try await fixture.repository.write { repository, _, _, _ in
                for group in groups {
                    try await repository.insert(group)
                    try await repository.upsertMember(groupID: group.id, userID: user.id, role: .owner, at: user.createdAt)
                }
            }
            var expected: [String: Int64] = [:]
            for (index, group) in groups.reversed().enumerated() {
                let identity = PromptOwnership.group(groupID: group.id)
                let seqs = try await fixture.seedFeed(identity: identity, count: 2, startingID: 100 + 2 * index)
                cursors[identity.key] = seqs[0]
                expected[identity.key] = seqs[1]
            }
            let noisy = try await fixture.seedFeed(identity: personal, count: 201, startingID: 20_000)
            let request = try await fixture.feedRequest(cursors: cursors)
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            let selected = Set(groups.reversed().prefix(200).map { "group:\($0.id)" })
            #expect(Set(first.scopes.filter { !$0.items.isEmpty }.map(\.identity.key)) == selected)
            for page in first.scopes {
                if selected.contains(page.identity.key) {
                    let seq = try #require(expected[page.identity.key])
                    #expect(page.items.map(\.seq) == [seq] && page.cursor == String(seq) && !page.hasMore)
                } else {
                    let cursor = try #require(cursors[page.identity.key])
                    #expect(page.items.isEmpty && page.cursor == String(cursor) && page.hasMore)
                }
            }
            // Fresh private writes must not overtake the five older, deferred group rows.
            _ = try await fixture.seedFeed(identity: personal, count: 1, startingID: 30_000)
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            for group in groups.prefix(5) {
                let page = try second.scope("group:\(group.id)")
                #expect(page.items.map(\.seq) == [try #require(expected[page.identity.key])] && !page.hasMore)
            }
            let privatePage = try second.scope(personal.key)
            #expect(privatePage.items.map(\.seq) == Array(noisy.prefix(195)))
            #expect(privatePage.cursor == String(noisy[194]) && privatePage.hasMore)
        }
    }
}
