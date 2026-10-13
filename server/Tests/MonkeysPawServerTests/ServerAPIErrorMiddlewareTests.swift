import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

struct ServerAPIErrorMiddlewareTests {
    @Test func canonicalSerializationFailureKeepsTheSanitizedInternalEnvelope() async throws {
        let capture = CapturedServerLogs()
        let logger = ServerLogging.makeLogger(level: .trace, sink: capture.write)
        let router = Router(context: ServerRequestContext.self)
        router.add(middleware: APIErrorMiddleware())
        router.put("/serialization") { _, _ async throws -> Response in
            throw PromptWriteError.serializationFailed
        }
        try await Application(router: router, logger: logger).test(.router) { client in
            try await client.execute(uri: "/serialization", method: .put) {
                try PromptHTTPTest.error($0, .failure(.internalError))
                #expect(String(buffer: $0.body) == "{\"code\":\"internal_error\"}")
            }
        }
        let failures = try capture.events().filter { $0.message == "API request failed" }
        #expect(failures.count == 1)
        let failure = try #require(failures.first)
        #expect(failure.level == "error")
        #expect(failure.fields == ["code": "internal_error", "status": "500", "method": "PUT", "error_type": "PromptWriteError"])
    }

    @Test func unexpectedErrorsLogOnlyTheirTypeAndKeepTheGenericEnvelope() async throws {
        let capture = APIErrorLogCapture()
        let logger = Logger(label: "api-error-test") { _ in APIErrorLogHandler(capture: capture) }
        let router = Router(context: ServerRequestContext.self)
        router.add(middleware: APIErrorMiddleware())
        router.get("/unexpected") { _, _ async throws -> Response in
            throw SecretBearingError(details: "private request data /secret/path token SELECT password_hash FROM users")
        }
        let app = Application(router: router, logger: logger)
        try await app.test(.router) { client in
            try await client.execute(uri: "/unexpected", method: .get) { response in
                #expect(response.status == .internalServerError)
                let envelope = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
                #expect(envelope == .failure(.internalError))
            }
        }
        let errors = capture.errors()
        #expect(errors.count == 1)
        let entry = try #require(errors.first)
        #expect(entry.error == nil)
        #expect(entry.message.description == "API request failed")
        #expect(entry.metadata?["code"] == .string("internal_error"))
        #expect(entry.metadata?["error_type"] == .string(String(describing: SecretBearingError.self)))
        let logged = entry.message.description + String(describing: entry.metadata)
        for secret in ["private request data", "/secret/path", "token", "SELECT", "password_hash"] {
            #expect(!logged.contains(secret))
        }
    }

    @Test func unexpectedErrorsReachJSONSinkWithOnlyTheTypeName() async throws {
        let capture = CapturedServerLogs()
        let logger = ServerLogging.makeLogger(level: .trace, sink: capture.write)
        let router = Router(context: ServerRequestContext.self)
        router.add(middleware: APIErrorMiddleware())
        let secret = "s8-fix1-private-error /secret/path token SELECT password_hash FROM users"
        router.get("/unexpected") { _, _ async throws -> Response in
            throw SecretBearingError(details: secret)
        }
        try await Application(router: router, logger: logger).test(.router) { client in
            try await client.execute(uri: "/unexpected", method: .get) { response in
                #expect(response.status == .internalServerError)
                let envelope = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
                #expect(envelope == .failure(.internalError))
            }
        }
        let failures = try capture.events().filter { $0.message == "API request failed" }
        #expect(failures.count == 1)
        let failure = try #require(failures.first)
        #expect(failure.level == "error")
        #expect(failure.fields == ["code": "internal_error", "status": "500", "method": "GET",
                                   "error_type": "SecretBearingError"])
        let text = String(decoding: capture.snapshot(), as: UTF8.self)
        for value in [secret, "/secret/path", "token", "SELECT", "password_hash", "unknown context"] {
            #expect(!text.contains(value))
        }
    }

    @Test func expectedErrorsDoNotLogRequestDetails() async throws {
        let capture = APIErrorLogCapture()
        let logger = Logger(label: "api-error-test") { _ in APIErrorLogHandler(capture: capture) }
        let router = Router(context: ServerRequestContext.self)
        router.add(middleware: APIErrorMiddleware())
        let cases: [(String, any Error, SyncAPI.FailureCode)] = [
            ("/unauthorized", AccountError.unauthorized, .unauthorized),
            ("/not-found", AccountError.notFound, .notFound),
            ("/malformed", AccountError.malformedRequest, .malformedRequest),
            ("/decode", DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private request data")), .malformedRequest),
            ("/overflow", HTTPError(.contentTooLarge, message: "private request data"), .envelopeTooLarge),
            ("/framework-not-found", HTTPError(.notFound, message: "private request data"), .notFound)
        ]
        for (path, error, _) in cases {
            router.get(RouterPath(path)) { _, _ async throws -> Response in throw error }
        }
        let app = Application(router: router, logger: logger)
        try await app.test(.router) { client in
            for (path, _, code) in cases {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status.code == code.httpStatus)
                    let envelope = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
                    #expect(envelope == .failure(code))
                }
            }
        }
        #expect(capture.errors().isEmpty)
    }
}

private struct SecretBearingError: Error, CustomStringConvertible {
    let details: String
    var description: String { details }
}

// Log handlers run on concurrent request tasks; the capture owns its locked storage.
private final class APIErrorLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEvent] = []

    func record(_ event: LogEvent) {
        lock.withLock { entries.append(event) }
    }

    func errors() -> [LogEvent] {
        lock.withLock { entries.filter { $0.level >= .error } }
    }
}

private struct APIErrorLogHandler: LogHandler {
    let capture: APIErrorLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        capture.record(event)
    }
}
