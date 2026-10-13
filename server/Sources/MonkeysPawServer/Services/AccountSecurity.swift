import Crypto
import Foundation
import HummingbirdBcrypt
import MonkeysPawCore
import NIOPosix

enum AccountError: Error, Equatable {
    case unauthorized
    case notFound
    case malformedRequest
}

enum AccountValidation {
    static func username(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        guard let first = bytes.first, alphanumeric(first), bytes.count <= ServerLimits.usernameMaxBytes,
              bytes.allSatisfy({ alphanumeric($0) || [45, 46, 95].contains($0) }) else {
            throw AccountError.malformedRequest
        }
        return String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    static func newPassword(_ value: String) throws {
        guard value.unicodeScalars.count >= ServerLimits.passwordMinimumLength,
              usablePassword(value) else { throw AccountError.malformedRequest }
    }

    static func usablePassword(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= ServerLimits.passwordMaximumBytes && !value.utf8.contains(0)
    }

    static func dto(_ value: some Encodable) throws {
        do { _ = try JSONEncoder().encode(value) } catch { throw AccountError.malformedRequest }
    }
}

protocol PasswordHashing: Sendable {
    func hash(_ password: String) async throws -> String
    func verify(_ password: String, hash: String) async throws -> Bool
}

struct BcryptPasswordHasher: PasswordHashing {
    // Public fixed work factor/salt, never an account credential. Unknown users
    // still execute one cost-12 bcrypt verification, including invalid input.
    static let dummyHash = "$2b$12$LQv3c1yqBWVHxkd0LHAkCOY6TtxLwJRo6L44MvJLL.UJujjYhSMZy"

    func hash(_ password: String) async throws -> String {
        try AccountValidation.newPassword(password)
        return try await NIOThreadPool.singleton.runIfActive {
            Bcrypt.hash(password, cost: ServerLimits.bcryptCost)
        }
    }

    func verify(_ password: String, hash: String) async throws -> Bool {
        let usable = AccountValidation.usablePassword(password)
        return try await NIOThreadPool.singleton.runIfActive {
            let matches = Bcrypt.verify(usable ? password : "invalid-password", hash: usable ? hash : Self.dummyHash)
            return usable && matches
        }
    }
}

struct DeviceToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    var description: String { "DeviceToken(<redacted>)" }
    var debugDescription: String { description }

    static func generate() -> Self {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let value = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Self(value: value)
    }

    var hash: String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        value.utf8.count == ServerLimits.deviceTokenEncodedBytes && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

enum ServerTimestamp {
    static func string(_ date: Date) -> String { formatter.string(date) }
    static func date(_ value: String) -> Date? { formatter.date(value) }

    private static let formatter = Formatter()

    static func id(at date: Date) throws -> String {
        let entropy = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0.prefix(10)) }
        return try ULID.generate(at: date, entropy: entropy).rawValue
    }

    // Foundation's formatter is not Sendable; keep its cached instance behind a lock.
    private final class Formatter: @unchecked Sendable {
        private let lock = NSLock()
        private let value: ISO8601DateFormatter

        init() {
            value = ISO8601DateFormatter()
            value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            value.timeZone = TimeZone(secondsFromGMT: 0)
        }

        func string(_ date: Date) -> String {
            lock.withLock { value.string(from: date) }
        }

        func date(_ text: String) -> Date? {
            lock.withLock { value.date(from: text) }
        }
    }
}
