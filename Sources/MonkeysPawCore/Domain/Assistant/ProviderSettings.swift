import Foundation

/// Non-secret version-1 provider metadata, stored beside settings.json.
public struct ProviderSettings: Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int { Self.currentVersion }
    public let profiles: [ProviderProfile]
    public let selectedProfileID: ProviderProfileID?

    public init(profiles: [ProviderProfile] = [], selectedProfileID: ProviderProfileID? = nil) throws {
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ProviderSettingsError.duplicateProfile }
        guard selectedProfileID == nil || profiles.contains(where: { $0.id == selectedProfileID }) else {
            throw ProviderSettingsError.profileNotFound
        }
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
    }

    public static func normalizeBaseURL(_ input: String, kind: ProviderKind) throws -> URL {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains("\\"),
              !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let rawHost = components.host, !rawHost.isEmpty else {
            throw ProviderSettingsError.invalidBaseURL
        }
        guard components.user == nil, components.password == nil else {
            throw ProviderSettingsError.credentialsInURL
        }
        // Provider bases have path semantics only. Reject every query rather
        // than trying to guess which parameter names hold credentials.
        guard components.query == nil, components.fragment == nil else {
            throw ProviderSettingsError.queryOrFragmentInURL
        }

        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains("%"),
              host.unicodeScalars.allSatisfy({ $0.isASCII }),
              (!host.hasPrefix("[") || isValidIPLiteral(host)),
              components.rangeOfPort.map({ $0.isEmpty || components.port != nil }) ?? true,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw ProviderSettingsError.invalidBaseURL
        }
        guard scheme == "https" || isLoopback(host) else { throw ProviderSettingsError.insecureBaseURL }
        components.scheme = scheme
        components.host = host
        // Resetting a missing port also removes an empty IPv6 port's colon.
        components.port = components.port == (scheme == "https" ? 443 : 80) ? nil : components.port

        // URLComponents.path silently returns empty for undecodable UTF-8.
        guard var path = components.percentEncodedPath.removingPercentEncoding else {
            throw ProviderSettingsError.invalidBaseURL
        }
        guard !path.contains("\\"), !path.contains("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !components.percentEncodedPath.lowercased().contains("%2f") else {
            throw ProviderSettingsError.invalidBaseURL
        }
        while path.hasSuffix("/") { path.removeLast() }
        let suffixes = kind == .anthropic ? ["/messages", "/models"] : ["/chat/completions", "/models"]
        // Reach a fixed point so persisted normalized bases do not change on
        // the next read, even when endpoint/version suffixes were repeated.
        while true {
            if let suffix = suffixes.first(where: path.hasSuffix) {
                path.removeLast(suffix.count)
                continue
            }
            if kind == .anthropic, path.hasSuffix("/v1") {
                path.removeLast(3)
                continue
            }
            break
        }
        if kind == .openaiCompatible, path.isEmpty { path = "/v1" }
        components.path = path
        guard let url = components.url else { throw ProviderSettingsError.invalidBaseURL }
        return url
    }

    private static func isValidIPLiteral(_ host: String) -> Bool {
        guard host.hasSuffix("]") else { return false }
        let literal = host.dropFirst().dropLast()
        if literal.hasPrefix("v") {
            let parts = literal.dropFirst().split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let allowed = "abcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:"
            return parts.count == 2 && !parts[0].isEmpty && parts[0].utf8.allSatisfy(isHexDigit)
                && !parts[1].isEmpty && parts[1].utf8.allSatisfy { allowed.utf8.contains($0) }
        }

        let halves = literal.split(separator: "::", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return false }
        let groups = halves.flatMap { $0.isEmpty ? [] : $0.split(separator: ":", omittingEmptySubsequences: false) }
        var count = groups.count
        for (index, group) in groups.enumerated() {
            if group.contains(".") {
                guard index == groups.count - 1, literal.last != ":" else { return false }
                let octets = group.split(separator: ".", omittingEmptySubsequences: false)
                guard octets.count == 4, octets.allSatisfy({ octet in
                    guard !octet.isEmpty, octet.utf8.count <= 3,
                          octet.utf8.allSatisfy({ (48...57).contains($0) }),
                          let value = Int(octet), value <= 255 else { return false }
                    return String(value) == octet
                }) else { return false }
                count += 1 // An IPv4 tail occupies two IPv6 groups.
            } else if group.isEmpty || group.utf8.count > 4 || !group.utf8.allSatisfy(isHexDigit) {
                return false
            }
        }
        return halves.count == 2 ? count < 8 : count == 8
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    // Shared with the transport after lowercasing and trimming a trailing dot.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if literal.contains(":") {
            let halves = literal.components(separatedBy: "::")
            var groups = [String]()
            if halves.count == 2 {
                let left = halves[0].isEmpty ? [] : halves[0].components(separatedBy: ":")
                let right = halves[1].isEmpty ? [] : halves[1].components(separatedBy: ":")
                let missing = 8 - left.count - right.count
                guard missing > 0 else { return false }
                groups = left + Array(repeating: "0", count: missing) + right
            } else { groups = literal.components(separatedBy: ":") }
            guard groups.count == 8,
                  groups.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  } }) else { return false }
            return groups.dropLast().allSatisfy { Int($0, radix: 16) == 0 } && Int(groups[7], radix: 16) == 1
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { octet in
            guard let value = Int(octet), (0...255).contains(value) else { return false }
            return String(value) == octet
        }
    }

    static func credentialOrigin(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return "\(components.scheme!)://\(components.host!):\(components.port ?? (components.scheme == "https" ? 443 : 80))"
    }
}

public struct ProviderSettingsSnapshot: Equatable, Sendable {
    public let settings: ProviderSettings
    public let readOnlyError: ProviderSettingsError?
    public var isReadOnly: Bool { readOnlyError != nil }
}
