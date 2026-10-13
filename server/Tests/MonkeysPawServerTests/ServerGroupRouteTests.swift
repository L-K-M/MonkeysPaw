import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerGroupRouteTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin])
    func createMakesCallerOwnerAndExposesOnlyMembershipMetadata(kind: SyncAPI.AccountKind) async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user(kind: kind)
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/groups", method: .post,
                                         headers: Self.headers(session), body: .init(string: "{\"name\":\"Team\"}")) {
                    #expect($0.status == .ok)
                    guard $0.status == .ok else { return }
                    let group = try JSONDecoder().decode(SyncAPI.Group.self, from: Data($0.body.readableBytesView))
                    #expect(group.name == "Team" && group.createdBy == user.id)
                    #expect(ULID(group.id)?.rawValue == group.id)
                    #expect(ServerTimestamp.date(group.createdAt) != nil)
                    try await client.execute(uri: "/api/v1/groups/\(group.id)/members", method: .get, headers: Self.headers(session)) {
                        let members = try Self.members($0)
                        #expect(members.count == 1)
                        #expect(members.first?.userID == user.id && members.first?.role == .owner)
                    }
                    try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(session)) {
                        let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data($0.body.readableBytesView))
                        #expect(me.groups == [.init(groupID: group.id, name: "Team", role: .owner)])
                    }
                }
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func groupAndMembershipPermissionMatrix(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let target = try await fixture.user("target")
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            try await fixture.member(groupID: group.id, user: target, role: .viewer)
            let session = try await fixture.account.session(actor)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let mayInspect = kind == .admin || role != .nonMember
            let mayManage = kind == .admin || role == .owner
            let denied: SyncAPI.FailureCode = role == .nonMember ? .notFound : .forbidden
            let uri = "/api/v1/groups/\(group.id)"
            try await app.test(.router) { client in
                try await client.execute(uri: "\(uri)/members", method: .get, headers: Self.headers(session)) {
                    if mayInspect {
                        let members = try Self.members($0)
                        #expect(members.contains { $0.userID == owner.id && $0.role == .owner })
                        #expect(members.contains { $0.userID == target.id && $0.role == .viewer })
                        let text = String(buffer: $0.body)
                        #expect(!text.contains("password_hash") && !text.contains("token_hash") && !text.contains("group-fixture-hash"))
                    } else { try Self.failure($0, .notFound) }
                }
                try await client.execute(uri: uri, method: .patch, headers: Self.headers(session), body: .init(string: "{\"name\":\"Renamed\"}")) {
                    if mayManage {
                        let renamed = try JSONDecoder().decode(SyncAPI.Group.self, from: Data($0.body.readableBytesView))
                        #expect($0.status == .ok && renamed.name == "Renamed")
                        #expect(renamed.id == group.id && renamed.createdBy == owner.id && renamed.createdAt == group.createdAt)
                    } else { try Self.failure($0, denied) }
                }
                for targetRole in [SyncAPI.Role.owner, .editor, .viewer] {
                    let request = try JSONEncoder().encode(SyncAPI.MembershipRequest(role: targetRole))
                    try await client.execute(uri: "\(uri)/members/\(target.id)", method: .put,
                                             headers: Self.headers(session), body: .init(bytes: request)) {
                        if mayManage {
                            let member = try JSONDecoder().decode(SyncAPI.Member.self, from: Data($0.body.readableBytesView))
                            #expect($0.status == .ok && member.userID == target.id && member.role == targetRole)
                            #expect(member.username == target.username && member.displayName == nil && member.joinedAt == target.createdAt)
                        } else { try Self.failure($0, denied) }
                    }
                }
                try await client.execute(uri: "\(uri)/members/\(target.id)", method: .delete, headers: Self.headers(session)) {
                    if mayManage { try Self.empty($0) } else { try Self.failure($0, denied) }
                }
                // PUT also adds an existing account that has no current membership.
                try await client.execute(uri: "\(uri)/members/\(target.id)", method: .put,
                                         headers: Self.headers(session), body: .init(string: "{\"role\":\"viewer\"}")) {
                    if mayManage {
                        #expect($0.status == .ok)
                        let member = try JSONDecoder().decode(SyncAPI.Member.self, from: Data($0.body.readableBytesView))
                        #expect(member.userID == target.id && member.role == .viewer)
                    } else { try Self.failure($0, denied) }
                }
                try await client.execute(uri: uri, method: .delete, headers: Self.headers(session)) {
                    if mayManage { try Self.empty($0) } else { try Self.failure($0, denied) }
                }
                if mayManage {
                    try await client.execute(uri: "\(uri)/members", method: .get, headers: Self.headers(session)) {
                        try Self.failure($0, .notFound)
                    }
                    try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(session)) {
                        let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data($0.body.readableBytesView))
                        #expect(!me.groups.contains { $0.groupID == group.id })
                    }
                }
                #expect(try await fixture.persistence.count("audit_events") == (mayManage ? (role == .nonMember ? 9 : 10) : 0))
                try await client.execute(uri: "/api/v1/groups", method: .post, headers: Self.headers(session), body: .init(string: "{\"name\":\"New\"}")) {
                    #expect($0.status == .ok)
                    let created = try JSONDecoder().decode(SyncAPI.Group.self, from: Data($0.body.readableBytesView))
                    #expect(created.createdBy == actor.id)
                    let memberships = try await fixture.account.accounts.me(session.identity).groups
                    #expect(memberships.contains { $0.groupID == created.id && $0.role == .owner })
                    if kind == .admin && role == .nonMember {
                        #expect(!memberships.contains { $0.groupID == group.id })
                    }
                }
            }
        }
    }

    @Test func adminSelfGrantAndLastOwnerDenialsUse403() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let adminSession = try await fixture.account.session(admin)
            let ownerSession = try await fixture.account.session(owner)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for role in [SyncAPI.Role.owner, .editor, .viewer] {
                    try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(admin.id)", method: .put,
                                             headers: Self.headers(adminSession), body: .init(bytes: JSONEncoder().encode(SyncAPI.MembershipRequest(role: role)))) {
                        try Self.failure($0, .forbidden)
                    }
                }
                for actor in [adminSession, ownerSession] {
                    try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(owner.id)", method: .delete, headers: Self.headers(actor)) {
                        try Self.failure($0, .forbidden)
                    }
                    for role in ["editor", "viewer"] {
                        try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(owner.id)", method: .put,
                                                 headers: Self.headers(actor), body: .init(string: "{\"role\":\"\(role)\"}")) {
                            try Self.failure($0, .forbidden)
                        }
                    }
                }
                #expect(try await fixture.persistence.count("audit_events") == 0)
            }
        }
    }

    @Test func typedFailuresCoverAuthPathsMissingTargetsAndBodyBounds() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let admin = try await fixture.user("admin", kind: .admin)
            let target = try await fixture.user("target")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(admin)
            let revoked = try await fixture.account.session(owner)
            try await fixture.account.sessions.logout(revoked.identity)
            let disabled = try await fixture.account.session(target)
            try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: target.id)")
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let routes: [(String, HTTPRequest.Method, String?)] = [
                ("/api/v1/groups", .post, "{\"name\":\"New\"}"),
                ("/api/v1/groups/\(group.id)", .patch, "{\"name\":\"New\"}"),
                ("/api/v1/groups/\(group.id)", .delete, nil),
                ("/api/v1/groups/\(group.id)/members", .get, nil),
                ("/api/v1/groups/\(group.id)/members/\(owner.id)", .put, "{\"role\":\"viewer\"}"),
                ("/api/v1/groups/\(group.id)/members/\(owner.id)", .delete, nil)
            ]
            try await app.test(.router) { client in
                for headers: HTTPFields in [[:], [.authorization: "Bearer invalid"], Self.headers(revoked), Self.headers(disabled)] {
                    for (uri, method, body) in routes {
                        try await client.execute(uri: uri, method: method, headers: headers, body: body.map { .init(string: $0) }) {
                            try Self.failure($0, .unauthorized)
                            #expect($0.headers[.wwwAuthenticate] == "Bearer")
                        }
                    }
                }
                for id in ["invalid", group.id.lowercased(), PersistenceTestRepository.otherGroup] {
                    let failure: SyncAPI.FailureCode = id == PersistenceTestRepository.otherGroup ? .notFound : .malformedRequest
                    for (suffix, method, body): (String, HTTPRequest.Method, String?) in [
                        ("", .patch, "{\"name\":\"New\"}"), ("", .delete, nil), ("/members", .get, nil),
                        ("/members/\(owner.id)", .put, "{\"role\":\"viewer\"}"), ("/members/\(owner.id)", .delete, nil)
                    ] {
                        try await client.execute(uri: "/api/v1/groups/\(id)\(suffix)", method: method, headers: Self.headers(session), body: body.map { .init(string: $0) }) {
                            try Self.failure($0, failure)
                        }
                    }
                }
                for id in ["bad", PersistenceTestRepository.otherUser] {
                    for method in [HTTPRequest.Method.put, .delete] {
                        try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(id)", method: method, headers: Self.headers(session),
                                                 body: method == .put ? .init(string: "{\"role\":\"viewer\"}") : nil) {
                            try Self.failure($0, id == "bad" ? .malformedRequest : .notFound)
                        }
                    }
                }
                try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(target.id)", method: .delete, headers: Self.headers(session)) {
                    try Self.failure($0, .notFound)
                }
                for (uri, method) in [("/api/v1/groups", HTTPRequest.Method.post), ("/api/v1/groups/\(group.id)", .patch)] {
                    for body in ["{", "{}", "{\"name\":null}", "{\"name\":\"\"}", "{\"name\":\"x\",\"extra\":1}",
                                 "{\"name\":\"\(String(repeating: "x", count: 256))\"}"] {
                        try await client.execute(uri: uri, method: method, headers: Self.headers(session), body: .init(string: body)) {
                            try Self.failure($0, .malformedRequest)
                        }
                    }
                }
                for body in ["{}", "{\"role\":null}", "{\"role\":\"admin\"}", "{\"role\":\"viewer\",\"extra\":1}"] {
                    try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(owner.id)", method: .put,
                                             headers: Self.headers(session), body: .init(string: body)) {
                        try Self.failure($0, .malformedRequest)
                    }
                }
                for (uri, method, body) in routes where body != nil {
                    try await client.execute(uri: uri, method: method, headers: Self.headers(session),
                                             body: .init(repeating: 32, count: SyncAPI.requestEnvelopeMaxBytes + 1)) {
                        try Self.failure($0, .envelopeTooLarge)
                    }
                }
                let valid = Data("{\"name\":\"Envelope boundary\"}".utf8)
                let padding = Data(repeating: 32, count: SyncAPI.requestEnvelopeMaxBytes - valid.count)
                try await client.execute(uri: "/api/v1/groups", method: .post, headers: Self.headers(session), body: .init(bytes: valid + padding)) {
                    #expect($0.status == .ok)
                }
                #expect(try await fixture.persistence.count("audit_events") == 2)
            }
        }
    }

    @Test func auditFailureReturnsSanitized500AndRollsBackHTTPMutation() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let target = try await fixture.user("target")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let failing = GroupService(database: fixture.persistence.database, clock: fixture.account.clock.now) { audit, event in
                try await audit.insert(event)
                throw InjectedAuditError.failure
            }
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions, groups: failing)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/groups/\(group.id)/members/\(target.id)", method: .put,
                                         headers: Self.headers(session), body: .init(string: "{\"role\":\"owner\"}")) {
                    try Self.failure($0, .internalError)
                    #expect(String(buffer: $0.body) == "{\"code\":\"internal_error\"}")
                }
                #expect(try await fixture.persistence.count("audit_events") == 0)
                #expect(try await fixture.service.members(id: group.id, session: session.identity).members.map(\.userID) == [owner.id])
            }
        }
    }

    private static func headers(_ session: IssuedSession) -> HTTPFields {
        [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
    }

    private static func members(_ response: TestResponse) throws -> [SyncAPI.Member] {
        #expect(response.status == .ok)
        return try JSONDecoder().decode(SyncAPI.MembersResponse.self, from: Data(response.body.readableBytesView)).members
    }

    private static func failure(_ response: TestResponse, _ code: SyncAPI.FailureCode) throws {
        #expect(response.status.code == code.httpStatus)
        #expect(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView)) == .failure(code))
    }

    private static func empty(_ response: TestResponse) throws {
        #expect(response.status == .ok)
        #expect(try JSONDecoder().decode(SyncAPI.EmptyResponse.self, from: Data(response.body.readableBytesView)) == .init())
    }
}
