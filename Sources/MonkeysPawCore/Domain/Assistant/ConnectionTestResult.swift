import Foundation

/// No provider body, raw header, stored key or underlying diagnostic escapes Test.
public enum ConnectionTestResult: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    case ok(models: [ModelDescriptor])
    case authentication
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case network
    case timeout
    case unsupportedListing
    case invalidResponse
    case cancelled
    case settings(ProviderSettingsError)
    case providerFailure(statusCode: Int)

    public var description: String {
        switch self {
        case .ok: return "ok"
        case .authentication: return "authentication"
        case .notFound: return "notFound"
        case .rateLimited: return "rateLimited"
        case .network: return "network"
        case .timeout: return "timeout"
        case .unsupportedListing: return "unsupportedListing"
        case .invalidResponse: return "invalidResponse"
        case .cancelled: return "cancelled"
        case .settings: return "settings"
        case .providerFailure: return "providerFailure"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["result": description]) }
}
