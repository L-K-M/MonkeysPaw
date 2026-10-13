import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedVisibilityTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func privateOwnerAndCurrentGroupMembershipDetermineVisibility(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader", kind: kind)
            let group = try await fixture.group(owner: owner)
            let hiddenGroup = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            if let role = role.role { try await fixture.member(groupID: group.id, user: reader, role: role) }
            let session = try await fixture.account.session(reader)
            let personal = PromptOwnership.user(ownerID: reader.id)
            let shared = PromptOwnership.group(groupID: group.id)
            let privateCursor = try #require(await fixture.seedFeed(identity: personal, count: 1).last)
            let groupCursor = try #require(await fixture.seedFeed(identity: shared, count: 1).last)
            let personalSeq = try #require(await fixture.seedFeed(identity: personal, count: 1, startingID: 10).last)
            let groupSeqs = try await fixture.seedFeed(identity: shared, count: 2, startingID: 20)
            _ = try await fixture.seedFeed(identity: .user(ownerID: owner.id), count: 1, startingID: 30, content: "Foreign private bytes")
            _ = try await fixture.seedFeed(identity: .group(groupID: hiddenGroup.id), count: 1, startingID: 40, content: "Foreign group bytes")
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, shared.key: groupCursor,
                                                                 "user:\(owner.id)": 0, "group:\(hiddenGroup.id)": 0])
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) {
                    let response = try PromptHTTPTest.success($0, as: SyncAPI.PullResponse.self)
                    let privatePage = try response.scope(personal.key)
                    #expect(privatePage.identity == .user(userID: reader.id))
                    #expect(privatePage.items.map(\.seq) == [personalSeq] && !privatePage.hasMore)
                    #expect(response.scopes.count == (role == .nonMember ? 1 : 2))
                    let expectedRemoved = ["user:\(owner.id)", "group:\(hiddenGroup.id)"] + (role == .nonMember ? [shared.key] : [])
                    #expect(response.removed == expectedRemoved.sorted())
                    if let membership = role.role {
                        let page = try response.scope(shared.key)
                        #expect(page.identity == .group(groupID: group.id, name: group.name, role: membership))
                        #expect(page.mode == .delta && page.items.map(\.seq) == groupSeqs)
                        #expect(page.cursor == String(try #require(groupSeqs.last)) && !page.hasMore)
                    }
                    let wire = String(decoding: $0.body.readableBytesView, as: UTF8.self)
                    for hidden in ["Foreign private bytes", "Foreign group bytes", feedTestID(30), feedTestID(40)] {
                        #expect(!wire.contains(hidden))
                    }
                }
            }
        }
    }

    @Test func quietScopeRenameRoleRemovalAndDeletionAreImmediatelyVisible() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader")
            let group = try await fixture.group(owner: owner)
            let second = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            for group in [group, second] { try await fixture.member(groupID: group.id, user: reader, role: .viewer) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(reader)
            let personal = PromptOwnership.user(ownerID: reader.id)
            let firstKey = "group:\(group.id)", secondKey = "group:\(second.id)"
            let privateCursor = try #require(await fixture.seedFeed(identity: personal, count: 1).last)
            let firstCursor = try #require(await fixture.seedFeed(identity: .group(groupID: group.id), count: 1).last)
            let secondCursor = try #require(await fixture.seedFeed(identity: .group(groupID: second.id), count: 1).last)
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, firstKey: firstCursor, secondKey: secondCursor])
            let quiet = try await fixture.feed.pull(request: request, session: session.identity)
            #expect(quiet.scopes.count == 3 && quiet.scopes.allSatisfy { $0.items.isEmpty && !$0.hasMore })
            _ = try await fixture.service.rename(id: group.id, request: .init(name: "Renamed / \"group\""), session: ownerSession.identity)
            _ = try await fixture.service.upsertMember(id: group.id, userID: reader.id, request: .init(role: .editor), session: ownerSession.identity)
            let renamed = try await fixture.feed.pull(request: request, session: session.identity)
            let page = try renamed.scope(firstKey)
            #expect(page.identity == .group(groupID: group.id, name: "Renamed / \"group\"", role: .editor))
            #expect(page.head == firstCursor && page.cursor == String(firstCursor) && page.items.isEmpty && !page.hasMore)
            try await fixture.service.removeMember(id: group.id, userID: reader.id, session: ownerSession.identity)
            try await fixture.service.delete(id: second.id, session: ownerSession.identity)
            let removed = try await fixture.feed.pull(request: request, session: session.identity)
            #expect(removed.removed == [firstKey, secondKey].sorted())
            #expect(removed.scopes.count == 1 && removed.scopes[0].identity == .user(userID: reader.id))
            #expect(removed.scopes[0].items.isEmpty && !removed.scopes[0].hasMore)
            let acknowledged = try await fixture.feed.pull(request: removed.continuation, session: session.identity)
            #expect(acknowledged.removed.isEmpty && acknowledged.scopes == removed.scopes)
        }
    }
}
