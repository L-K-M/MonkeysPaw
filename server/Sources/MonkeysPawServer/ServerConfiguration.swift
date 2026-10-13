import Foundation
import Logging
import MonkeysPawCore

/// Environment configuration shared by serving and the Docker healthcheck.
public struct ServerConfiguration: Sendable {
    let httpHost: String
    let version: String
    public let httpPort: Int
    let trustedProxies: TrustedProxies
    let logLevel: Logger.Level
    let publicURL: String?

    /// Treats empty or whitespace-only environment values as unset before applying defaults.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let environment = environment.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        httpHost = environment["MONKEYSPAW_HTTP_HOST"] ?? ServerLimits.defaultHTTPHost
        version = environment["MONKEYSPAW_VERSION"] ?? AppIdentity.fallbackVersion
        logLevel = ServerLogging.logLevel(environment: environment)
        publicURL = environment["MONKEYSPAW_PUBLIC_URL"]
        if let publicURL {
            guard let url = URLComponents(string: publicURL), ["http", "https"].contains(url.scheme?.lowercased()),
                  let host = url.host, !host.isEmpty, url.url != nil, url.user == nil, url.password == nil,
                  url.fragment == nil, !publicURL.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
                throw ConfigurationError.invalidPublicURL
            }
        }

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
        case invalidPublicURL

        var description: String {
            switch self {
            case .invalidHTTPPort:
                return "MONKEYSPAW_HTTP_PORT must be an integer in \(ServerLimits.httpPortRange)."
            case .invalidTrustedProxies:
                return "MONKEYSPAW_TRUSTED_PROXIES must be a bounded comma-separated list of IP addresses or CIDRs."
            case .invalidPublicURL:
                return "MONKEYSPAW_PUBLIC_URL must be an absolute HTTP(S) URL without credentials or a fragment."
            }
        }
    }
}
