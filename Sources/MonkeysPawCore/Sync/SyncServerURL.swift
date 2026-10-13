import Foundation

public enum SyncServerURLError: String, Error, Equatable, Sendable {
    case invalidURL
    case credentialsInURL
    case queryOrFragmentInURL
    case insecureURL
    case invalidDeploymentPrefix
}

/// A validated deployment base, without /api/v1, suitable for SyncAccount.
/// HTTP exemptions are lexical: DNS never grants a hostname private access.
public struct SyncServerURL: Hashable, Sendable {
    public let baseURL: URL
    public var apiURL: URL { baseURL.appendingPathComponent("api/v1") }

    public init(_ input: String) throws {
        var components = try Self.components(input, queryAllowed: false)
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        // Reach a fixed point, including a pasted, repeated API suffix.
        while path.hasSuffix("/api/v1") { path.removeLast(7) }
        components.path = path
        guard let url = components.url else { throw SyncServerURLError.invalidURL }
        baseURL = url
    }

    /// Revalidate each request and restrict it to this deployment's API tree.
    func validatedRequestURL(_ url: URL) throws -> URL {
        let components: URLComponents
        do { components = try Self.components(url.absoluteString, queryAllowed: true) }
        catch SyncServerURLError.credentialsInURL { throw HTTPTransportError.credentialsInURL }
        catch SyncServerURLError.insecureURL { throw HTTPTransportError.insecureURL }
        catch { throw HTTPTransportError.invalidURL }

        let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let apiPath = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!.percentEncodedPath
        guard components.scheme == base.scheme, components.host == base.host, components.port == base.port,
              components.percentEncodedPath.hasPrefix(apiPath + "/") else {
            throw HTTPTransportError.serverMismatch
        }
        guard let normalized = components.url else { throw HTTPTransportError.invalidURL }
        return normalized
    }

    private static func components(_ input: String, queryAllowed: Bool) throws -> URLComponents {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains("\\"),
              !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = components.host, !rawHost.isEmpty,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw SyncServerURLError.invalidURL
        }
        guard components.user == nil, components.password == nil else { throw SyncServerURLError.credentialsInURL }
        guard (queryAllowed || components.query == nil), components.fragment == nil else {
            throw SyncServerURLError.queryOrFragmentInURL
        }

        // Foundation decodes host escapes and performs IDNA mapping. Escaped
        // and Unicode lookalikes must never acquire a literal HTTP exemption.
        guard let authorityStart = input.range(of: "://")?.upperBound else { throw SyncServerURLError.invalidURL }
        let authority = input[authorityStart...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("%"), let urlHost = components.url?.host else { throw SyncServerURLError.invalidURL }
        var host = urlHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(\.isASCII) else { throw SyncServerURLError.invalidURL }

        if host.contains(":") {
            guard let words = ipv6(host) else { throw SyncServerURLError.invalidURL }
            host = "[" + canonicalIPv6(words) + "]"
        } else {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".utf8)
            guard host.utf8.allSatisfy(allowed.contains), !host.contains("..") else { throw SyncServerURLError.invalidURL }
        }
        guard scheme == "https" || (authority.unicodeScalars.allSatisfy(\.isASCII) && allowsHTTP(host)) else {
            throw SyncServerURLError.insecureURL
        }
        components.scheme = scheme
        components.host = host
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }

        let path = components.path
        guard !path.contains("\\"), !path.contains("//"), !path.contains("%"),
              !path.contains("?"), !path.contains("#"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !components.percentEncodedPath.lowercased().contains("%2f") else {
            throw SyncServerURLError.invalidDeploymentPrefix
        }
        components.path = path
        return components
    }

    private static func allowsHTTP(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host.hasPrefix("[") {
            guard let words = ipv6(String(host.dropFirst().dropLast())) else { return false }
            return (words.dropLast().allSatisfy { $0 == 0 } && words.last == 1) || words[0] & 0xfe00 == 0xfc00
        }
        guard let bytes = ipv4(host) else { return false }
        return bytes[0] == 127 || bytes[0] == 10 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
    }

    private static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let byte = UInt8(part), String(byte) == part else { return nil }
            return byte
        }
        return bytes.count == 4 ? bytes : nil
    }

    private static func ipv6(_ text: String) -> [UInt16]? {
        var text = text
        if text.contains(".") {
            guard let separator = text.lastIndex(of: ":"), let bytes = ipv4(String(text[text.index(after: separator)...])) else { return nil }
            text = String(text[...separator]) + String(UInt16(bytes[0]) << 8 | UInt16(bytes[1]), radix: 16) + ":" +
                String(UInt16(bytes[2]) << 8 | UInt16(bytes[3]), radix: 16)
        }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func words(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            let groups = part.split(separator: ":", omittingEmptySubsequences: false)
            var result = [UInt16]()
            for group in groups {
                guard (1...4).contains(group.utf8.count), group.utf8.allSatisfy({
                    (48...57).contains($0) || (97...102).contains($0)
                }), let word = UInt16(group, radix: 16) else { return nil }
                result.append(word)
            }
            return result
        }
        guard let left = words(halves[0]) else { return nil }
        if halves.count == 1 { return left.count == 8 ? left : nil }
        guard let right = words(halves[1]), left.count + right.count < 8 else { return nil }
        return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
    }

    private static func canonicalIPv6(_ words: [UInt16]) -> String {
        var bestStart = 0, bestCount = 0, index = 0
        while index < words.count {
            if words[index] != 0 { index += 1; continue }
            let start = index
            while index < words.count && words[index] == 0 { index += 1 }
            if index - start > bestCount { bestStart = start; bestCount = index - start }
        }
        let text = words.map { String($0, radix: 16) }
        guard bestCount >= 2 else { return text.joined(separator: ":") }
        return text[..<bestStart].joined(separator: ":") + "::" + text[(bestStart + bestCount)...].joined(separator: ":")
    }
}
