import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerLoginRouteTests {
    private static let forwardedFor = HTTPField.Name("X-Forwarded-For")!

    @Test func loginReturnsTheS1AuthResponseAndCreatesAUsableDevice() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.live) { client in
                let response = try await client.execute(uri: "/api/v1/auth/login", method: .post,
                                                        headers: [.contentType: "application/json"],
                                                        body: Self.body(username: "ALICE", password: AccountTestFixture.password))
                #expect(response.status == .ok)
                let auth = try JSONDecoder().decode(SyncAPI.AuthResponse.self, from: Data(response.body.readableBytesView))
                #expect(auth.user == user.metadata)
                #expect(DeviceToken(value: auth.deviceToken).isValid)
                #expect(response.headers[.retryAfter] == nil)
                try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer \(auth.deviceToken)"]) {
                    #expect($0.status == .ok)
                    let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: Data($0.body.readableBytesView))
                    #expect(me.devices.count == 1 && me.devices[0].isCurrent && me.devices[0].name == "Login test")
                }
                try await fixture.assertNoPlaintext([auth.deviceToken, AccountTestFixture.password])
            }
        }
    }

    @Test func unauthorizedAndLockedResponsesUseS1EnvelopesAndRoundedRetryAfter() async throws {
        try await withLoginFixture { fixture in
            _ = try await fixture.account.user()
            let app = try Self.application(fixture)
            try await app.test(.live) { client in
                for index in 1...5 {
                    try await client.execute(uri: "/api/v1/auth/login", method: .post, body: Self.body()) {
                        try Self.failure($0, index == 5 ? .rateLimited : .unauthorized, retry: index == 5 ? 30 : nil)
                    }
                }
                fixture.account.clock.advance(29.001)
                try await client.execute(uri: "/api/v1/auth/login", method: .post,
                                         body: Self.body(password: AccountTestFixture.password)) {
                    try Self.failure($0, .rateLimited, retry: 1)
                }
                #expect(await fixture.hasher.usedHashes().count == 5)
                fixture.account.clock.advance(0.999)
                try await client.execute(uri: "/api/v1/auth/login", method: .post, body: Self.body()) {
                    try Self.failure($0, .rateLimited, retry: 60)
                }
            }
        }
    }

    @Test func untrustedXFFCannotRotateTheSocketPeersIPBucket() async throws {
        try await withLoginFixture { fixture in
            let app = try Self.application(fixture)
            try await app.test(.live) { client in
                for index in 1...5 {
                    try await client.execute(uri: "/api/v1/auth/login", method: .post,
                                             headers: [Self.forwardedFor: "198.51.100.\(index)"],
                                             body: Self.body(username: "user\(index)")) {
                        try Self.failure($0, index == 5 ? .rateLimited : .unauthorized, retry: index == 5 ? 30 : nil)
                    }
                }
                try await client.execute(uri: "/api/v1/auth/login", method: .post,
                                         headers: [Self.forwardedFor: "203.0.113.99"], body: Self.body(username: "fresh")) {
                    try Self.failure($0, .rateLimited, retry: 30)
                }
                #expect(try await fixture.account.persistence.count("login_ip_buckets") == 1)
                let ip = try await fixture.account.persistence.string("SELECT ip FROM login_ip_buckets", column: "ip")
                #expect(["127.0.0.1", "::1"].contains(ip))
                #expect(await fixture.hasher.usedHashes().count == 5)
            }
        }
    }

    @Test func trustedRepeatedChainsUseTheNearestUntrustedAddress() async throws {
        try await withLoginFixture { fixture in
            let app = try Self.application(fixture, proxies: "127.0.0.1,::1,10.0.0.0/8")
            try await app.test(.live) { client in
                for index in 1...5 {
                    var headers = HTTPFields()
                    let spoof = index == 5 ? String(repeating: "x", count: ServerLimits.forwardedForMaxBytes + 1) : "spoof\(index)"
                    headers[values: Self.forwardedFor] = [spoof + ",198.51.100.7", "10.2.3.4"]
                    try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: headers,
                                             body: Self.body(username: "user\(index)")) {
                        try Self.failure($0, index == 5 ? .rateLimited : .unauthorized, retry: index == 5 ? 30 : nil)
                    }
                }
                #expect(try await fixture.account.persistence.count("login_ip_buckets") == 1)
                #expect(try await fixture.buckets(username: "user1", ip: "198.51.100.7").ip.failures == 5)
                try await client.execute(uri: "/api/v1/auth/login", method: .post,
                                         headers: [Self.forwardedFor: "203.0.113.99,198.51.100.7,10.2.3.4"],
                                         body: Self.body(username: "fresh")) { try Self.failure($0, .rateLimited, retry: 30) }
                #expect(await fixture.hasher.usedHashes().count == 5)
            }
        }
    }

    @Test func malformedAndOverflowBodiesFailBeforeCredentialWork() async throws {
        try await withLoginFixture { fixture in
            let app = try Self.application(fixture)
            try await app.test(.router) { client in
                for body in ["{", "{}", #"{"username":"alice","password":"wrong","device_name":"Test","extra":true}"#,
                             #"{"username":"INVALID NAME","password":"wrong","device_name":"Test"}"#,
                             #"{"username":"alice","password":"","device_name":"Test"}"#,
                             #"{"username":"alice","password":"wrong","device_name":""}"#] {
                    try await client.execute(uri: "/api/v1/auth/login", method: .post, body: ByteBuffer(string: body)) {
                        try Self.failure($0, .malformedRequest)
                    }
                }
                try await client.execute(uri: "/api/v1/auth/login", method: .post,
                                         body: ByteBuffer(string: String(repeating: " ", count: SyncAPI.requestEnvelopeMaxBytes + 1))) {
                    try Self.failure($0, .envelopeTooLarge)
                }
                #expect(await fixture.hasher.usedHashes().isEmpty)
                #expect(try await fixture.account.persistence.count("login_account_buckets") == 0)
                #expect(try await fixture.account.persistence.count("login_ip_buckets") == 0)
            }
        }
    }

    @Test func exactEnvelopeLimitIsAcceptedAndTheNextByteIs413() async throws {
        try await withLoginFixture { fixture in
            let app = try Self.application(fixture)
            let prefix = "{\"username\":\"alice\",\"password\":\""
            let suffix = "\",\"device_name\":\"Test\"}"
            let password = String(repeating: "a", count: SyncAPI.requestEnvelopeMaxBytes - prefix.utf8.count - suffix.utf8.count)
            try await app.test(.live) { client in
                try await client.execute(uri: "/api/v1/auth/login", method: .post, body: ByteBuffer(string: prefix + password + suffix)) {
                    try Self.failure($0, .unauthorized)
                }
                try await client.execute(uri: "/api/v1/auth/login", method: .post, body: ByteBuffer(string: prefix + password + "a" + suffix)) {
                    try Self.failure($0, .envelopeTooLarge)
                }
                #expect(await fixture.hasher.usedHashes().count == 1)
            }
        }
    }

    @Test func persistenceFailureReturnsSanitized500AndRollsBackBothBuckets() async throws {
        try await withLoginFixture { fixture in
            try await fixture.account.persistence.execute("""
                CREATE TRIGGER fail_ip BEFORE INSERT ON login_ip_buckets
                BEGIN SELECT RAISE(ABORT, 'private SQL details and credentials'); END
                """)
            let app = try Self.application(fixture)
            try await app.test(.live) { client in
                try await client.execute(uri: "/api/v1/auth/login", method: .post, body: Self.body()) {
                    try Self.failure($0, .internalError)
                    #expect(String(decoding: $0.body.readableBytesView, as: UTF8.self) == #"{"code":"internal_error"}"#)
                }
                #expect(try await fixture.account.persistence.count("login_account_buckets") == 0)
                #expect(try await fixture.account.persistence.count("login_ip_buckets") == 0)
            }
        }
    }

    private static func application(_ fixture: LoginTestFixture, proxies: String = "") throws -> some ApplicationProtocol {
        makeApplication(configuration: try .init(environment: ["MONKEYSPAW_TRUSTED_PROXIES": proxies]),
                        accounts: .init(database: fixture.account.persistence.database, passwords: fixture.hasher, clock: fixture.account.clock.now),
                        sessions: fixture.account.sessions)
    }

    private static func body(username: String = "alice", password: String = "wrong") throws -> ByteBuffer {
        ByteBuffer(bytes: try JSONEncoder().encode(SyncAPI.LoginRequest(username: username, password: password, deviceName: "Login test")))
    }

    private static func failure(_ response: TestResponse, _ code: SyncAPI.FailureCode, retry: Int64? = nil) throws {
        #expect(response.status.code == code.httpStatus)
        #expect(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView)) == .failure(code))
        if let retry {
            #expect(try SyncAPI.RetryAfter(headerValue: #require(response.headers[.retryAfter])).seconds == retry)
        } else {
            #expect(response.headers[.retryAfter] == nil)
        }
    }
}
