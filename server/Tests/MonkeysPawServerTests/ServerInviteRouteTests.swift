import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerInviteRouteTests {
    @Test(arguments: [SyncAPI.InviteTarget.account, .group(groupID: PersistenceTestRepository.group, role: .editor)])
    func issueAndRegisterFromBothInviteShapes(target: SyncAPI.InviteTarget) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner", kind: .admin)
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let capture = CapturedServerLogs()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions,
                                      logger: ServerLogging.makeLogger(level: .trace, sink: capture.write))
            let uri: String
            let body: Data
            switch target {
            case .account:
                uri = "/api/v1/admin/invites"
                body = try JSONEncoder().encode(SyncAPI.AdminInviteRequest(target: target))
            case .group:
                uri = "/api/v1/groups/\(group.id)/invites"
                body = try JSONEncoder().encode(SyncAPI.GroupInviteRequest(role: .editor))
            }
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .post, headers: Self.headers(session), body: .init(bytes: body)) { response in
                    #expect(response.status == .ok)
                    guard response.status == .ok else { return }
                    let invite = try JSONDecoder().decode(SyncAPI.InviteResponse.self, from: Data(response.body.readableBytesView))
                    #expect(invite.target == target)
                    #expect(ServerTimestamp.date(invite.expiresAt) == fixture.account.clock.now().addingTimeInterval(604_800))
                    let registration = SyncAPI.RegisterRequest(inviteToken: invite.inviteToken, username: "new-member",
                                                               password: AccountTestFixture.password, deviceName: "New device")
                    try await client.execute(uri: "/api/v1/auth/register", method: .post,
                                             headers: [.contentType: "application/json"], body: .init(bytes: JSONEncoder().encode(registration))) {
                        #expect($0.status == .ok)
                        guard $0.status == .ok else { return }
                        let auth = try JSONDecoder().decode(SyncAPI.AuthResponse.self, from: Data($0.body.readableBytesView))
                        #expect(auth.user.username == "new-member")
                        #expect(auth.user.accountKind == .member)
                        #expect(auth.user.displayName == nil)
                        #expect(auth.user.disabledAt == nil)
                        try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer \(auth.deviceToken)"]) {
                            let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data($0.body.readableBytesView))
                            let groups: [SyncAPI.GroupMembership] = target == .account ? [] : [.init(groupID: group.id, name: group.name, role: .editor)]
                            #expect($0.status == .ok)
                            #expect(me.groups == groups)
                            #expect(me.devices.count == 1)
                            #expect(me.devices.first?.isCurrent == true)
                            #expect(me.devices.first?.name == "New device")
                        }
                        try await fixture.account.assertNoPlaintext([invite.inviteToken, auth.deviceToken, AccountTestFixture.password, session.token.value])
                        let log = String(decoding: capture.snapshot(), as: UTF8.self)
                        #expect(!log.contains(invite.inviteToken))
                        #expect(!log.contains(auth.deviceToken))
                        #expect(!log.contains(AccountTestFixture.password))
                        #expect(!log.contains(session.token.value))
                        #expect(!log.contains("New device"))
                        #expect(!log.contains("new-member"))
                        let events = try await fixture.persistence.auditEvents()
                        #expect(events.map(\.action) == (target == .account ? ["invite.create", "user.create", "invite.consume"] :
                                                        ["invite.create", "user.create", "membership.upsert", "invite.consume"]))
                        #expect(events.dropLast().allSatisfy { $0.actorID == owner.id })
                        #expect(events.last?.actorID == auth.user.id)
                        #expect(events.last?.targetID == auth.user.id)
                        #expect(events.allSatisfy { $0.at == ServerTimestamp.string(fixture.account.clock.now()) })
                    }
                }
            }
            #expect(try await fixture.persistence.count("invites") == 1)
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("devices") == 2)
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func invitePermissionMatrix(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let session = try await fixture.account.session(actor)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let mayInvite = kind == .admin || role == .owner
            try await app.test(.router) { client in
                for inviteRole in [SyncAPI.InviteRole.editor, .viewer] {
                    try await client.execute(uri: "/api/v1/groups/\(group.id)/invites", method: .post, headers: Self.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(SyncAPI.GroupInviteRequest(role: inviteRole, expiresIn: 60)))) {
                        if mayInvite {
                            #expect($0.status == .ok)
                            let issued = try JSONDecoder().decode(SyncAPI.InviteResponse.self, from: Data($0.body.readableBytesView))
                            #expect(issued.target == .group(groupID: group.id, role: inviteRole))
                            #expect(ServerTimestamp.date(issued.expiresAt) == fixture.account.clock.now().addingTimeInterval(60))
                        } else { try Self.failure($0, role == .nonMember ? .notFound : .forbidden) }
                    }
                }
                for target in [SyncAPI.InviteTarget.account, .group(groupID: group.id, role: .viewer)] {
                    try await client.execute(uri: "/api/v1/admin/invites", method: .post, headers: Self.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(SyncAPI.AdminInviteRequest(target: target)))) {
                        if kind == .admin {
                            #expect($0.status == .ok)
                            let issued = try JSONDecoder().decode(SyncAPI.InviteResponse.self, from: Data($0.body.readableBytesView))
                            #expect(issued.target == target)
                        } else { try Self.failure($0, .forbidden) }
                    }
                }
            }
            let count = kind == .admin ? 4 : (mayInvite ? 2 : 0)
            #expect(try await fixture.persistence.count("invites") == count)
            #expect(try await fixture.persistence.count("audit_events") == count)
        }
    }

    @Test func HTTPRejectsOwnerInvitesAndInvalidUnionShapes() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let adminSession = try await fixture.account.session(admin)
            let ownerSession = try await fixture.account.session(owner)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for session in [adminSession, ownerSession] {
                    for body in ["{\"role\":\"owner\"}", "{\"role\":\"viewer\",\"group_id\":\"\(group.id)\"}",
                                 "{}", "{\"role\":null}", "{\"role\":\"viewer\",\"expires_in\":null}",
                                 "{\"role\":\"viewer\",\"expires_in\":0}", "{\"role\":\"viewer\",\"expires_in\":-1}",
                                 "{\"role\":\"editor\",\"expires_in\":604801}"] {
                        try await client.execute(uri: "/api/v1/groups/\(group.id)/invites", method: .post,
                                                 headers: Self.headers(session), body: .init(string: body)) { try Self.failure($0, .malformedRequest) }
                    }
                }
                for body in ["{\"role\":\"owner\"}", "{\"role\":\"viewer\"}", "{\"group_id\":\"\(group.id)\"}",
                             "{\"group_id\":\"\(group.id)\",\"role\":\"owner\"}", "{\"group_id\":null,\"role\":null}",
                             "{\"expires_in\":null}", "{\"expires_in\":0}", "{\"expires_in\":-1}", "{\"expires_in\":604801}", "{\"extra\":1}"] {
                    try await client.execute(uri: "/api/v1/admin/invites", method: .post, headers: Self.headers(adminSession),
                                             body: .init(string: body)) { try Self.failure($0, .malformedRequest) }
                }
                for id in ["invalid", group.id.lowercased(), PersistenceTestRepository.otherGroup] {
                    try await client.execute(uri: "/api/v1/groups/\(id)/invites", method: .post, headers: Self.headers(adminSession),
                                             body: .init(string: "{\"role\":\"viewer\"}")) {
                        try Self.failure($0, id == PersistenceTestRepository.otherGroup ? .notFound : .malformedRequest)
                    }
                }
            }
            #expect(try await fixture.persistence.count("invites") == 0)
            #expect(try await fixture.persistence.count("audit_events") == 0)
        }
    }

    @Test func authenticatedExistingAccountJoinConsumesOnce() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let joining = try await fixture.user("joining")
            let group = try await fixture.group(owner: owner)
            let issuer = try await fixture.account.session(owner)
            let session = try await fixture.account.session(joining)
            let issued = try await fixture.inviteService().createGroup(id: group.id, request: .init(role: .viewer), session: issuer.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let body = try JSONEncoder().encode(SyncAPI.JoinGroupRequest(inviteToken: issued.response.inviteToken))
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/groups/join", method: .post, headers: Self.headers(session), body: .init(bytes: body)) {
                    #expect($0.status == .ok)
                    let joined = try JSONDecoder().decode(SyncAPI.GroupMembership.self, from: Data($0.body.readableBytesView))
                    #expect(joined == .init(groupID: group.id, name: group.name, role: .viewer))
                }
                try await client.execute(uri: "/api/v1/groups/join", method: .post, headers: Self.headers(session), body: .init(bytes: body)) {
                    try Self.failure($0, .malformedRequest)
                }
                try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(session)) {
                    let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data($0.body.readableBytesView))
                    #expect(me.groups == [.init(groupID: group.id, name: group.name, role: .viewer)])
                }
            }
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["invite.create", "membership.upsert", "invite.consume"])
            #expect(events.map(\.actorID) == [owner.id, owner.id, joining.id])
            #expect(events.map(\.targetID) == [group.id, joining.id, joining.id])
            #expect(events.allSatisfy { $0.groupID == group.id })
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("devices") == 2)
        }
    }

    private static func headers(_ session: IssuedSession) -> HTTPFields {
        [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
    }

    private static func failure(_ response: TestResponse, _ code: SyncAPI.FailureCode) throws {
        #expect(response.status.code == code.httpStatus)
        #expect(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView)) == .failure(code))
    }
}
