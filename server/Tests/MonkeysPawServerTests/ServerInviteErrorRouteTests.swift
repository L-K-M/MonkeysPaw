import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerInviteErrorRouteTests {
    @Test func protectedRoutesRequireActiveDevicesAndEnabledUsers() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let disabled = try await fixture.user("disabled", kind: .admin)
            let group = try await fixture.group(owner: admin)
            let revokedSession = try await fixture.account.session(admin)
            let disabledSession = try await fixture.account.session(disabled)
            try await fixture.account.sessions.logout(revokedSession.identity)
            try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: disabled.id)")
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for headers: HTTPFields in [[:], [.authorization: "Bearer invalid"], Self.headers(revokedSession), Self.headers(disabledSession)] {
                    for (uri, body) in [("/api/v1/admin/invites", "{}"), ("/api/v1/groups/\(group.id)/invites", "{\"role\":\"viewer\"}"),
                                        ("/api/v1/groups/join", "{\"invite_token\":\"\(String(repeating: "A", count: 43))\"}")] {
                        try await client.execute(uri: uri, method: .post, headers: headers, body: .init(string: body)) {
                            try Self.failure($0, .unauthorized)
                            #expect($0.headers[.wwwAuthenticate] == "Bearer")
                        }
                    }
                }
            }
            #expect(try await fixture.persistence.count("invites") == 0)
            #expect(try await fixture.persistence.count("audit_events") == 0)
        }
    }

    @Test func registrationIsPublicButInviteOnlyAndStrictlyDecoded() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let session = try await fixture.account.session(admin)
            let hasher = InviteTestHasher()
            let service = fixture.inviteService(passwords: hasher)
            let issued = try await service.createAdmin(.init(target: .account), session: session.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions, invites: service)
            let valid: [String: Any] = ["invite_token": issued.response.inviteToken, "username": "new-member",
                                      "password": AccountTestFixture.password, "device_name": "New device"]
            var bodies = [Data("{".utf8), Data("{}".utf8)]
            for key in valid.keys {
                var missing = valid
                missing.removeValue(forKey: key)
                bodies.append(try JSONSerialization.data(withJSONObject: missing))
            }
            for (key, value): (String, Any) in [("invite_token", NSNull()), ("invite_token", "bad"),
                                               ("username", "Uppercase"), ("username", "../bad"),
                                               ("password", "short"), ("password", String(repeating: "x", count: 73)),
                                               ("password", String(repeating: "\u{00e9}", count: 37)), ("password", "password-with-\0-nul"),
                                               ("device_name", ""), ("extra", 1), ("account_kind", "admin")] {
                var invalid = valid
                invalid[key] = value
                bodies.append(try JSONSerialization.data(withJSONObject: invalid))
            }
            let malformedBodies = bodies
            var unknown = valid
            unknown["invite_token"] = DeviceToken.generate().value
            let unknownBody = try JSONSerialization.data(withJSONObject: unknown)
            try await app.test(.router) { client in
                for body in malformedBodies {
                    try await client.execute(uri: "/api/v1/auth/register", method: .post, body: .init(bytes: body)) {
                        try Self.failure($0, .malformedRequest)
                    }
                }
                try await client.execute(uri: "/api/v1/auth/register", method: .post,
                                         body: .init(bytes: unknownBody)) {
                    try Self.failure($0, .malformedRequest)
                }
                for body in ["{}", "{\"invite_token\":null}", "{\"invite_token\":\"bad\"}",
                             "{\"invite_token\":\"\(issued.response.inviteToken)\",\"role\":\"viewer\"}"] {
                    try await client.execute(uri: "/api/v1/groups/join", method: .post, headers: Self.headers(session), body: .init(string: body)) {
                        try Self.failure($0, .malformedRequest)
                    }
                }
                #expect(await hasher.hashes() == 0)
                let collision = SyncAPI.RegisterRequest(inviteToken: issued.response.inviteToken, username: "admin",
                                                       password: AccountTestFixture.password, deviceName: "Collision device")
                try await client.execute(uri: "/api/v1/auth/register", method: .post, body: .init(bytes: JSONEncoder().encode(collision))) {
                    try Self.failure($0, .malformedRequest)
                }
                #expect(await hasher.hashes() == 1)
                let expiring = try await service.createAdmin(.init(target: .account, expiresIn: 1), session: session.identity)
                fixture.account.clock.advance(1)
                let expired = SyncAPI.RegisterRequest(inviteToken: expiring.response.inviteToken, username: "expired",
                                                      password: AccountTestFixture.password, deviceName: "Expired device")
                try await client.execute(uri: "/api/v1/auth/register", method: .post, body: .init(bytes: JSONEncoder().encode(expired))) {
                    try Self.failure($0, .malformedRequest)
                }
                #expect(await hasher.hashes() == 1)
            }
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
            #expect(try await fixture.persistence.count("users") == 1)
            #expect(try await fixture.persistence.count("devices") == 1)
            #expect(try await fixture.persistence.count("audit_events") == 2)
        }
    }

    @Test func everyInviteBodyUsesTheExactEnvelopeLimit() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let group = try await fixture.group(owner: admin)
            let session = try await fixture.account.session(admin)
            let service = fixture.inviteService()
            let accountInvite = try await service.createAdmin(.init(target: .account), session: session.identity)
            let groupInvite = try await service.createGroup(id: group.id, request: .init(role: .viewer), session: session.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions, invites: service)
            let registration = SyncAPI.RegisterRequest(inviteToken: accountInvite.response.inviteToken, username: "boundary",
                                                       password: AccountTestFixture.password, deviceName: "Boundary device")
            let routes: [(String, Data)] = [
                ("/api/v1/admin/invites", Data("{}".utf8)),
                ("/api/v1/groups/\(group.id)/invites", Data("{\"role\":\"editor\"}".utf8)),
                ("/api/v1/groups/join", try JSONEncoder().encode(SyncAPI.JoinGroupRequest(inviteToken: groupInvite.response.inviteToken))),
                ("/api/v1/auth/register", try JSONEncoder().encode(registration))
            ]
            try await app.test(.router) { client in
                for (uri, valid) in routes {
                    let padded = valid + Data(repeating: 32, count: SyncAPI.requestEnvelopeMaxBytes - valid.count)
                    try await client.execute(uri: uri, method: .post, headers: Self.headers(session), body: .init(bytes: padded)) {
                        #expect($0.status == .ok)
                    }
                    try await client.execute(uri: uri, method: .post, headers: Self.headers(session), body: .init(bytes: padded + Data([32]))) {
                        try Self.failure($0, .envelopeTooLarge)
                    }
                }
            }
        }
    }

    @Test func allFourRoutesSanitizeAuditFailureAndRollBack() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let member = try await fixture.user("member")
            let group = try await fixture.group(owner: admin)
            let issuer = try await fixture.account.session(admin)
            let session = try await fixture.account.session(member)
            let service = fixture.inviteService()
            let accountInvite = try await service.createAdmin(.init(target: .account), session: issuer.identity)
            let groupInvite = try await service.createGroup(id: group.id, request: .init(role: .viewer), session: issuer.identity)
            let failing = fixture.inviteService { audit, event in
                try await audit.insert(event)
                if event.action != .userCreate { throw InjectedAuditError.failure }
            }
            let capture = CapturedServerLogs()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions,
                                      invites: failing, logger: ServerLogging.makeLogger(level: .trace, sink: capture.write))
            let registration = SyncAPI.RegisterRequest(inviteToken: accountInvite.response.inviteToken, username: "rollback-user",
                                                       password: AccountTestFixture.password, deviceName: "Rollback device")
            let routes: [(String, Data, IssuedSession)] = [
                ("/api/v1/admin/invites", Data("{}".utf8), issuer),
                ("/api/v1/groups/\(group.id)/invites", Data("{\"role\":\"viewer\"}".utf8), issuer),
                ("/api/v1/groups/join", try JSONEncoder().encode(SyncAPI.JoinGroupRequest(inviteToken: groupInvite.response.inviteToken)), session),
                ("/api/v1/auth/register", try JSONEncoder().encode(registration), issuer)
            ]
            try await app.test(.router) { client in
                for (uri, body, actor) in routes {
                    try await client.execute(uri: uri, method: .post, headers: Self.headers(actor), body: .init(bytes: body)) {
                        try Self.failure($0, .internalError)
                        #expect(String(buffer: $0.body) == "{\"code\":\"internal_error\"}")
                    }
                }
            }
            #expect(try await fixture.persistence.storedInvite(accountInvite.response.inviteToken).consumedAt == nil)
            #expect(try await fixture.persistence.storedInvite(groupInvite.response.inviteToken).consumedAt == nil)
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("devices") == 2)
            #expect(try await fixture.persistence.count("memberships") == 1)
            #expect(try await fixture.persistence.count("invites") == 2)
            #expect(try await fixture.persistence.count("audit_events") == 2)
            let log = String(decoding: capture.snapshot(), as: UTF8.self)
            let secrets = [accountInvite.response.inviteToken, groupInvite.response.inviteToken, issuer.token.value, session.token.value,
                           AccountTestFixture.password, "Rollback device", "rollback-user", "invite-fixture-hash"]
            #expect(secrets.allSatisfy { !log.contains($0) })
            let failures = try capture.events().filter { $0.message == "API request failed" }
            #expect(failures.count == 4 && failures.allSatisfy { $0.level == "error" && $0.fields["code"] == "internal_error" })
        }
    }

    @Test func adminSelfGrantAndDeletedGroupDenialsLeaveTokensUsable() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let admin = try await fixture.user("admin", kind: .admin)
            let group = try await fixture.group(owner: owner)
            let issuer = try await fixture.account.session(owner)
            let session = try await fixture.account.session(admin)
            let hasher = InviteTestHasher()
            let service = fixture.inviteService(passwords: hasher)
            let issued = try await service.createGroup(id: group.id, request: .init(role: .editor), session: issuer.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions, invites: service)
            let body = try JSONEncoder().encode(SyncAPI.JoinGroupRequest(inviteToken: issued.response.inviteToken))
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/groups/join", method: .post, headers: Self.headers(session), body: .init(bytes: body)) {
                    try Self.failure($0, .forbidden)
                }
                #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
                try await fixture.service.delete(id: group.id, session: issuer.identity)
                try await client.execute(uri: "/api/v1/groups/join", method: .post, headers: Self.headers(session), body: .init(bytes: body)) {
                    try Self.failure($0, .notFound)
                }
                try await client.execute(uri: "/api/v1/groups/\(group.id)/invites", method: .post, headers: Self.headers(session),
                                         body: .init(string: "{\"role\":\"viewer\"}")) { try Self.failure($0, .notFound) }
                try await client.execute(uri: "/api/v1/admin/invites", method: .post, headers: Self.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(SyncAPI.AdminInviteRequest(target: .group(groupID: group.id, role: .viewer))))) {
                    try Self.failure($0, .notFound)
                }
                let request = SyncAPI.RegisterRequest(inviteToken: issued.response.inviteToken, username: "deleted-group",
                                                      password: AccountTestFixture.password, deviceName: "New device")
                try await client.execute(uri: "/api/v1/auth/register", method: .post, body: .init(bytes: JSONEncoder().encode(request))) {
                    try Self.failure($0, .notFound)
                }
            }
            #expect(await hasher.hashes() == 0)
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
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
