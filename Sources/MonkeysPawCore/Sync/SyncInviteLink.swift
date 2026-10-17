import Foundation

enum SyncInviteLinkError: Error, Equatable { case invalidLink, serverRequired }

/// Untrusted bearer input. Neither this value nor its full URL is serializable.
struct SyncInviteLink: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let server: SyncServerURL
    let token: SecretValue

    init(_ input: String, server explicitServer: String? = nil) throws {
        if !input.contains(":") {
            guard Self.validToken(input) else { throw SyncInviteLinkError.invalidLink }
            guard let explicitServer, !explicitServer.isEmpty else { throw SyncInviteLinkError.serverRequired }
            do { server = try SyncServerURL(explicitServer) }
            catch { throw SyncInviteLinkError.invalidLink }
            token = SecretValue(input)
            return
        }

        guard !input.contains("\\"), !input.contains("#"),
              !input.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              let separator = input.firstIndex(of: "?"),
              input[..<separator].lowercased() == "monkeyspaw://join" else {
            throw SyncInviteLinkError.invalidLink
        }
        let query = input[input.index(after: separator)...]
        var values: [String: String] = [:]
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, ["server", "token"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, let value = Self.decode(String(pair[1])), !value.isEmpty else {
                throw SyncInviteLinkError.invalidLink
            }
            values[String(pair[0])] = value
        }
        guard values.count == 2, let destination = values["server"], let supplied = values["token"], Self.validToken(supplied) else {
            throw SyncInviteLinkError.invalidLink
        }
        do { server = try SyncServerURL(destination) }
        catch { throw SyncInviteLinkError.invalidLink }
        token = SecretValue(supplied)
    }

    init(server: SyncServerURL, token: SecretValue) throws {
        guard token.withValue(Self.validToken) else { throw SyncInviteLinkError.invalidLink }
        self.server = server
        self.token = token
    }

    var text: String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let destination = server.baseURL.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved)!
        return token.withValue { "monkeyspaw://join?server=" + destination + "&token=" + $0 }
    }

    private static func validToken(_ token: String) -> Bool {
        (try? SyncAPISchema.token.validate(.string(token))) != nil
    }

    private static func decode(_ value: String) -> String? {
        // Foundation can repair malformed escapes. Reject them before decoding;
        // '+' is literal, and a decoded '%' is never decoded a second time here.
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return nil }
                index += 3
            } else { index += 1 }
        }
        return value.removingPercentEncoding
    }

    private static func hex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    var description: String { "<sync invite link redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["invite": description]) }
}
