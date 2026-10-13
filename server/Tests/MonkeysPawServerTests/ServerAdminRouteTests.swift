import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAdminRouteTests {
    @Test(arguments: ["{\"disabled\":true}", "{\"account_kind\":\"member\"}",
                       "{\"disabled\":true,\"account_kind\":\"member\",\"password\":\"replacement-password\"}"])
    func lastAdminRemovalReturnsTheTypedForbiddenEnvelope(body: String) async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(kind: .admin)
            let session = try await fixture.session(actor)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/admin/users/\(actor.id)", method: .patch,
                    headers: Self.headers(session), body: .init(string: body)) { try Self.failure($0, .forbidden) }
            }
            #expect(try await fixture.sessions.authenticate(token: session.token.value) == session.identity)
            #expect(try await fixture.persistence.count("audit_events") == 0)
        }
    }

    @Test(arguments: [String(repeating: "a", count: ServerLimits.passwordMinimumLength),
                       String(repeating: "é", count: ServerLimits.passwordMaximumBytes / 2)])
    func adminPasswordPolicyAcceptsExactScalarAndUTF8Boundaries(password: String) async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let session = try await fixture.session(actor)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                let create = SyncAPI.CreateUserRequest(username: "boundary-user", password: password)
                try await client.execute(uri: "/api/v1/admin/users", method: .post, headers: Self.headers(session),
                    body: .init(bytes: JSONEncoder().encode(create))) { #expect($0.status == .ok) }
                let patch = SyncAPI.UpdateUserRequest(password: password)
                try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch, headers: Self.headers(session),
                    body: .init(bytes: JSONEncoder().encode(patch))) { #expect($0.status == .ok) }
            }
            #expect(try await fixture.accounts.verifyCredentials(username: target.username, password: password).user.id == target.id)
        }
    }

    @Test func adminCreatesMembersAndAdminsButMembersAreForbidden() async throws {
        try await withAccountFixture { fixture in
            let admin = try await fixture.user(username: "admin", kind: .admin)
            let member = try await fixture.user()
            let adminSession = try await fixture.session(admin)
            let memberSession = try await fixture.session(member)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.CreateUserRequest(username: "newmember", password: AccountTestFixture.password))
                try await client.execute(uri: "/api/v1/admin/users", method: .post, body: .init(bytes: body)) {
                    try Self.failure($0, .unauthorized)
                }
                try await client.execute(uri: "/api/v1/admin/users", method: .post,
                                         headers: Self.headers(memberSession), body: .init(bytes: body)) {
                    try Self.failure($0, .forbidden)
                }
                for (username, kind) in [("newmember", SyncAPI.AccountKind.member), ("newadmin", .admin)] {
                    let request = SyncAPI.CreateUserRequest(username: username, password: AccountTestFixture.password,
                                                            accountKind: kind == .admin ? kind : nil)
                    try await client.execute(uri: "/api/v1/admin/users", method: .post,
                                             headers: Self.headers(adminSession), body: .init(bytes: JSONEncoder().encode(request))) {
                        #expect($0.status == .ok)
                        let user = try JSONDecoder().decode(SyncAPI.User.self, from: Data($0.body.readableBytesView))
                        #expect(user.username == username)
                        #expect(user.accountKind == kind)
                        #expect(user.displayName == nil && user.disabledAt == nil)
                    }
                }
                #expect(try await fixture.persistence.count("users") == 4)
                #expect(try await fixture.persistence.count("audit_events") == 2)
            }
        }
    }

    @Test(arguments: [SyncAPI.Role.viewer, .editor, .owner])
    func groupRolesNeverGrantAccountAdministration(role: SyncAPI.Role) async throws {
        try await withAccountFixture { fixture in
            let member = try await fixture.user()
            let target = try await fixture.user(username: "admin", kind: .admin)
            let session = try await fixture.session(member)
            try await fixture.persistence.seedAccountData(member, role: role)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                for kind in [SyncAPI.AccountKind.member, .admin] {
                    let body = try JSONEncoder().encode(SyncAPI.CreateUserRequest(username: "denied", password: AccountTestFixture.password, accountKind: kind))
                    try await client.execute(uri: "/api/v1/admin/users", method: .post, headers: Self.headers(session), body: .init(bytes: body)) {
                        try Self.failure($0, .forbidden)
                    }
                }
                for request in [SyncAPI.UpdateUserRequest(disabled: true), .init(disabled: false),
                                .init(password: "replacement-password"), .init(displayName: .null), .init(accountKind: .admin)] {
                    for id in [target.id, PersistenceTestRepository.otherUser] {
                        try await client.execute(uri: "/api/v1/admin/users/\(id)", method: .patch,
                                                 headers: Self.headers(session), body: .init(bytes: JSONEncoder().encode(request))) {
                            try Self.failure($0, .forbidden)
                        }
                    }
                }
                #expect(try await fixture.persistence.count("users") == 2)
                #expect(try await fixture.persistence.count("audit_events") == 0)
                #expect(try await fixture.sessions.authenticate(token: session.token.value) == session.identity)
            }
        }
    }

    @Test func disablePreservesDataAndEnableRequiresNewLogin() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let admin = try await fixture.session(actor)
            let first = try await fixture.session(target)
            let second = try await fixture.session(target)
            try await fixture.persistence.seedAccountData(target)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                // Re-disabling after a clock advance keeps the first disabledAt and adds no audit event.
                for repeated in 0..<2 {
                    try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch,
                                             headers: Self.headers(admin), body: .init(string: "{\"disabled\":true}")) {
                        let user = try Self.user($0)
                        #expect(user.disabledAt == target.createdAt)
                    }
                    if repeated == 0 { fixture.clock.advance(60) }
                }
                for session in [first, second] {
                    try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(session)) { try Self.failure($0, .unauthorized) }
                }
                await #expect(throws: AccountError.unauthorized) {
                    _ = try await fixture.accounts.verifyCredentials(username: target.username, password: AccountTestFixture.password)
                }
                for _ in 0..<2 {
                    try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch,
                                             headers: Self.headers(admin), body: .init(string: "{\"disabled\":false}")) {
                        let user = try Self.user($0)
                        #expect(user.disabledAt == nil)
                    }
                }
                for session in [first, second] {
                    try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(session)) { try Self.failure($0, .unauthorized) }
                }
                let verified = try await fixture.accounts.verifyCredentials(username: target.username, password: AccountTestFixture.password)
                let fresh = try await fixture.sessions.issueSession(for: verified, deviceName: "Fresh login")
                try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(fresh)) {
                    #expect($0.status == .ok)
                    let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data($0.body.readableBytesView))
                    #expect(me.groups.map(\.groupID) == [PersistenceTestRepository.group])
                }
                #expect(try await fixture.persistence.count("prompts") == 1)
                #expect(try await fixture.persistence.count("prompt_revisions") == 1)
                #expect(try await fixture.persistence.count("memberships") == 1)
                #expect(try await fixture.persistence.string("SELECT content FROM prompts", column: "content") == "preserved private prompt")
                let events = try await fixture.persistence.auditEvents()
                #expect(events.map(\.action) == ["user.disable", "user.enable"])
                #expect(events.allSatisfy { $0.actorID == actor.id && $0.targetID == target.id })
                let revoked = try await fixture.accounts.repository.read { _, devices in try await devices.device(id: first.identity.deviceID)?.revokedAt }
                #expect(revoked == target.createdAt)
            }
        }
    }

    @Test func adminResetRevokesEveryTargetDeviceAndPreservesOtherUsersAndMetadata() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let admin = try await fixture.session(actor)
            let first = try await fixture.session(target)
            let second = try await fixture.session(target)
            let alreadyRevoked = try await fixture.session(target)
            try await fixture.sessions.revokeDevice(id: alreadyRevoked.identity.deviceID, session: first.identity)
            fixture.clock.advance(60)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch,
                                         headers: Self.headers(admin), body: .init(string: "{\"password\":\"replacement-password\"}")) {
                    let user = try Self.user($0)
                    #expect(user == target.metadata)
                }
                for session in [first, second, alreadyRevoked] {
                    try await client.execute(uri: "/api/v1/me", method: .get, headers: Self.headers(session)) { try Self.failure($0, .unauthorized) }
                }
                #expect(try await fixture.sessions.authenticate(token: admin.token.value) == admin.identity)
                let adminDevices = try await fixture.accounts.repository.read { _, devices in try await devices.list(userID: actor.id) }
                #expect(adminDevices.count == 1 && adminDevices.allSatisfy { $0.revokedAt == nil })
                let verified = try await fixture.accounts.verifyCredentials(username: target.username, password: "replacement-password")
                #expect(verified.user.metadata == target.metadata)
                await #expect(throws: AccountError.unauthorized) {
                    _ = try await fixture.accounts.verifyCredentials(username: target.username, password: AccountTestFixture.password)
                }
                let devices = try await fixture.accounts.repository.read { _, devices in try await devices.list(userID: target.id) }
                #expect(devices.allSatisfy { $0.revokedAt != nil })
                #expect(devices.first(where: { $0.id == alreadyRevoked.identity.deviceID })?.revokedAt == target.createdAt)
                #expect(devices.first(where: { $0.id == first.identity.deviceID })?.revokedAt == ServerTimestamp.string(fixture.clock.now()))
                #expect(try await fixture.persistence.auditEvents().map(\.action) == ["user.reset_password"])
                try await fixture.assertNoPlaintext(["replacement-password", admin.token.value, first.token.value, second.token.value])
            }
        }
    }

    @Test(arguments: ["reset", "disable", "demote"])
    func selfAdministrationCommitsThenEnforcesChangedAuthority(action: String) async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(kind: .admin)
            _ = try await fixture.user(username: "backup-admin", kind: .admin)
            let session = try await fixture.session(actor)
            let other = try await fixture.session(actor)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let body: String
            switch action {
            case "reset": body = "{\"password\":\"replacement-password\"}"
            case "disable": body = "{\"disabled\":true}"
            default: body = "{\"account_kind\":\"member\"}"
            }
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/admin/users/\(actor.id)", method: .patch, headers: Self.headers(session), body: .init(string: body)) {
                    let user = try Self.user($0)
                    #expect(user.id == actor.id)
                    if action == "demote" { #expect(user.accountKind == .member) }
                }
                for device in [session, other] {
                    try await client.execute(uri: "/api/v1/admin/users/\(actor.id)", method: .patch,
                                             headers: Self.headers(device), body: .init(string: "{\"disabled\":false}")) {
                        try Self.failure($0, action == "demote" ? .forbidden : .unauthorized)
                    }
                }
                let event = try #require(await fixture.persistence.auditEvents().first)
                #expect(event.actorID == actor.id && event.targetID == actor.id)
            }
        }
    }

    @Test func patchNullOmissionKindsValidationAndMissingTargetsUsePinnedContract() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let admin = try await fixture.session(actor)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                for (body, displayName, kind) in [("{\"display_name\":\"A name\",\"account_kind\":\"admin\"}", "A name" as String?, SyncAPI.AccountKind.admin),
                                                 ("{\"account_kind\":\"member\"}", "A name", .member),
                                                 ("{\"display_name\":null}", nil, .member),
                                                 ("{\"display_name\":\"\"}", "", .member)] {
                    try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch,
                                             headers: Self.headers(admin), body: .init(string: body)) {
                        let user = try Self.user($0)
                        #expect(user.displayName == displayName && user.accountKind == kind)
                        #expect(user.username == target.username && user.createdAt == target.createdAt && user.disabledAt == nil)
                    }
                }
                for invalid in ["{", "{}", "{\"password\":null}", "{\"disabled\":null}", "{\"account_kind\":null}",
                                "{\"account_kind\":\"owner\"}", "{\"disabled\":\"true\"}", "{\"disabled\":false,\"extra\":1}",
                                "{\"password\":\"short\"}", "{\"password\":\"twelve-chars!\\u0000suffix\"}",
                                "{\"password\":\"\(String(repeating: "a", count: ServerLimits.passwordMinimumLength - 1))\"}",
                                "{\"password\":\"\(String(repeating: "é", count: ServerLimits.passwordMaximumBytes / 2 + 1))\"}"] {
                    try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch,
                                             headers: Self.headers(admin), body: .init(string: invalid)) { try Self.failure($0, .malformedRequest) }
                }
                for (id, failure) in [("invalid", SyncAPI.FailureCode.malformedRequest), (PersistenceTestRepository.otherUser, .notFound)] {
                    try await client.execute(uri: "/api/v1/admin/users/\(id)", method: .patch,
                                             headers: Self.headers(admin), body: .init(string: "{\"disabled\":false}")) { try Self.failure($0, failure) }
                }
                for username in ["ALICE", "bad username"] {
                    let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": AccountTestFixture.password])
                    try await client.execute(uri: "/api/v1/admin/users", method: .post,
                                             headers: Self.headers(admin), body: .init(bytes: body)) { try Self.failure($0, .malformedRequest) }
                }
                // A valid but already-taken username retains §8.3's 400 contract.
                let duplicate = SyncAPI.CreateUserRequest(username: target.username, password: AccountTestFixture.password)
                try await client.execute(uri: "/api/v1/admin/users", method: .post, headers: Self.headers(admin),
                    body: .init(bytes: JSONEncoder().encode(duplicate))) { try Self.failure($0, .malformedRequest) }
                try await client.execute(uri: "/api/v1/admin/users", method: .post, headers: Self.headers(admin),
                                         body: .init(repeating: 32, count: SyncAPI.requestEnvelopeMaxBytes + 1)) { try Self.failure($0, .envelopeTooLarge) }
                #expect(try await fixture.persistence.count("users") == 2)
                #expect(try await fixture.persistence.count("audit_events") == 4)
                #expect(try await fixture.accounts.verifyCredentials(username: target.username, password: AccountTestFixture.password).user.id == target.id)
            }
        }
    }

    private static func user(_ response: TestResponse) throws -> SyncAPI.User {
        #expect(response.status == .ok)
        return try JSONDecoder().decode(SyncAPI.User.self, from: Data(response.body.readableBytesView))
    }

    private static func headers(_ session: IssuedSession) -> HTTPFields {
        [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
    }

    private static func failure(_ response: TestResponse, _ code: SyncAPI.FailureCode) throws {
        #expect(response.status.code == code.httpStatus)
        let envelope = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
        #expect(envelope == .failure(code))
    }
}
