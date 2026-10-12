import Foundation

/// Defer validation and file reads until the service observes an empty users table.
public struct BootstrapConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let username: String
    private let passwordFile: String?
    private let password: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        username = environment["MONKEYSPAW_ADMIN_USERNAME"] ?? ServerLimits.defaultAdminUsername
        passwordFile = environment["MONKEYSPAW_ADMIN_PASSWORD_FILE"]
        password = environment["MONKEYSPAW_ADMIN_PASSWORD"]
    }

    public var description: String { "BootstrapConfiguration(<redacted>)" }
    public var debugDescription: String { description }

    func credentials() throws -> (username: String, password: String) {
        do {
            let secret: String
            if let passwordFile {
                // A configured file is authoritative; never fall back on an unreadable one.
                var data = try Data(contentsOf: URL(fileURLWithPath: passwordFile))
                // Secret files commonly have one terminal line ending; spaces are significant.
                if data.last == 10 {
                    data.removeLast()
                    if data.last == 13 { data.removeLast() }
                }
                guard let value = String(data: data, encoding: .utf8) else { throw BootstrapError() }
                secret = value
            } else {
                guard let password else { throw BootstrapError() }
                secret = password
            }
            try AccountValidation.newPassword(secret)
            return (try AccountValidation.username(username), secret)
        } catch {
            throw BootstrapError()
        }
    }
}

struct BootstrapError: Error, CustomStringConvertible {
    var description: String { "Bootstrap admin credentials are missing, unreadable, or invalid." }
}
