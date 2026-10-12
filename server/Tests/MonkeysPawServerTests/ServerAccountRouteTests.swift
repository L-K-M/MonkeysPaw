import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAccountRouteTests {
    @Test func bearerFailuresUseS1EnvelopesAndHealthStaysPublic() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/health", method: .get) { #expect($0.status == .ok) }
                for header in ["", "Basic anything", "Bearer", "Bearer invalid", "Bearer  \(session.token.value)", "Bearer \(DeviceToken.generate().value)"] {
                    try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: header]) {
                        try Self.failure($0, .unauthorized)
                        #expect($0.headers[.wwwAuthenticate] == "Bearer")
                    }
                }
                try await client.execute(uri: "/api/v1/me", method: .get) { try Self.failure($0, .unauthorized) }
                var duplicate = HTTPFields()
                duplicate[values: .authorization] = ["Bearer \(session.token.value)", "Bearer \(session.token.value)"]
                try await client.execute(uri: "/api/v1/me", method: .get, headers: duplicate) { try Self.failure($0, .unauthorized) }
                try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "bEaReR \(session.token.value)"]) { #expect($0.status == .ok) }
                try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at")
                try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer \(session.token.value)"]) { try Self.failure($0, .unauthorized) }
                try await fixture.persistence.execute("UPDATE users SET disabled_at = NULL")
                try await fixture.sessions.logout(session.identity)
                try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer \(session.token.value)"]) { try Self.failure($0, .unauthorized) }
            }
        }
    }

    @Test func meContainsOnlyOwnDevicesAndCurrentMembershipsEvenForAdmins() async throws {
        try await withAccountFixture { fixture in
            let caller = try await fixture.user(kind: .admin)
            let other = try await fixture.user(username: "bob")
            let current = try await fixture.session(caller)
            let old = try await fixture.session(caller, name: "Old device")
            _ = try await fixture.session(other, name: "Other user device")
            try await fixture.sessions.revokeDevice(id: old.identity.deviceID, session: current.identity)
            for (id, owner, deleted) in [(PersistenceTestRepository.group, caller.id, false),
                                         (PersistenceTestRepository.otherGroup, other.id, false),
                                         (PersistenceTestRepository.prompt, caller.id, true)] {
                try await fixture.persistence.execute("""
                    INSERT INTO groups VALUES (\(bind: id), 'Group', \(bind: owner), \(bind: caller.createdAt), \(bind: deleted ? caller.createdAt : nil))
                    """)
                try await fixture.persistence.execute("INSERT INTO memberships VALUES (\(bind: id), \(bind: owner), 'owner', \(bind: caller.createdAt))")
            }
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer \(current.token.value)"]) { response in
                    #expect(response.status == .ok)
                    let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data(response.body.readableBytesView))
                    #expect(me.user == caller.metadata)
                    #expect(Set(me.devices.map(\.id)) == Set([current.identity.deviceID, old.identity.deviceID]))
                    #expect(me.devices.filter(\.isCurrent).map(\.id) == [current.identity.deviceID])
                    #expect(me.devices.first(where: { $0.id == old.identity.deviceID })?.revokedAt != nil)
                    #expect(me.groups.map(\.groupID) == [PersistenceTestRepository.group])
                }
            }
        }
    }

    @Test func logoutRevokesOnlyTheCallingDevice() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let current = try await fixture.session(user)
            let other = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/auth/logout", method: .post, headers: [.authorization: "Bearer \(current.token.value)"]) { try Self.empty($0) }
                try await client.execute(uri: "/api/v1/auth/logout", method: .post, headers: [.authorization: "Bearer \(current.token.value)"]) { try Self.failure($0, .unauthorized) }
                try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer \(other.token.value)"]) { #expect($0.status == .ok) }
            }
        }
    }

    @Test func revocationCannotTargetAnotherUsersDeviceAndIsIdempotentForOwnDevices() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user(kind: .admin)
            let other = try await fixture.user(username: "bob")
            let current = try await fixture.session(user)
            let own = try await fixture.session(user)
            let foreign = try await fixture.session(other)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let headers: HTTPFields = [.authorization: "Bearer \(current.token.value)"]
            try await app.test(.router) { client in
                for id in [foreign.identity.deviceID, PersistenceTestRepository.prompt] {
                    try await client.execute(uri: "/api/v1/me/devices/\(id)", method: .delete, headers: headers) { try Self.failure($0, .notFound) }
                }
                try await client.execute(uri: "/api/v1/me/devices/invalid", method: .delete, headers: headers) { try Self.failure($0, .malformedRequest) }
                for _ in 0..<2 {
                    try await client.execute(uri: "/api/v1/me/devices/\(own.identity.deviceID)", method: .delete, headers: headers) { try Self.empty($0) }
                }
                #expect(try await fixture.sessions.authenticate(token: foreign.token.value) == foreign.identity)
                await #expect(throws: AccountError.unauthorized) { _ = try await fixture.sessions.authenticate(token: own.token.value) }
                try await client.execute(uri: "/api/v1/me/devices/\(current.identity.deviceID)", method: .delete, headers: headers) { try Self.empty($0) }
                try await client.execute(uri: "/api/v1/me", method: .get, headers: headers) { try Self.failure($0, .unauthorized) }
            }
        }
    }

    @Test func passwordChangeRequiresCurrentPasswordAndKeepsOnlyCurrentDevice() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let otherUser = try await fixture.user(username: "bob")
            let current = try await fixture.session(user)
            let old = try await fixture.session(user)
            let foreign = try await fixture.session(otherUser)
            let replacement = "replacement-password"
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let headers: HTTPFields = [.authorization: "Bearer \(current.token.value)", .contentType: "application/json"]
            try await app.test(.router) { client in
                for (password, newPassword, code) in [("wrong", replacement, SyncAPI.FailureCode.unauthorized),
                                                     (AccountTestFixture.password, "short", .malformedRequest),
                                                     (AccountTestFixture.password, String(repeating: "a", count: 73), .malformedRequest)] {
                    let body = try JSONSerialization.data(withJSONObject: ["current_password": password, "new_password": newPassword])
                    try await client.execute(uri: "/api/v1/auth/password", method: .post, headers: headers, body: .init(bytes: body)) { try Self.failure($0, code) }
                }
                #expect(try await fixture.sessions.authenticate(token: old.token.value) == old.identity)
                let request = SyncAPI.PasswordChangeRequest(currentPassword: AccountTestFixture.password, newPassword: replacement)
                try await client.execute(uri: "/api/v1/auth/password", method: .post, headers: headers, body: .init(bytes: JSONEncoder().encode(request))) { try Self.empty($0) }
                #expect(try await fixture.sessions.authenticate(token: current.token.value) == current.identity)
                #expect(try await fixture.sessions.authenticate(token: foreign.token.value) == foreign.identity)
                await #expect(throws: AccountError.unauthorized) { _ = try await fixture.sessions.authenticate(token: old.token.value) }
                _ = try await fixture.accounts.verifyCredentials(username: "alice", password: replacement)
                await #expect(throws: AccountError.unauthorized) {
                    _ = try await fixture.accounts.verifyCredentials(username: "alice", password: AccountTestFixture.password)
                }
                #expect(try await fixture.accounts.me(current.identity).user == user.metadata)
                try await fixture.assertNoPlaintext([current.token.value, old.token.value, foreign.token.value,
                                                    AccountTestFixture.password, replacement])
            }
        }
    }

    @Test func malformedOverflowAndInternalErrorsNeverExposeDetails() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let current = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let headers: HTTPFields = [.authorization: "Bearer \(current.token.value)", .contentType: "application/json"]
            try await app.test(.router) { client in
                for invalid in ["{", "{}", "{\"current_password\":true,\"new_password\":\"replacement-password\"}",
                                "{\"current_password\":\"account-test-password\",\"new_password\":\"replacement-password\",\"extra\":1}"] {
                    try await client.execute(uri: "/api/v1/auth/password", method: .post, headers: headers, body: .init(string: invalid)) { try Self.failure($0, .malformedRequest) }
                }
                try await client.execute(uri: "/api/v1/auth/password", method: .post, headers: headers,
                                         body: .init(repeating: 32, count: SyncAPI.requestEnvelopeMaxBytes + 1)) { try Self.failure($0, .envelopeTooLarge) }
                try await fixture.persistence.execute("""
                    CREATE TRIGGER fail_revoke BEFORE UPDATE OF revoked_at ON devices
                    BEGIN SELECT RAISE(ABORT, 'private backend details'); END
                    """)
                try await client.execute(uri: "/api/v1/auth/logout", method: .post, headers: headers) { try Self.failure($0, .internalError) }
                #expect(try await fixture.sessions.authenticate(token: current.token.value) == current.identity)
            }
        }
    }

    @Test func failedDeviceMutationRollsBackPasswordAndStaleSessionsAreDenied() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let current = try await fixture.session(user)
            let other = try await fixture.session(user)
            try await fixture.persistence.execute("""
                CREATE TRIGGER fail_revoke BEFORE UPDATE OF revoked_at ON devices
                BEGIN SELECT RAISE(ABORT, 'private backend details'); END
                """)
            let request = SyncAPI.PasswordChangeRequest(currentPassword: AccountTestFixture.password, newPassword: "replacement-password")
            await #expect(throws: (any Error).self) { try await fixture.accounts.changePassword(request, session: current.identity) }
            _ = try await fixture.accounts.verifyCredentials(username: "alice", password: AccountTestFixture.password)
            #expect(try await fixture.sessions.authenticate(token: other.token.value) == other.identity)
            try await fixture.persistence.execute("DROP TRIGGER fail_revoke")
            try await fixture.sessions.logout(current.identity)
            await #expect(throws: AccountError.unauthorized) { _ = try await fixture.accounts.me(current.identity) }
            await #expect(throws: AccountError.unauthorized) { try await fixture.accounts.changePassword(request, session: current.identity) }
            await #expect(throws: AccountError.unauthorized) { try await fixture.sessions.revokeDevice(id: other.identity.deviceID, session: current.identity) }
        }
    }

    private static func failure(_ response: TestResponse, _ code: SyncAPI.FailureCode) throws {
        #expect(response.status.code == code.httpStatus)
        let envelope = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
        #expect(envelope == .failure(code))
    }

    private static func empty(_ response: TestResponse) throws {
        #expect(response.status == .ok)
        _ = try JSONDecoder().decode(SyncAPI.EmptyResponse.self, from: Data(response.body.readableBytesView))
    }
}
