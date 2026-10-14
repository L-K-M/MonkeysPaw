import Foundation

/// Y11 persists this binding in its versioned secret envelope. A raw token
/// cannot be reused by a client pointing at another deployment.
struct SyncCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let server: SyncServerURL
    let token: SecretValue

    var description: String { "<sync credential redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": description]) }

    fileprivate func authorization(for server: SyncServerURL) throws -> String {
        guard self.server == server else { throw SyncHTTPClientError.credentialServerMismatch }
        return try token.withValue {
            do { try SyncAPISchema.token.validate(.string($0)) }
            catch { throw SyncHTTPClientError.invalidRequest }
            return "Bearer " + $0
        }
    }
}

struct SyncAuthentication: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let credential: SyncCredential
    let user: SyncAPI.User

    var description: String { "<sync authentication redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["authentication": description]) }
}

struct SyncIssuedInvite: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: SecretValue
    let expiresAt: String
    let target: SyncAPI.InviteTarget

    var description: String { "<sync invite redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["invite": description]) }
}

/// Payloads remain available to reconciliation, but never enter diagnostics.
enum SyncHTTPClientError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case conflict(head: SyncAPI.ConflictHead)
    case pathTaken(existing: SyncAPI.ExistingPrompt)
    case deleted
    case validation(issues: [SyncAPI.Issue])
    case snapshotExpired(scopes: [String])
    case malformedRequest
    case unauthorized
    case forbidden
    case notFound
    case envelopeTooLarge
    case rateLimited(retryAfter: SyncAPI.RetryAfter)
    case serverFailure(statusCode: Int)
    case statusEnvelopeMismatch(statusCode: Int)
    case malformedResponse
    case invalidRequest
    case credentialServerMismatch
    case transport(HTTPTransportError)

    var description: String { "<sync HTTP error redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["error": description]) }
}

/// Immutable connection and injected transport. No retries, persistence or
/// engine decisions belong here; every operation consumes the shared catalog.
struct SyncHTTPClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let server: SyncServerURL
    private let transport: HTTPTransporting
    private let credential: SyncCredential?

    init(server: SyncServerURL, transport: HTTPTransporting, credential: SyncCredential? = nil) {
        self.server = server
        self.transport = transport
        self.credential = credential
    }

    func permitting(_ permit: SyncWorkPermit) -> SyncHTTPClient {
        SyncHTTPClient(server: server, transport: SyncPermittedTransport(transport: transport, permit: permit),
            credential: credential)
    }

    func login(_ request: SyncAPI.LoginRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAuthentication {
        let response: SyncAPI.AuthResponse = try await send(.post, "/api/v1/auth/login", body: encode(request),
                                                          authentication: .none, deadline: deadline)
        return authentication(response)
    }

    func register(_ request: SyncAPI.RegisterRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAuthentication {
        let response: SyncAPI.AuthResponse = try await send(.post, "/api/v1/auth/register", body: encode(request),
                                                          authentication: .none, deadline: deadline)
        return authentication(response)
    }

    func logout(deadline: ContinuousClock.Instant? = nil) async throws {
        let _: SyncAPI.EmptyResponse = try await send(.post, "/api/v1/auth/logout", deadline: deadline)
    }

    func me(deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.MeResponse {
        try await send(.get, "/api/v1/me", deadline: deadline)
    }

    func devices(deadline: ContinuousClock.Instant? = nil) async throws -> [SyncAPI.Device] {
        try await me(deadline: deadline).devices
    }

    func revokeDevice(id: ULID, deadline: ContinuousClock.Instant? = nil) async throws {
        let _: SyncAPI.EmptyResponse = try await send(.delete, "/api/v1/me/devices/{id}",
                                                     parameters: ["id": id.rawValue], deadline: deadline)
    }

    func prompt(id: ULID, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.Prompt {
        try await send(.get, "/api/v1/prompts/{id}", parameters: ["id": id.rawValue], deadline: deadline)
    }

    func putPrompt(id: ULID, request: SyncAPI.PutPromptRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.WriteResponse {
        try await send(.put, "/api/v1/prompts/{id}", parameters: ["id": id.rawValue], body: encode(request), deadline: deadline)
    }

    func deletePrompt(id: ULID, baseRev: Int64, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.WriteResponse {
        let query = SyncAPI.DeletePromptQuery(baseRev: baseRev)
        do { try SyncAPI.DeletePromptQuery.schema.validate(.object(query.object)) }
        catch { throw SyncHTTPClientError.invalidRequest }
        return try await send(.delete, "/api/v1/prompts/{id}", parameters: ["id": id.rawValue],
                              query: [URLQueryItem(name: "base_rev", value: String(baseRev))], deadline: deadline)
    }

    func movePrompt(id: ULID, request: SyncAPI.MovePromptRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.WriteResponse {
        try await send(.post, "/api/v1/prompts/{id}/move", parameters: ["id": id.rawValue], body: encode(request), deadline: deadline)
    }

    func pull(_ request: SyncAPI.PullRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.PullResponse {
        try await send(.post, "/api/v1/sync/pull", body: encode(request), deadline: deadline)
    }

    func createGroup(_ request: SyncAPI.CreateGroupRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.Group {
        try await send(.post, "/api/v1/groups", body: encode(request), deadline: deadline)
    }

    func renameGroup(id: ULID, request: SyncAPI.RenameGroupRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.Group {
        try await send(.patch, "/api/v1/groups/{id}", parameters: ["id": id.rawValue], body: encode(request), deadline: deadline)
    }

    func deleteGroup(id: ULID, deadline: ContinuousClock.Instant? = nil) async throws {
        let _: SyncAPI.EmptyResponse = try await send(.delete, "/api/v1/groups/{id}", parameters: ["id": id.rawValue], deadline: deadline)
    }

    func members(groupID: ULID, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.MembersResponse {
        try await send(.get, "/api/v1/groups/{id}/members", parameters: ["id": groupID.rawValue], deadline: deadline)
    }

    func upsertMember(groupID: ULID, userID: ULID, request: SyncAPI.MembershipRequest,
                      deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.Member {
        try await send(.put, "/api/v1/groups/{id}/members/{user_id}", parameters: ["id": groupID.rawValue, "user_id": userID.rawValue],
                       body: encode(request), deadline: deadline)
    }

    func removeMember(groupID: ULID, userID: ULID, deadline: ContinuousClock.Instant? = nil) async throws {
        let _: SyncAPI.EmptyResponse = try await send(.delete, "/api/v1/groups/{id}/members/{user_id}",
            parameters: ["id": groupID.rawValue, "user_id": userID.rawValue], deadline: deadline)
    }

    func createInvite(groupID: ULID, request: SyncAPI.GroupInviteRequest,
                      deadline: ContinuousClock.Instant? = nil) async throws -> SyncIssuedInvite {
        let response: SyncAPI.InviteResponse = try await send(.post, "/api/v1/groups/{id}/invites", parameters: ["id": groupID.rawValue],
                                                              body: encode(request), deadline: deadline)
        return SyncIssuedInvite(token: SecretValue(response.inviteToken), expiresAt: response.expiresAt, target: response.target)
    }

    func joinGroup(_ request: SyncAPI.JoinGroupRequest, deadline: ContinuousClock.Instant? = nil) async throws -> SyncAPI.GroupMembership {
        try await send(.post, "/api/v1/groups/join", body: encode(request), deadline: deadline)
    }

    private enum Authentication { case none, bearer }

    private func authentication(_ response: SyncAPI.AuthResponse) -> SyncAuthentication {
        SyncAuthentication(credential: SyncCredential(server: server, token: SecretValue(response.deviceToken)), user: response.user)
    }

    private func encode(_ value: some SyncAPIDTO) throws -> Data {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(value)
        } catch { throw SyncHTTPClientError.invalidRequest }
        guard data.count <= SyncAPI.requestEnvelopeMaxBytes else { throw SyncHTTPClientError.transport(.requestTooLarge) }
        return data
    }

    private func send<Response: SyncAPIDTO>(_ method: HTTPMethod, _ path: String, parameters: [String: String] = [:],
        query: [URLQueryItem] = [], body: Data? = nil, authentication: Authentication = .bearer,
        deadline suppliedDeadline: ContinuousClock.Instant?) async throws -> Response {
        do {
            try Task.checkCancellation()
            let requestDeadline = ContinuousClock.now.advanced(by: Limits.syncRequestTimeout)
            let deadline = min(requestDeadline, suppliedDeadline ?? requestDeadline)
            guard ContinuousClock.now < deadline else { throw HTTPTransportError.deadlineExceeded }
            guard let endpoint = SyncAPI.endpoints.first(where: { $0.method == method.rawValue && $0.path == path }),
                  endpoint.responseBody == Response.schemaName else { throw SyncHTTPClientError.invalidRequest }

            var relative = String(endpoint.path.dropFirst("/api/v1/".count))
            for (key, value) in parameters { relative = relative.replacingOccurrences(of: "{" + key + "}", with: value) }
            var components = URLComponents(url: server.apiURL.appendingPathComponent(relative), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            guard let url = components.url else { throw SyncHTTPClientError.invalidRequest }
            var headers = ["Accept": "application/json"]
            if body != nil { headers["Content-Type"] = "application/json" }
            if case .bearer = authentication {
                guard let credential else { throw SyncHTTPClientError.unauthorized }
                headers["Authorization"] = try credential.authorization(for: server)
            }
            let request = try HTTPRequest(url: url, method: method, headers: headers, body: body,
                requestByteCap: SyncAPI.requestEnvelopeMaxBytes,
                responseByteCap: Response.schemaName == SyncAPI.PullResponse.schemaName ? SyncAPI.responseEnvelopeMaxBytes : Limits.responseCap,
                deadline: deadline, urlPolicy: .sync(server: server))
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw HTTPTransportError.deadlineExceeded }
            guard response.body.count <= request.responseByteCap else { throw HTTPTransportError.responseTooLarge }
            guard !(300..<400).contains(response.statusCode) else { throw HTTPTransportError.redirectRefused }
            if response.statusCode != endpoint.successStatus {
                let error: SyncHTTPClientError
                if (try? JSONDecoder().decode(Response.self, from: response.body)) != nil {
                    error = .statusEnvelopeMismatch(statusCode: response.statusCode)
                } else { error = responseError(response) }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw HTTPTransportError.deadlineExceeded }
                throw error
            }

            let decoded: Response
            do { decoded = try JSONDecoder().decode(Response.self, from: response.body) }
            catch {
                if (try? JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: response.body)) != nil {
                    throw SyncHTTPClientError.statusEnvelopeMismatch(statusCode: response.statusCode)
                }
                throw SyncHTTPClientError.malformedResponse
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw HTTPTransportError.deadlineExceeded }
            return decoded
        } catch let error as SyncHTTPClientError { throw error }
        catch let error as HTTPTransportError { throw SyncHTTPClientError.transport(error) }
        catch is CancellationError { throw SyncHTTPClientError.transport(.cancelled) }
        catch { throw SyncHTTPClientError.transport(.networkFailure) }
    }

    private func responseError(_ response: HTTPResponse) -> SyncHTTPClientError {
        guard let envelope = try? JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: response.body) else {
            // Gateways may return non-JSON 5xx bodies. Keep only their status.
            if (500...599).contains(response.statusCode) { return .serverFailure(statusCode: response.statusCode) }
            return .malformedResponse
        }
        guard envelope.httpStatus == response.statusCode else { return .statusEnvelopeMismatch(statusCode: response.statusCode) }
        switch envelope {
        case .conflict(let head): return .conflict(head: head)
        case .pathTaken(let existing): return .pathTaken(existing: existing)
        case .deleted: return .deleted
        case .validation(let issues): return .validation(issues: issues)
        case .snapshotExpired(let scopes): return .snapshotExpired(scopes: scopes)
        case .failure(let code):
            switch code {
            case .malformedRequest: return .malformedRequest
            case .unauthorized: return .unauthorized
            case .forbidden: return .forbidden
            case .notFound: return .notFound
            case .envelopeTooLarge: return .envelopeTooLarge
            case .internalError: return .serverFailure(statusCode: response.statusCode)
            case .rateLimited:
                let headers = response.headers.filter { $0.key.lowercased() == "retry-after" }
                guard headers.count == 1, let value = headers.first?.value,
                      let retry = try? SyncAPI.RetryAfter(headerValue: value) else { return .malformedResponse }
                return .rateLimited(retryAfter: retry)
            }
        }
    }

    var description: String { "<sync HTTP client redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["client": description]) }
}
