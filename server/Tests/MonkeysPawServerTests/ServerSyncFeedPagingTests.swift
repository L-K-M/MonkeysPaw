import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedPagingTests {
    @Test func itemBudgetIsSharedAndOnlyConsumedRowsAdvanceTheCursor() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let sequences = try await fixture.seedFeed(identity: identity, count: 201, startingID: 10)
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            #expect(first == (try await fixture.feed.pull(request: request, session: session.identity)))
            let page = try first.scope(identity.key)
            #expect(page.items.map(\.seq) == Array(sequences.prefix(200)))
            #expect(page.cursor == String(sequences[199]) && page.head == sequences[200] && page.hasMore)
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            let last = try second.scope(identity.key)
            #expect(last.items.map(\.seq) == [sequences[200]] && last.cursor == String(sequences[200]) && !last.hasMore)
            let empty = try await fixture.feed.pull(request: second.continuation, session: session.identity)
            let emptyPage = try empty.scope(identity.key)
            #expect(emptyPage.items.isEmpty && !emptyPage.hasMore)
            #expect(emptyPage.cursor == last.cursor && emptyPage.head == last.head)
        }
    }

    @Test(arguments: ["upsert", "delete", "move_out"])
    func adjacentRunsPreserveTheFinalPayloadAndKind(kind: String) async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let id = feedTestID(10)
            let changes: [FeedTestChange] = [
                .init(id: id, rev: 1, content: "Original"),
                .init(id: id, path: "Renamed.md", rev: 2, content: "Edited"),
                .init(id: id, path: "Final.md", rev: 3, kind: kind, content: kind == "upsert" ? "Final" : nil)
            ]
            let seqs = try await fixture.seedFeed(identity: identity, changes: changes)
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let page = try await fixture.feed.pull(request: request, session: session.identity).scope(identity.key)
            let seq = try #require(seqs.last)
            let expected: SyncAPI.FeedItem
            switch kind {
            case "upsert": expected = .upsert(seq: seq, prompt: .init(id: id, rev: 3, path: "Final.md", content: "Final"))
            case "delete": expected = .delete(seq: seq, id: id)
            default: expected = .moveOut(seq: seq, id: id)
            }
            #expect(page.items == [expected] && page.cursor == String(seq) && !page.hasMore)
        }
    }

    @Test func interveningPromptsPreventCollapseAndKeepSequenceOrdering() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let first = feedTestID(10), other = feedTestID(11)
            let seqs = try await fixture.seedFeed(identity: identity, changes: [
                .init(id: first, rev: 1, content: "Before"), .init(id: other, path: "Other.md", content: "Other"),
                .init(id: first, rev: 2, content: "After")
            ])
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let page = try await fixture.feed.pull(request: request, session: session.identity).scope(identity.key)
            #expect(page.items.map(\.seq) == seqs)
            #expect(page.items == [
                .upsert(seq: seqs[0], prompt: .init(id: first, rev: 1, path: "Example.md", content: "Before")),
                .upsert(seq: seqs[1], prompt: .init(id: other, rev: 1, path: "Other.md", content: "Other")),
                .upsert(seq: seqs[2], prompt: .init(id: first, rev: 2, path: "Example.md", content: "After"))
            ])
            #expect(page.cursor == String(seqs[2]) && !page.hasMore)
        }
    }

    @Test func longCollapsedRunsHaveBoundedWorkAndContinueAtHighestConsumedSequence() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let id = feedTestID(10)
            let seqs = try await fixture.seedFeed(identity: identity, changes: (1...1_005).map {
                .init(id: id, rev: Int64($0), content: "Revision \($0)")
            })
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let first = try await fixture.feed.pull(request: request, session: session.identity)
            let page = try first.scope(identity.key)
            #expect(page.items == [.upsert(seq: seqs[999], prompt: .init(id: id, rev: 1_000, path: "Example.md", content: "Revision 1000"))])
            #expect(page.cursor == String(seqs[999]) && page.head == seqs[1_004] && page.hasMore)
            let last = try await fixture.feed.pull(request: first.continuation, session: session.identity).scope(identity.key)
            #expect(last.items == [.upsert(seq: seqs[1_004], prompt: .init(id: id, rev: 1_005, path: "Example.md", content: "Revision 1005"))])
            #expect(last.cursor == String(seqs[1_004]) && !last.hasMore)
        }
    }

    @Test func busyScopesShareTurnsRatherThanUsingTheWholePageOnOneScope() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let identities: [PromptOwnership] = [.user(ownerID: user.id), .group(groupID: group.id)]
            var cursors: [String: Int64] = [:]
            var expected: [String: [Int64]] = [:]
            for (index, identity) in identities.enumerated() {
                cursors[identity.key] = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
                expected[identity.key] = try await fixture.seedFeed(identity: identity, count: 250, startingID: 1_000 * (index + 1))
            }
            var request = try await fixture.feedRequest(cursors: cursors)
            var collected: [String: [Int64]] = [:]
            for turn in 0..<3 {
                let response = try await fixture.feed.pull(request: request, session: session.identity)
                #expect(response.scopes.reduce(0) { $0 + $1.items.count } == (turn == 2 ? 100 : 200))
                for scope in response.scopes {
                    #expect(scope.items.count == (turn == 2 ? 50 : 100))
                    #expect(scope.hasMore == (turn < 2))
                    collected[scope.identity.key, default: []] += scope.items.map(\.seq)
                    #expect(try #require(Int64(scope.cursor)) > #require(Int64(request.cursors[scope.identity.key] ?? "")))
                }
                request = response.continuation
            }
            #expect(collected == expected)
        }
    }

    @Test func moreThanTwoHundredScopesProgressDespiteNewWritesInANoisyScope() async throws {
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
            for (index, group) in groups.enumerated() {
                let identity = PromptOwnership.group(groupID: group.id)
                let seqs = try await fixture.seedFeed(identity: identity, count: 2, startingID: 2 * index + 100)
                cursors[identity.key] = seqs[0]
            }
            _ = try await fixture.seedFeed(identity: personal, count: 500, startingID: 20_000)
            var request = try await fixture.feedRequest(cursors: cursors)
            var seen = Set<String>()
            for turn in 0..<2 {
                let response = try await fixture.feed.pull(request: request, session: session.identity)
                #expect(response.scopes.count == 206)
                #expect(response.scopes.reduce(0) { $0 + $1.items.count } == 200)
                seen.formUnion(response.scopes.filter { $0.identity.key != personal.key && !$0.items.isEmpty }.map { $0.identity.key })
                request = response.continuation
                _ = try await fixture.seedFeed(identity: personal, count: 1, startingID: 30_000 + turn)
            }
            #expect(seen == Set(groups.map { "group:\($0.id)" }))
        }
    }

    @Test(arguments: [false, true])
    func exactHTTPBytesIncludeEscapingAndMetadataAndDoNotSkipLargeRows(escaped: Bool) async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let identities: [PromptOwnership] = [.user(ownerID: user.id), .group(groupID: group.id)]
            let count = escaped ? 12 : 20
            let content = String(repeating: escaped ? "\u{01}" : "x", count: Limits.maxPromptBytes)
            _ = try await fixture.service.rename(id: group.id, request: .init(name: String(repeating: "\"\\/\t", count: 60)), session: session.identity)
            var cursors: [String: Int64] = [:]
            var expected: [String: [Int64]] = [:]
            for (index, identity) in identities.enumerated() {
                cursors[identity.key] = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
                expected[identity.key] = try await fixture.seedFeed(identity: identity, count: count, startingID: 100 * (index + 1), content: content)
            }
            let deltaRequest = try await fixture.feedRequest(cursors: cursors)
            let removed = Dictionary(uniqueKeysWithValues: (1...100).map { ("group:" + feedTestID(40_000 + $0), "0") })
            let request = SyncAPI.PullRequest(databaseID: deltaRequest.databaseID, cursors: deltaRequest.cursors.merging(removed) { _, new in new })
            let expectedSequences = expected
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) {
                    let response = try PromptHTTPTest.success($0, as: SyncAPI.PullResponse.self)
                    #expect($0.body.readableBytes <= ServerLimits.syncPageBytes && $0.body.readableBytes <= SyncAPI.responseEnvelopeMaxBytes)
                    #expect(response.scopes.reduce(0) { $0 + $1.items.count } == (escaped ? 5 : 31))
                    #expect(response.scopes.allSatisfy { $0.hasMore })
                    #expect(response.removed == removed.keys.sorted())
                    for scope in response.scopes {
                        #expect(scope.items.map(\.seq) == Array(try #require(expectedSequences[scope.identity.key]).prefix(scope.items.count)))
                        #expect(scope.cursor == String(try #require(scope.items.last?.seq)))
                    }
                }
            }
            var next = request
            var collected: [String: [Int64]] = [:]
            for _ in 0..<10 {
                let response = try await fixture.feed.pull(request: next, session: session.identity)
                let encodedBytes = try JSONEncoder().encode(response).count
                #expect(encodedBytes <= ServerLimits.syncPageBytes && encodedBytes <= SyncAPI.responseEnvelopeMaxBytes)
                #expect(!response.scopes.flatMap(\.items).isEmpty)
                for scope in response.scopes { collected[scope.identity.key, default: []] += scope.items.map(\.seq) }
                next = response.continuation
                if !response.scopes.contains(where: \.hasMore) { break }
            }
            #expect(collected == expected)
        }
    }
}
