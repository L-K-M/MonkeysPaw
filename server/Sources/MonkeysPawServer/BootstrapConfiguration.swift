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
                let url = URL(fileURLWithPath: passwordFile).resolvingSymlinksInPath()
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                // Reject special files before opening, since opening a FIFO can block.
                guard properties.isRegularFile == true else { throw BootstrapError.invalidCredentials }
                let limit = ServerLimits.bootstrapSecretFileMaximumBytes
                if let size = properties.fileSize, size > limit { throw BootstrapError.secretFileTooLarge }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                // Also bound the read if the file grows after its size was checked.
                var data = try file.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw BootstrapError.secretFileTooLarge }
                // Secret files commonly have one terminal line ending; spaces are significant.
                if data.last == 10 {
                    data.removeLast()
                    if data.last == 13 { data.removeLast() }
                }
                guard let value = String(data: data, encoding: .utf8) else { throw BootstrapError.invalidCredentials }
                secret = value
            } else {
                guard let password else { throw BootstrapError.invalidCredentials }
                secret = password
            }
            try AccountValidation.newPassword(secret)
            return (try AccountValidation.username(username), secret)
        } catch let error as BootstrapError {
            throw error
        } catch {
            throw BootstrapError.invalidCredentials
        }
    }
}

enum BootstrapError: Error, Equatable, CustomStringConvertible {
    case invalidCredentials
    case secretFileTooLarge

    var description: String {
        switch self {
        case .invalidCredentials: "Bootstrap admin credentials are missing, unreadable, or invalid."
        case .secretFileTooLarge: "Bootstrap admin password file exceeds \(ServerLimits.bootstrapSecretFileMaximumBytes) bytes."
        }
    }
}
