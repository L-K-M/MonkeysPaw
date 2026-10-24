import Foundation

/// Body names reference SyncAPI.schemas. Parameter schemas describe the values
/// after URL/query extraction, not an extra JSON request body.
public struct SyncAPIEndpoint: Equatable, Sendable {
    public let method: String
    public let path: String
    public let requestBody: String?
    public let pathParameters: String?
    public let query: String?
    public let responseBody: String
    public let successStatus: Int

    init(_ method: String, _ path: String, request: String? = nil, parameters: String? = nil,
         query: String? = nil, response: String) {
        self.method = method
        self.path = path
        requestBody = request
        pathParameters = parameters
        self.query = query
        responseBody = response
        successStatus = 200
    }
}

extension SyncAPI {
    /// B3: transport limits are separate from decoded prompt UTF-8 bounds.
    public static let requestEnvelopeMaxBytes = 2 * 1_024 * 1_024
    public static var responseEnvelopeMaxBytes: Int { Limits.syncResponseCap }
    public static let endpoints: [SyncAPIEndpoint] = [
        .init("GET", "/api/health", response: "HealthResponse"),
        .init("POST", "/api/v1/auth/login", request: "LoginRequest", response: "AuthResponse"),
        .init("POST", "/api/v1/auth/logout", response: "EmptyResponse"),
        .init("POST", "/api/v1/auth/register", request: "RegisterRequest", response: "AuthResponse"),
        .init("POST", "/api/v1/auth/password", request: "PasswordChangeRequest", response: "EmptyResponse"),
        .init("GET", "/api/v1/me", response: "MeResponse"),
        .init("DELETE", "/api/v1/me/devices/{id}", parameters: "IDPath", response: "EmptyResponse"),
        .init("GET", "/api/v1/me/provider-settings", response: "ProviderSettingsDocument"),
        .init("PUT", "/api/v1/me/provider-settings", request: "PutProviderSettingsRequest", response: "ProviderSettingsResponse"),
        .init("POST", "/api/v1/sync/pull", request: "PullRequest", response: "PullResponse"),
        .init("GET", "/api/v1/prompts/{id}", parameters: "IDPath", response: "Prompt"),
        .init("PUT", "/api/v1/prompts/{id}", request: "PutPromptRequest", parameters: "IDPath", response: "WriteResponse"),
        .init("DELETE", "/api/v1/prompts/{id}", parameters: "IDPath", query: "DeletePromptQuery", response: "WriteResponse"),
        .init("POST", "/api/v1/prompts/{id}/move", request: "MovePromptRequest", parameters: "IDPath", response: "WriteResponse"),
        .init("GET", "/api/v1/prompts/{id}/revisions", parameters: "IDPath", response: "RevisionsResponse"),
        .init("GET", "/api/v1/prompts/{id}/revisions/{rev}", parameters: "RevisionPath", response: "Revision"),
        .init("POST", "/api/v1/groups", request: "CreateGroupRequest", response: "Group"),
        .init("PATCH", "/api/v1/groups/{id}", request: "RenameGroupRequest", parameters: "IDPath", response: "Group"),
        .init("DELETE", "/api/v1/groups/{id}", parameters: "IDPath", response: "EmptyResponse"),
        .init("POST", "/api/v1/groups/join", request: "JoinGroupRequest", response: "GroupMembership"),
        .init("GET", "/api/v1/groups/{id}/members", parameters: "IDPath", response: "MembersResponse"),
        .init("PUT", "/api/v1/groups/{id}/members/{user_id}", request: "MembershipRequest", parameters: "MemberPath", response: "Member"),
        .init("DELETE", "/api/v1/groups/{id}/members/{user_id}", parameters: "MemberPath", response: "EmptyResponse"),
        .init("POST", "/api/v1/groups/{id}/invites", request: "GroupInviteRequest", parameters: "IDPath", response: "InviteResponse"),
        .init("POST", "/api/v1/admin/users", request: "CreateUserRequest", response: "User"),
        .init("PATCH", "/api/v1/admin/users/{id}", request: "UpdateUserRequest", parameters: "IDPath", response: "User"),
        .init("POST", "/api/v1/admin/invites", request: "AdminInviteRequest", response: "InviteResponse")
    ]

    /// A body alone cannot represent an HTTP header; S2 can render this header
    /// description separately from the ErrorResponse JSON schema.
    public static let rateLimitHeaders: [SyncAPIField] = [.init("Retry-After", .reference("RetryAfter"))]
}
