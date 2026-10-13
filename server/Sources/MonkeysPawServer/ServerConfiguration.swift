import Foundation
import MonkeysPawCore

/// Environment configuration shared by serving and the Docker healthcheck.
public struct ServerConfiguration: Sendable {
    let httpHost: String
    let version: String
    public let httpPort: Int
    let trustedProxies: TrustedProxies

    /// Treats empty or whitespace-only environment values as unset before applying defaults.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let environment = environment.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        httpHost = environment["MONKEYSPAW_HTTP_HOST"] ?? ServerLimits.defaultHTTPHost
        version = environment["MONKEYSPAW_VERSION"] ?? AppIdentity.fallbackVersion

        do {
            trustedProxies = try TrustedProxies(configuration: environment["MONKEYSPAW_TRUSTED_PROXIES"] ?? "")
        } catch {
            throw ConfigurationError.invalidTrustedProxies
        }

        guard let configuredPort = environment["MONKEYSPAW_HTTP_PORT"] else {
            httpPort = ServerLimits.defaultHTTPPort
            return
        }

        guard let port = Int(configuredPort), ServerLimits.httpPortRange.contains(port) else {
            throw ConfigurationError.invalidHTTPPort
        }

        httpPort = port
    }

    private enum ConfigurationError: Error, CustomStringConvertible {
        case invalidHTTPPort
        case invalidTrustedProxies

        var description: String {
            switch self {
            case .invalidHTTPPort:
                return "MONKEYSPAW_HTTP_PORT must be an integer in \(ServerLimits.httpPortRange)."
            case .invalidTrustedProxies:
                return "MONKEYSPAW_TRUSTED_PROXIES must be a bounded comma-separated list of IP addresses or CIDRs."
            }
        }
    }
}
