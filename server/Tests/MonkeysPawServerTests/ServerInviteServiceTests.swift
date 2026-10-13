import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerInviteServiceTests {
    @Test func expiryBoundsSingleUseAndCollisionRollback() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let group = try await fixture.group(owner: admin)
            let session = try await fixture.account.session(admin)
            let hasher = InviteTestHasher()
            let service = fixture.inviteService(passwords: hasher)
            for ttl in [Int64(-1), 0, 604_801, .max] {
                await #expect(throws: AccountError.malformedRequest) {
                    _ = try await service.createAdmin(.init(target: .account, expiresIn: ttl), session: session.identity)
                }
                await #expect(throws: AccountError.malformedRequest) {
                    _ = try await service.createGroup(id: group.id, request: .init(role: .viewer, expiresIn: ttl), session: session.identity)
                }
            }
            #expect(try await fixture.persistence.count("invites") == 0)
            let issued = try await service.createAdmin(.init(target: .account), session: session.identity)
            #expect(ServerTimestamp.date(issued.response.expiresAt) == fixture.account.clock.now().addingTimeInterval(604_800))
            #expect(issued.link != nil && String(reflecting: issued) == "IssuedInvite(<redacted>)")
            let registration = SyncAPI.RegisterRequest(inviteToken: issued.response.inviteToken, username: "admin",
                                                       password: AccountTestFixture.password, deviceName: "New device")
            await #expect(throws: AccountError.malformedRequest) { _ = try await service.register(registration) }
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
            #expect(try await fixture.persistence.count("users") == 1)
            #expect(try await fixture.persistence.count("devices") == 1)
            #expect(try await fixture.persistence.count("audit_events") == 1)
            let auth = try await service.register(.init(inviteToken: issued.response.inviteToken, username: "available",
                                                       password: AccountTestFixture.password, deviceName: "New device"))
            #expect(auth.user.accountKind == .member)
            #expect(try await fixture.account.sessions.authenticate(token: auth.token.value) == auth.identity)
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == ServerTimestamp.string(fixture.account.clock.now()))
            let work = await hasher.hashes()
            await #expect(throws: AccountError.malformedRequest) { _ = try await service.register(registration) }
            #expect(await hasher.hashes() == work)

            let short = try await service.createGroup(id: group.id, request: .init(role: .viewer, expiresIn: 1), session: session.identity)
            fixture.account.clock.advance(1)
            let expired = SyncAPI.RegisterRequest(inviteToken: short.response.inviteToken, username: "expired",
                                                  password: AccountTestFixture.password, deviceName: "Expired device")
            await #expect(throws: AccountError.malformedRequest) { _ = try await service.register(expired) }
            await #expect(throws: AccountError.malformedRequest) {
                _ = try await service.join(.init(inviteToken: short.response.inviteToken), session: auth.identity)
            }
            #expect(await hasher.hashes() == work)
            #expect(try await fixture.persistence.storedInvite(short.response.inviteToken).consumedAt == nil)
        }
    }

    @Test(arguments: ["register", "join", "mixed"])
    func parallelRedemptionsHaveExactlyOneWinner(operation: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let ownerSession = try await fixture.account.session(owner)
            let members = try await [fixture.user("first"), fixture.user("second")]
            let memberSessions = try await [fixture.account.session(members[0]), fixture.account.session(members[1])]
            let service = fixture.inviteService()
            for attempt in 0..<5 {
                let issued = try await service.createGroup(id: group.id, request: .init(role: .editor), session: ownerSession.identity)
                let before = try await fixture.persistence.count("users")
                let devices = try await fixture.persistence.count("devices")
                let audits = try await fixture.persistence.count("audit_events")
                let start = LoginTestLatch()
                let winners = try await withThrowingTaskGroup(of: String?.self) { tasks in
                    for index in 0..<2 {
                        tasks.addTask {
                            await start.wait()
                            do {
                                if operation == "register" || (operation == "mixed" && index == 0) {
                                    let auth = try await service.register(.init(inviteToken: issued.response.inviteToken,
                                                                               username: "race-\(attempt)-\(index)", password: AccountTestFixture.password,
                                                                               deviceName: "Race device"))
                                    return auth.user.id
                                }
                                _ = try await service.join(.init(inviteToken: issued.response.inviteToken), session: memberSessions[index].identity)
                                return memberSessions[index].user.id
                            } catch AccountError.malformedRequest { return nil }
                        }
                    }
                    await start.open()
                    var winners: [String] = []
                    for try await winner in tasks { if let winner { winners.append(winner) } }
                    return winners
                }
                #expect(winners.count == 1)
                let winner = try #require(winners.first)
                let registered = !members.contains { $0.id == winner }
                #expect(try await fixture.persistence.count("users") == before + (registered ? 1 : 0))
                #expect(try await fixture.persistence.count("devices") == devices + (registered ? 1 : 0))
                #expect(try await fixture.persistence.count("audit_events") == audits + (registered ? 3 : 2))
                #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt != nil)
                #expect(try await fixture.repository.read { groups, _, _ in try await groups.member(groupID: group.id, userID: winner)?.role } == .editor)
            }
        }
    }

    @Test func parallelUsernameCollisionLeavesTheLosingInviteUsable() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let session = try await fixture.account.session(admin)
            let service = fixture.inviteService()
            let invites = try await [service.createAdmin(.init(target: .account), session: session.identity),
                                     service.createAdmin(.init(target: .account), session: session.identity)]
            let start = LoginTestLatch()
            let winner = try await withThrowingTaskGroup(of: Int?.self) { tasks in
                for index in invites.indices {
                    tasks.addTask {
                        await start.wait()
                        do {
                            _ = try await service.register(.init(inviteToken: invites[index].response.inviteToken, username: "collision",
                                                                password: AccountTestFixture.password, deviceName: "Collision device"))
                            return index
                        } catch AccountError.malformedRequest { return nil }
                    }
                }
                await start.open()
                var winners: [Int] = []
                for try await winner in tasks { if let winner { winners.append(winner) } }
                #expect(winners.count == 1)
                return try #require(winners.first)
            }
            let losing = invites[1 - winner].response.inviteToken
            #expect(try await fixture.persistence.storedInvite(losing).consumedAt == nil)
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("devices") == 2)
            #expect(try await fixture.persistence.count("audit_events") == 4)
            _ = try await service.register(.init(inviteToken: losing, username: "second-account", password: AccountTestFixture.password, deviceName: "Retry"))
            #expect(try await fixture.persistence.count("users") == 3)
            #expect(try await fixture.persistence.count("devices") == 3)
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func joinsPreserveHigherRolesAndDenyAdminSelfGrants(kind: SyncAPI.AccountKind, current: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let user = try await fixture.user("joining", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = current.role { try await fixture.member(groupID: group.id, user: user, role: role) }
            let issuer = try await fixture.account.session(owner)
            let session = try await fixture.account.session(user)
            let service = fixture.inviteService()
            fixture.account.clock.advance(60)
            for role in [SyncAPI.InviteRole.editor, .viewer] {
                let issued = try await service.createGroup(id: group.id, request: .init(role: role), session: issuer.identity)
                let request = SyncAPI.JoinGroupRequest(inviteToken: issued.response.inviteToken)
                let denied = kind == .admin && (current == .nonMember || (current == .viewer && role == .editor))
                if denied {
                    await #expect(throws: AccountError.forbidden) { _ = try await service.join(request, session: session.identity) }
                    #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
                    continue
                }
                let joined = try await service.join(request, session: session.identity)
                let expected: SyncAPI.Role = current == .owner ? .owner : (current == .editor || role == .editor || kind == .member ? .editor : .viewer)
                #expect(joined == .init(groupID: group.id, name: group.name, role: expected))
                let member = try await fixture.repository.read { groups, _, _ in try await groups.member(groupID: group.id, userID: user.id) }
                #expect(member?.joinedAt == (current == .nonMember ? ServerTimestamp.string(fixture.account.clock.now()) : user.createdAt))
            }
            #expect(try await fixture.repository.read { groups, _, _ in try await groups.ownerCount(groupID: group.id) } >= 1)
        }
    }

    @Test func accountOnlyJoinIsRejectedWithoutConsumingAndOwnerCLITokensAreRedeemable() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let user = try await fixture.user("member")
            let group = try await fixture.group(owner: admin)
            let adminSession = try await fixture.account.session(admin)
            let session = try await fixture.account.session(user)
            let service = fixture.inviteService()
            let issued = try await service.createAdmin(.init(target: .account), session: adminSession.identity)
            await #expect(throws: AccountError.malformedRequest) {
                _ = try await service.join(.init(inviteToken: issued.response.inviteToken), session: session.identity)
            }
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
            _ = try await service.register(.init(inviteToken: issued.response.inviteToken, username: "ungrouped", password: AccountTestFixture.password, deviceName: "New device"))
            let token = DeviceToken.generate()
            try await InviteRepository(database: fixture.persistence.database).write { invites, _, _, _, _ in
                try await invites.insert(.init(tokenHash: token.hash, target: .group(groupID: group.id, role: .owner), createdBy: admin.id,
                                               expiresAt: ServerTimestamp.string(fixture.account.clock.now().addingTimeInterval(60)), consumedAt: nil))
            }
            let joined = try await service.join(.init(inviteToken: token.value), session: session.identity)
            #expect(joined.role == .owner)
        }
    }
}
