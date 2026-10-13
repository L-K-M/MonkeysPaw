import Foundation

/// M6 supplies authoritative group changes; the server authorizes independently.
public enum AssistantGroupRole: String, Equatable, Sendable {
    case viewer
    case editor
    case owner
}

public enum AssistantMutationAccess: Equatable, Sendable {
    case currentScope
    case privateCopy
    case unavailable
}

/// The local M4 flow uses privatePrompt without constructing Account/sync UI.
public enum AssistantAccessState: Equatable, Sendable {
    case privatePrompt
    case group(AssistantGroupRole)
    case unavailable

    public var mutationAccess: AssistantMutationAccess {
        switch self {
        case .privatePrompt, .group(.editor), .group(.owner): return .currentScope
        case .group(.viewer): return .privateCopy
        case .unavailable: return .unavailable
        }
    }
}

/// Provider content and underlying errors never become user-facing diagnostics.
public enum AssistantError: Error, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    case notConfigured
    case accessDenied
    case privatePrompt
    case transport(HTTPTransportError)
    case authentication
    case modelNotFound
    /// Parsed seconds only, never a raw provider header or body.
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case providerFailure(statusCode: Int)
    /// Local, non-secret capability state could not be read or published.
    case providerState(SettingsError)
    case truncated
    case declined
    case emptyResponse
    case unexpectedStop(String)
    case invalidOutput

    public var description: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .accessDenied: return "accessDenied"
        case .privatePrompt: return "privatePrompt"
        case .transport: return "transportFailure"
        case .authentication: return "authentication"
        case .modelNotFound: return "modelNotFound"
        case .rateLimited: return "rateLimited"
        case .overloaded: return "overloaded"
        case .providerFailure: return "providerFailure"
        case .providerState: return "providerState"
        case .truncated: return "truncated"
        case .declined: return "declined"
        case .emptyResponse: return "emptyResponse"
        case .unexpectedStop: return "unexpectedStop"
        case .invalidOutput: return "invalidOutput"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["error": description]) }
}
