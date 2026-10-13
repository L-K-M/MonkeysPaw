import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncHTTPClientTests: XCTestCase {
    private let id = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    private let otherID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    private let timestamp = "2026-10-12T20:10:56.557Z"
    private let databaseID = "11111111-1111-1111-1111-111111111111"
    private let token = String(repeating: "a", count: 42) + "A"

    private var user: SyncAPI.User {
        .init(id: id.rawValue, username: "alice", displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil)
    }
    private var device: SyncAPI.Device {
        .init(id: otherID.rawValue, name: "Laptop", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)
    }
    private var me: SyncAPI.MeResponse { .init(user: user, groups: [], devices: [device]) }
    private var group: SyncAPI.Group { .init(id: otherID.rawValue, name: "Team", createdBy: id.rawValue, createdAt: timestamp) }
    private var member: SyncAPI.Member {
        .init(userID: id.rawValue, username: "alice", displayName: nil, role: .viewer, joinedAt: timestamp)
    }
    private var membership: SyncAPI.GroupMembership { .init(groupID: otherID.rawValue, name: "Team", role: .viewer) }
    private var write: SyncAPI.WriteResponse {
        .init(rev: 2, seq: 3, warnings: [.init(code: "metadata.group_private_removed", severity: .warning)])
    }
    private var pull: SyncAPI.PullResponse {
        .init(databaseID: databaseID, scopes: [.init(identity: .user(userID: id.rawValue), mode: .snapshot,
            head: 0, cursor: "opaque:next/+==", hasMore: false, items: [])], removed: [])
    }

    func testLoginAndRegistrationUseWireCodecsWithoutBearerAndReturnBoundCredentials() async throws {
        let response = SyncAPI.AuthResponse(deviceToken: token, user: user)
        let transport = SyncClientFakeTransport(response: try http(response))
        let client = try client(transport)
        let signedIn = try await client.login(.init(username: "alice", password: "password", deviceName: "Laptop"))
        XCTAssertEqual(signedIn.user, user)
        XCTAssertEqual(signedIn.credential, .init(server: client.server, token: SecretValue(token)))
        try assertRequest(transport.requests[0], client: client, method: .post, path: "/auth/login",
            body: #"{"device_name":"Laptop","password":"password","username":"alice"}"#, authentication: .none)
        let registered = try await client.register(.init(inviteToken: token, username: "alice", password: "password1234", deviceName: "Laptop"))
        XCTAssertEqual(registered, signedIn)
        try assertRequest(transport.requests[1], client: client, method: .post, path: "/auth/register",
            body: "{\"device_name\":\"Laptop\",\"invite_token\":\"\(token)\",\"password\":\"password1234\",\"username\":\"alice\"}", authentication: .none)
    }

    func testEveryAuthenticatedEndpointHasExactMethodPathQueryHeadersAndBodyBytes() async throws {
        try await check(response: SyncAPI.EmptyResponse(), method: .post, path: "/auth/logout") {
            try await $0.logout(); return SyncAPI.EmptyResponse()
        }
        try await check(response: me, method: .get, path: "/me") { try await $0.me() }
        try await check(response: me, method: .get, path: "/me") {
            let devices = try await $0.devices()
            XCTAssertEqual(devices, self.me.devices)
            return self.me
        }
        try await check(response: SyncAPI.EmptyResponse(), method: .delete, path: "/me/devices/\(otherID.rawValue)") {
            try await $0.revokeDevice(id: self.otherID); return SyncAPI.EmptyResponse()
        }
        let prompt = SyncAPI.Prompt(id: id.rawValue, rev: 2, scope: .user, path: "folder/name.md", content: "body\n")
        try await check(response: prompt, method: .get, path: "/prompts/\(id.rawValue)") { try await $0.prompt(id: self.id) }
        try await check(response: write, method: .put, path: "/prompts/\(id.rawValue)",
            body: "{\"base_rev\":0,\"content\":\"body\\n\",\"path\":\"folder/name.md\",\"scope\":\"user\"}") {
            try await $0.putPrompt(id: self.id, request: .init(baseRev: 0, scope: .user, path: "folder/name.md", content: "body\n"))
        }
        try await check(response: write, method: .put, path: "/prompts/\(id.rawValue)",
            body: "{\"base_rev\":1,\"content\":\"café \\\"quoted\\\"\\r\\n\",\"group_id\":\"\(otherID.rawValue)\",\"origin\":\"llm\",\"path\":\"name.md\",\"scope\":\"group\"}") {
            try await $0.putPrompt(id: self.id, request: .init(baseRev: 1, scope: .group(groupID: self.otherID.rawValue),
                path: "name.md", content: "café \"quoted\"\r\n", origin: .llm))
        }
        try await check(response: write, method: .delete, path: "/prompts/\(id.rawValue)", query: "base_rev=9223372036854775807") {
            try await $0.deletePrompt(id: self.id, baseRev: Int64.max)
        }
        try await check(response: write, method: .post, path: "/prompts/\(id.rawValue)/move",
            body: "{\"base_rev\":2,\"group_id\":\"\(otherID.rawValue)\",\"path\":\"new.md\",\"scope\":\"group\"}") {
            try await $0.movePrompt(id: self.id, request: .init(baseRev: 2, scope: .group(groupID: self.otherID.rawValue), path: "new.md"))
        }
        try await check(response: pull, method: .post, path: "/sync/pull",
            body: "{\"cursors\":{\"user:\(id.rawValue)\":\"snap:opaque/+==%&\"},\"database_id\":\"\(databaseID)\"}") {
            try await $0.pull(.init(databaseID: self.databaseID, cursors: ["user:\(self.id.rawValue)": "snap:opaque/+==%&"]))
        }
        try await check(response: pull, method: .post, path: "/sync/pull", body: #"{"cursors":{},"database_id":null}"#) {
            try await $0.pull(.init(databaseID: nil, cursors: [:]))
        }
        try await check(response: group, method: .post, path: "/groups", body: #"{"name":"Team"}"#) {
            try await $0.createGroup(.init(name: "Team"))
        }
        try await check(response: group, method: .patch, path: "/groups/\(otherID.rawValue)", body: #"{"name":"New name"}"#) {
            try await $0.renameGroup(id: self.otherID, request: .init(name: "New name"))
        }
        try await check(response: SyncAPI.EmptyResponse(), method: .delete, path: "/groups/\(otherID.rawValue)") {
            try await $0.deleteGroup(id: self.otherID); return SyncAPI.EmptyResponse()
        }
        try await check(response: SyncAPI.MembersResponse(members: [member]), method: .get, path: "/groups/\(otherID.rawValue)/members") {
            try await $0.members(groupID: self.otherID)
        }
        try await check(response: member, method: .put, path: "/groups/\(otherID.rawValue)/members/\(id.rawValue)", body: #"{"role":"viewer"}"#) {
            try await $0.upsertMember(groupID: self.otherID, userID: self.id, request: .init(role: .viewer))
        }
        try await check(response: SyncAPI.EmptyResponse(), method: .delete, path: "/groups/\(otherID.rawValue)/members/\(id.rawValue)") {
            try await $0.removeMember(groupID: self.otherID, userID: self.id); return SyncAPI.EmptyResponse()
        }
        let invite = SyncAPI.InviteResponse(inviteToken: token, expiresAt: timestamp, target: .group(groupID: otherID.rawValue, role: .viewer))
        for (request, body) in [(SyncAPI.GroupInviteRequest(role: .viewer), #"{"role":"viewer"}"#),
                               (.init(role: .viewer, expiresIn: 60), #"{"expires_in":60,"role":"viewer"}"#)] {
            try await check(response: invite, method: .post, path: "/groups/\(otherID.rawValue)/invites", body: body) {
                let issued = try await $0.createInvite(groupID: self.otherID, request: request)
                XCTAssertEqual(issued.token, SecretValue(self.token))
                XCTAssertEqual(issued.expiresAt, self.timestamp)
                XCTAssertEqual(issued.target, invite.target)
                return invite
            }
        }
        try await check(response: membership, method: .post, path: "/groups/join", body: "{\"invite_token\":\"\(token)\"}") {
            try await $0.joinGroup(.init(inviteToken: self.token))
        }
    }

    func testBearerCannotCrossHostSchemePortOrDeploymentPrefix() async throws {
        let transport = SyncClientFakeTransport(response: try http(me))
        let server = try SyncServerURL("https://example.com/paw")
        let credential = SyncCredential(server: server, token: SecretValue(token))
        for input in ["https://other.example/paw", "https://example.com:8443/paw", "https://example.com/other",
                      "https://example.com", "http://localhost/paw"] {
            let client = SyncHTTPClient(server: try SyncServerURL(input), transport: transport, credential: credential)
            await assertError(.credentialServerMismatch) { _ = try await client.me() }
        }
        XCTAssertTrue(transport.requests.isEmpty)
        let alias = try SyncServerURL("HTTPS://EXAMPLE.COM:443/paw/api/v1/")
        _ = try await SyncHTTPClient(server: alias, transport: transport, credential: credential).me()
        let otherServer = try SyncServerURL("https://other.example/paw")
        let otherToken = String(repeating: "b", count: 42) + "A"
        _ = try await SyncHTTPClient(server: otherServer, transport: transport,
            credential: .init(server: otherServer, token: SecretValue(otherToken))).me()
        XCTAssertEqual(transport.requests.map(\.url.host), ["example.com", "other.example"])
        XCTAssertEqual(transport.requests.map { $0.headers["Authorization"] }, ["Bearer " + token, "Bearer " + otherToken])
        XCTAssertTrue(transport.requests.allSatisfy { !$0.url.absoluteString.contains(self.token) })
    }

    func testAllErrorEnvelopesRetainOnlyTypedContractData() async throws {
        for (envelope, expected) in try errorCases() {
            let transport = SyncClientFakeTransport(response: try http(envelope, status: envelope.httpStatus, headers: ["rEtRy-AfTeR": "30"]))
            let client = try client(transport)
            await assertError(expected) { _ = try await client.me() }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testEveryEnvelopeRejectsWrongHTTPStatusIncludingSuccess() async throws {
        for (envelope, _) in try errorCases() {
            for status in [200, envelope.httpStatus + 1] {
                let transport = SyncClientFakeTransport(response: try http(envelope, status: status, headers: ["Retry-After": "30"]))
                let client = try client(transport)
                await assertError(.statusEnvelopeMismatch(statusCode: status)) { _ = try await client.me() }
            }
        }
        for status in [201, 401, 500] {
            let transport = SyncClientFakeTransport(response: try http(me, status: status))
            let client = try client(transport)
            await assertError(.statusEnvelopeMismatch(statusCode: status)) { _ = try await client.me() }
        }
    }

    func testRetryAfterRequiresOneCanonicalIntegerInContractRange() async throws {
        for value in ["1", "900"] {
            let transport = SyncClientFakeTransport(response: try http(SyncAPI.ErrorResponse.failure(.rateLimited), status: 429,
                                                                      headers: ["Retry-After": value]))
            let client = try client(transport)
            await assertError(.rateLimited(retryAfter: try .init(headerValue: value))) { _ = try await client.me() }
        }
        for headers in [[:], ["Retry-After": "0"], ["Retry-After": "901"], ["Retry-After": "01"],
                        ["Retry-After": " 30"], ["Retry-After": "-1"], ["Retry-After": "1.5"],
                        ["Retry-After": "Tue, 13 Oct 2026 00:00:00 GMT"], ["Retry-After": "1", "retry-after": "2"]] {
            let transport = SyncClientFakeTransport(response: try http(SyncAPI.ErrorResponse.failure(.rateLimited), status: 429, headers: headers))
            let client = try client(transport)
            await assertError(.malformedResponse) { _ = try await client.me() }
        }
    }

    func testMalformedBodiesUnknownEnvelopesAndNonJSONGatewayErrorsAreSanitized() async throws {
        for status in [200, 400, 401, 403, 404, 409, 410, 413, 422, 429] {
            for body in ["", "not json", "[]", "{\"code\":\"unknown\"}", "{\"code\":\"unauthorized\",\"detail\":\"secret\"}"] {
                let transport = SyncClientFakeTransport(response: .init(statusCode: status, body: Data(body.utf8)))
                let client = try client(transport)
                await assertError(.malformedResponse) { _ = try await client.me() }
            }
        }
        for status in [500, 502, 503, 599] {
            let transport = SyncClientFakeTransport(response: .init(statusCode: status, body: Data("upstream secret error".utf8)))
            let client = try client(transport)
            await assertError(.serverFailure(statusCode: status)) { _ = try await client.me() }
        }
        let malformedMe = SyncClientFakeTransport(response: .init(statusCode: 200, body: Data(#"{"user":{},"groups":[],"devices":[]}"#.utf8)))
        await assertError(.malformedResponse) { _ = try await self.client(malformedMe).me() }
    }

    func testResponseCapsApplyToSuccessErrorsAndPullEvenWithNonconformingTransport() async throws {
        for status in [200, 401, 500] {
            let transport = SyncClientFakeTransport(response: .init(statusCode: status, body: Data(repeating: 32, count: Limits.responseCap + 1)))
            let client = try client(transport)
            await assertError(.transport(.responseTooLarge)) { _ = try await client.me() }
        }
        var normalBody = try http(me).body
        normalBody.append(Data(repeating: 32, count: Limits.responseCap - normalBody.count))
        let normal = SyncClientFakeTransport(response: .init(statusCode: 200, body: normalBody))
        let meResult = try await client(normal).me()
        XCTAssertEqual(meResult, me)

        var pullBody = try http(pull).body
        pullBody.append(Data(repeating: 32, count: SyncAPI.responseEnvelopeMaxBytes - pullBody.count))
        let exact = SyncClientFakeTransport(response: .init(statusCode: 200, body: pullBody))
        let result = try await client(exact).pull(.init(databaseID: nil, cursors: [:]))
        XCTAssertEqual(result, pull)
        pullBody.append(32)
        let oversized = SyncClientFakeTransport(response: .init(statusCode: 200, body: pullBody))
        await assertError(.transport(.responseTooLarge)) { _ = try await self.client(oversized).pull(.init(databaseID: nil, cursors: [:])) }
        XCTAssertEqual(exact.requests[0].responseByteCap, 16 * 1_024 * 1_024)
    }

    func testInvalidAndOversizeRequestsNeverReachTransport() async throws {
        let transport = SyncClientFakeTransport(response: try http(me))
        let client = try client(transport)
        await assertError(.invalidRequest) { _ = try await client.login(.init(username: "Alice", password: "password", deviceName: "Laptop")) }
        await assertError(.invalidRequest) { _ = try await client.deletePrompt(id: self.id, baseRev: 0) }
        await assertError(.invalidRequest) { _ = try await client.movePrompt(id: self.id, request: .init(baseRev: 0, scope: .user, path: "name.md")) }
        await assertError(.invalidRequest) { _ = try await client.joinGroup(.init(inviteToken: "bad")) }
        await assertError(.transport(.requestTooLarge)) {
            _ = try await client.pull(.init(databaseID: nil, cursors: ["user:\(self.id.rawValue)": String(repeating: "x", count: SyncAPI.requestEnvelopeMaxBytes)]))
        }
        let anonymous = SyncHTTPClient(server: client.server, transport: transport)
        await assertError(.unauthorized) { _ = try await anonymous.me() }
        let invalidBearer = SyncHTTPClient(server: client.server, transport: transport, credential: .init(server: client.server, token: SecretValue("bad\r\nheader")))
        await assertError(.invalidRequest) { _ = try await invalidBearer.me() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testClientAlsoRefusesEveryRedirectStatusReturnedByFake() async throws {
        for status in [300, 301, 302, 303, 304, 307, 308, 399] {
            let transport = SyncClientFakeTransport(response: .init(statusCode: status, headers: ["Location": "https://other.example"], body: Data()))
            let client = try client(transport)
            await assertError(.transport(.redirectRefused)) { _ = try await client.me() }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testNamedRequestDeadlineIsCappedAndEarlierCallerDeadlineIsPreserved() async throws {
        let transport = SyncClientFakeTransport(response: try http(me))
        let client = try client(transport)
        let before = ContinuousClock.now
        _ = try await client.me()
        let after = ContinuousClock.now
        XCTAssertGreaterThanOrEqual(transport.requests[0].deadline, before.advanced(by: Limits.syncRequestTimeout))
        XCTAssertLessThanOrEqual(transport.requests[0].deadline, after.advanced(by: .seconds(60)))
        let earlier = ContinuousClock.now.advanced(by: .seconds(2))
        _ = try await client.me(deadline: earlier)
        XCTAssertEqual(transport.requests[1].deadline, earlier)
        _ = try await client.me(deadline: .now.advanced(by: .seconds(300)))
        XCTAssertLessThanOrEqual(transport.requests[2].deadline, ContinuousClock.now.advanced(by: .seconds(60)))
        await assertError(.transport(.deadlineExceeded)) { _ = try await client.me(deadline: .now.advanced(by: .seconds(-1))) }
        XCTAssertEqual(transport.requests.count, 3)
        let late = SyncClientFakeTransport { _ in
            try await Task.sleep(for: .milliseconds(30))
            return try self.http(self.me)
        }
        await assertError(.transport(.deadlineExceeded)) {
            _ = try await self.client(late).me(deadline: .now.advanced(by: .milliseconds(10)))
        }
    }

    func testCancellationBeforeDuringAndAfterTransportIsTyped() async throws {
        let transport = SyncClientFakeTransport(response: try http(me))
        let client = try client(transport)
        let cancelled = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            return try await client.me()
        }
        cancelled.cancel()
        await assertError(.transport(.cancelled)) { _ = try await cancelled.value }
        XCTAssertTrue(transport.requests.isEmpty)

        let began = expectation(description: "Fake request began")
        let waiting = SyncClientFakeTransport { _ in
            began.fulfill()
            try await Task.sleep(for: .seconds(30))
            return try self.http(self.me)
        }
        let waitingClient = try self.client(waiting)
        let inFlight = Task { try await waitingClient.me() }
        await fulfillment(of: [began], timeout: 2)
        inFlight.cancel()
        await assertError(.transport(.cancelled)) { _ = try await inFlight.value }

        let after = SyncClientFakeTransport { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return try self.http(self.me)
        }
        let afterClient = try self.client(after)
        let completed = Task { try await afterClient.me() }
        await assertError(.transport(.cancelled)) { _ = try await completed.value }
    }

    func testTransportErrorsPassThroughAndUnknownErrorsCannotLeakSecrets() async throws {
        for error in [HTTPTransportError.cancelled, .deadlineExceeded, .networkFailure, .responseTooLarge, .redirectRefused] {
            let transport = SyncClientFakeTransport { _ in throw error }
            let client = try client(transport)
            await assertError(.transport(error)) { _ = try await client.me() }
        }
        let sentinel = UUID().uuidString
        let transport = SyncClientFakeTransport { _ in throw NSError(domain: sentinel, code: 1, userInfo: [NSLocalizedDescriptionKey: sentinel]) }
        let client = try client(transport)
        await assertError(.transport(.networkFailure)) { _ = try await client.me() }
    }

    func testDescriptionsReflectionAndNSErrorNeverRevealTokensOrConflictContent() async throws {
        let secret = String(repeating: "b", count: 42) + "A"
        let server = try SyncServerURL("https://example.com/paw")
        let credential = SyncCredential(server: server, token: SecretValue(secret))
        let auth = SyncAuthentication(credential: credential, user: user)
        let invite = SyncIssuedInvite(token: SecretValue(secret), expiresAt: timestamp, target: .account)
        let errors: [SyncHTTPClientError] = [
            .conflict(head: .init(rev: 1, scope: .user, path: secret, content: secret)),
            .pathTaken(existing: .init(id: id.rawValue, rev: 1, content: secret)),
            .snapshotExpired(scopes: [secret]), .serverFailure(statusCode: 503)
        ]
        let transport = SyncClientFakeTransport(response: try http(me))
        let client = SyncHTTPClient(server: server, transport: transport, credential: credential)
        for value: Any in [credential, auth, invite, client] + errors.map({ $0 as Any }) {
            XCTAssertFalse(String(describing: value).contains(secret))
            XCTAssertFalse(String(reflecting: value).contains(secret))
            XCTAssertFalse(Mirror(reflecting: value).children.map { String(reflecting: $0.value) }.joined().contains(secret))
        }
        for error in errors { XCTAssertFalse((error as NSError).description.contains(secret)) }
    }

    private enum Authentication { case none, bearer }

    private func client(_ transport: HTTPTransporting) throws -> SyncHTTPClient {
        let server = try SyncServerURL("https://example.com/paw")
        return SyncHTTPClient(server: server, transport: transport, credential: .init(server: server, token: SecretValue(token)))
    }

    private func http(_ dto: some SyncAPIDTO, status: Int = 200, headers: [String: String] = [:]) throws -> HTTPResponse {
        .init(statusCode: status, headers: headers, body: try JSONEncoder().encode(dto))
    }

    private func check<Response: SyncAPIDTO & Equatable>(response: Response, method: HTTPMethod, path: String,
        query: String? = nil, body: String? = nil, operation: (SyncHTTPClient) async throws -> Response,
        file: StaticString = #filePath, line: UInt = #line) async throws {
        let transport = SyncClientFakeTransport(response: try http(response))
        let client = try client(transport)
        let actual = try await operation(client)
        XCTAssertEqual(actual, response, file: file, line: line)
        XCTAssertEqual(transport.requests.count, 1, file: file, line: line)
        try assertRequest(XCTUnwrap(transport.requests.first), client: client, method: method, path: path,
                          query: query, body: body, file: file, line: line)
    }

    private func assertRequest(_ request: HTTPRequest, client: SyncHTTPClient, method: HTTPMethod, path: String,
        query: String? = nil, body: String? = nil, authentication: Authentication = .bearer,
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(request.method, method, file: file, line: line)
        XCTAssertEqual(request.url.absoluteString, client.server.apiURL.absoluteString + path + (query.map { "?" + $0 } ?? ""), file: file, line: line)
        var headers = ["Accept": "application/json"]
        if case .bearer = authentication { headers["Authorization"] = "Bearer " + token }
        if body != nil { headers["Content-Type"] = "application/json" }
        XCTAssertEqual(request.headers, headers, file: file, line: line)
        XCTAssertEqual(request.body, body.map { Data($0.utf8) }, file: file, line: line)
        XCTAssertEqual(request.urlPolicy, .sync(server: client.server), file: file, line: line)
        XCTAssertEqual(request.requestByteCap, 2 * 1_024 * 1_024, file: file, line: line)
        XCTAssertEqual(request.responseByteCap, path == "/sync/pull" ? 16 * 1_024 * 1_024 : Limits.responseCap, file: file, line: line)
    }

    private func errorCases() throws -> [(SyncAPI.ErrorResponse, SyncHTTPClientError)] {
        let head = SyncAPI.ConflictHead(rev: 3, scope: .group(groupID: otherID.rawValue), path: "name.md", content: "server\r\n")
        let existing = SyncAPI.ExistingPrompt(id: id.rawValue, rev: 2, content: "existing\n")
        let issues = [SyncAPI.Issue(code: "prompt.id_mismatch", severity: .error, location: .frontMatter(line: 1, column: 1)),
                      .init(code: "path.empty", severity: .error, location: .path(segment: nil))]
        let scopes = ["user:\(id.rawValue)", "group:\(otherID.rawValue)"]
        return [(.conflict(head: head), .conflict(head: head)), (.pathTaken(existing: existing), .pathTaken(existing: existing)),
                (.deleted, .deleted), (.validation(issues: issues), .validation(issues: issues)),
                (.snapshotExpired(scopes: scopes), .snapshotExpired(scopes: scopes)),
                (.failure(.malformedRequest), .malformedRequest), (.failure(.unauthorized), .unauthorized),
                (.failure(.forbidden), .forbidden), (.failure(.notFound), .notFound),
                (.failure(.envelopeTooLarge), .envelopeTooLarge), (.failure(.internalError), .serverFailure(statusCode: 500)),
                (.failure(.rateLimited), .rateLimited(retryAfter: try .init(seconds: 30)))]
    }

    private func assertError(_ expected: SyncHTTPClientError, operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected typed sync error", file: file, line: line) }
        catch { XCTAssertEqual(error as? SyncHTTPClientError, expected, file: file, line: line) }
    }
}

private final class SyncClientFakeTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [HTTPRequest]()
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) { self.handler = handler }
    convenience init(response: HTTPResponse) { self.init { _ in response } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return try await handler(request)
    }

    private func record(_ request: HTTPRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }
}
