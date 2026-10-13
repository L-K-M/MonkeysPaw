import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

struct CapturedServerLog: Decodable {
    let at: String
    let level: String
    let message: String
    let fields: [String: String]
}

// NSLock protects captured records while loggers run on concurrent tasks.
final class CapturedServerLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func events() throws -> [CapturedServerLog] {
        try snapshot().split(separator: 10).map { try JSONDecoder().decode(CapturedServerLog.self, from: Data($0)) }
    }
}

private struct SecretLogError: Error, CustomStringConvertible {
    var description: String { "s8-private-error-sentinel" }
}

@Suite(.serialized)
struct ServerLoggingTests {
    @Test func configuredLevelsFilterAndLoggerCopiesKeepTheirOwnMetadata() throws {
        for (value, expected) in [("TRACE", Logger.Level.trace), ("debug", .debug), (" INFO ", .info),
                                  ("notice", .notice), ("WARN", .warning), ("warning", .warning),
                                  ("error", .error), ("critical", .critical), ("unknown", .info), ("", .info)] {
            #expect(try ServerConfiguration(environment: ["MONKEYSPAW_LOG_LEVEL": value]).logLevel == expected)
        }
        #expect(try ServerConfiguration(environment: [:]).logLevel == .info)
        let capture = CapturedServerLogs()
        let clock = AccountTestClock()
        var logger = ServerLogging.makeLogger(level: .info, clock: clock.now, sink: capture.write)
        logger[metadataKey: "status"] = "400"
        var copy = logger
        copy.logLevel = .debug
        copy[metadataKey: "status"] = "403"
        logger.debug("API request failed")
        copy.debug("API request failed")
        logger.info("API request failed")
        let events = try capture.events()
        #expect(events.map(\.level) == ["debug", "info"])
        #expect(events.map { $0.fields["status"] } == ["403", "400"])
        #expect(events.allSatisfy { $0.at == ServerTimestamp.string(clock.now()) })
    }

    @Test func frameworkMessagesErrorsAndEveryMetadataSourceDropSecretsEvenAtTrace() throws {
        let capture = CapturedServerLogs()
        let sentinel = "s8-credential-sentinel"
        var logger = ServerLogging.makeLogger(level: .trace, sink: capture.write)
        logger[metadataKey: "password"] = .string(sentinel)
        logger[metadataKey: "token_hash"] = .string(sentinel)
        logger[metadataKey: "actor_id"] = .string(sentinel)
        logger.handler.metadataProvider = .init {
            ["body": .string(sentinel), "headers": .dictionary(["Authorization": .string(sentinel)]),
             "method": .string("POST"), "status": .string("401")]
        }
        for level in Logger.Level.allCases {
            logger.log(level: level, "Decode Error: \(sentinel)\nsecond line\r", metadata: [
                "request_body": .string(sentinel), "password_hash": .string(sentinel), "code": .string("unauthorized"),
                "target_id": .string(sentinel), "action": .array([.string(sentinel)]), "status": "403"
            ], source: sentinel, file: sentinel, function: sentinel)
        }
        logger.error("Server channel error", error: SecretLogError(), metadata: ["error": .string(sentinel)])
        logger.info("Server started and listening on \(sentinel):8080")
        logger.trace("Server State: \(sentinel)")
        logger.info("Account mutation committed", metadata: [
            "action": "user.disable", "actor_id": .string(PersistenceTestRepository.user),
            "target_id": .string(PersistenceTestRepository.otherUser), "status": .stringConvertible(SecretLogError())
        ])
        logger.info("API request failed", metadata: ["method": .string(sentinel), "status": "999", "code": .string(sentinel)])
        let bytes = capture.snapshot()
        let text = String(decoding: bytes, as: UTF8.self)
        let secretsAbsent = !text.contains(sentinel) && !text.contains(SecretLogError().description)
        #expect(secretsAbsent)
        #expect(bytes.last == 10 && !bytes.contains(13))
        let events = try capture.events()
        #expect(events.count == Logger.Level.allCases.count + 5)
        #expect(events.prefix(7).allSatisfy { $0.message == "Server event" && $0.fields == ["code": "unauthorized", "method": "POST", "status": "403"] })
        #expect(events[8].message == "Server started")
        #expect(events[9].message == "Server state changed")
        #expect(events[10].fields == ["action": "user.disable", "actor_id": PersistenceTestRepository.user,
                                     "target_id": PersistenceTestRepository.otherUser, "method": "POST"])
        #expect(events[11].fields.isEmpty)
        for event in events { #expect(ServerTimestamp.date(event.at) != nil) }
    }

    @Test func concurrentEventsRemainSeparateJSONLines() async throws {
        let capture = CapturedServerLogs()
        let logger = ServerLogging.makeLogger(level: .trace, sink: capture.write)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { logger.info("API request failed", metadata: ["method": "GET", "status": "404", "code": "not_found"]) }
            }
        }
        let lines = capture.snapshot().split(separator: 10)
        #expect(lines.count == 100)
        #expect(try capture.events().allSatisfy { $0.message == "API request failed" && $0.level == "info" && $0.fields["code"] == "not_found" })
    }

    @Test func liveHTTPLogsNeverContainPasswordsTokensHashesBodiesOrBackendErrors() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let admin = try await fixture.session(actor)
            let capture = CapturedServerLogs()
            let logger = ServerLogging.makeLogger(level: .trace, clock: fixture.clock.now, sink: capture.write)
            let password = "s8-created-password-sentinel"
            let newPassword = "s8-reset-password-sentinel"
            let displayName = "s8-display-name-sentinel\nsecond line"
            let username = "s8_username_sentinel"
            let service = AdminUserService(accounts: fixture.accounts, logger: logger)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts,
                                      sessions: fixture.sessions, admin: service, logger: logger)
            let issuedToken = try await app.test(.live) { client in
                let request = SyncAPI.CreateUserRequest(username: username, password: password, displayName: .value(displayName))
                let headers: HTTPFields = [.authorization: "Bearer \(admin.token.value)", .contentType: "application/json"]
                try await client.execute(uri: "/api/v1/admin/users", method: .post, headers: headers,
                                         body: .init(bytes: JSONEncoder().encode(request))) { #expect($0.status == .ok) }
                let patch = SyncAPI.UpdateUserRequest(displayName: .value(displayName), password: newPassword)
                try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch, headers: headers,
                                         body: .init(bytes: JSONEncoder().encode(patch))) { #expect($0.status == .ok) }
                try await client.execute(uri: "/api/v1/admin/users", method: .post, headers: headers,
                                         body: .init(string: "{\"password\":\"s8-malformed-body-sentinel\"}")) { #expect($0.status == .badRequest) }
                try await client.execute(uri: "/api/v1/me?secret=s8-query-sentinel", method: .get,
                                         headers: [.authorization: "Bearer s8-invalid-token-sentinel"]) { #expect($0.status == .unauthorized) }
                let login = SyncAPI.LoginRequest(username: username, password: password, deviceName: "s8-device-name-sentinel")
                let response = try await client.execute(uri: "/api/v1/auth/login", method: .post, body: .init(bytes: JSONEncoder().encode(login)))
                #expect(response.status == .ok)
                return try JSONDecoder().decode(SyncAPI.AuthResponse.self, from: Data(response.body.readableBytesView)).deviceToken
            }
            let failing = AdminUserService(accounts: fixture.accounts, logger: logger) { audit, event in
                try await audit.insert(event)
                throw SecretLogError()
            }
            let failureApp = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts,
                                             sessions: fixture.sessions, admin: failing, logger: logger)
            let successesBefore = try capture.events().filter { $0.message == "Account mutation committed" }.count
            try await failureApp.test(.router) { client in
                try await client.execute(uri: "/api/v1/admin/users/\(target.id)", method: .patch,
                                         headers: [.authorization: "Bearer \(admin.token.value)"], body: .init(string: "{\"disabled\":true}")) {
                    #expect($0.status == .internalServerError)
                    let response = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data($0.body.readableBytesView))
                    #expect(response == .failure(.internalError))
                }
            }
            let storedHashes = try await fixture.accounts.repository.read { accounts, _ in
                let created = try #require(await accounts.user(username: username))
                let reset = try #require(await accounts.user(id: target.id))
                return [created.passwordHash, reset.passwordHash]
            }
            let secrets = storedHashes + [AccountTestFixture.password, password, newPassword, displayName,
                           "s8-display-name-sentinel", username, issuedToken, DeviceToken(value: issuedToken).hash,
                           admin.token.value, admin.token.hash, actor.passwordHash, target.passwordHash,
                           "s8-malformed-body-sentinel", "s8-query-sentinel", "s8-invalid-token-sentinel",
                           "s8-device-name-sentinel", SecretLogError().description]
            let text = String(decoding: capture.snapshot(), as: UTF8.self)
            let secretsAbsent = secrets.allSatisfy { !text.contains($0) }
            #expect(secretsAbsent)
            let events = try capture.events()
            let successes = events.filter { $0.message == "Account mutation committed" }
            #expect(successes.count == successesBefore && successes.count == 3)
            #expect(successes.map { $0.fields["action"] } == ["user.create", "user.update", "user.reset_password"])
            #expect(events.contains { $0.message == "Server started" })
            #expect(events.contains { $0.message == "API request failed" && $0.level == "error" && $0.fields["code"] == "internal_error" })
        }
    }
}
