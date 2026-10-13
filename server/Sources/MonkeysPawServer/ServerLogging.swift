import Foundation
import Logging
import MonkeysPawCore

public enum ServerLogging {
    /// Every server-owned logger uses the same serialized, JSON stdout sink.
    public static func logger(level: Logger.Level? = nil) -> Logger {
        makeLogger(level: level ?? logLevel(environment: ProcessInfo.processInfo.environment), sink: StandardOutputLogSink.shared.write)
    }

    static func logLevel(environment: [String: String]) -> Logger.Level {
        let value = environment["MONKEYSPAW_LOG_LEVEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "warn" { return .warning }
        return value.flatMap(Logger.Level.init(rawValue:)) ?? .info
    }

    static func makeLogger(
        level: Logger.Level, clock: @escaping @Sendable () -> Date = { Date() },
        sink: @escaping @Sendable (Data) -> Void
    ) -> Logger {
        Logger(label: "monkeyspaw-server") { _ in JSONLogHandler(logLevel: level, clock: clock, sink: sink) }
    }
}

private struct JSONLogHandler: LogHandler {
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    let clock: @Sendable () -> Date
    let sink: @Sendable (Data) -> Void

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var combined = metadata
        if let provided = metadataProvider?.get() { combined.merge(provided) { _, new in new } }
        if let extra = event.metadata { combined.merge(extra) { _, new in new } }
        let record = Record(at: ServerTimestamp.string(clock()), level: event.level.rawValue,
                            message: Self.safeMessage(event.message.description), fields: Self.safeFields(combined))
        guard var bytes = try? JSONEncoder().encode(record) else { return }
        bytes.append(10)
        sink(bytes)
    }

    private struct Record: Encodable {
        let at: String
        let level: String
        let message: String
        let fields: [String: String]
    }

    private static func safeMessage(_ message: String) -> String {
        switch message {
        case "Account mutation committed", "API request failed", "Healthcheck configuration invalid",
             "Shutting down", "Server channel error", "HTTP parse error, closing connection",
             "Idle read timeout, so close channel", "Unrecognised Error":
            return message
        default:
            // Framework diagnostics may interpolate a credential, path or error body.
            if message.hasPrefix("Server started and listening on ") { return "Server started" }
            if message.hasPrefix("Server State: ") { return "Server state changed" }
            return "Server event"
        }
    }

    private static func safeFields(_ metadata: Logger.Metadata) -> [String: String] {
        var fields: [String: String] = [:]
        for key in ["action", "actor_id", "target_id", "method", "status", "code"] {
            guard case .string(let value) = metadata[key] else { continue }
            let valid: Bool
            switch key {
            case "action": valid = AuditAction(rawValue: value) != nil
            case "actor_id": valid = value == "operator" || ULID(value)?.rawValue == value
            case "target_id": valid = ULID(value)?.rawValue == value
            case "method": valid = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"].contains(value)
            case "status": valid = Int(value).map { (100...599).contains($0) && String($0) == value } ?? false
            case "code": valid = SyncAPI.FailureCode(rawValue: value) != nil
            default: valid = false
            }
            if valid { fields[key] = value }
        }
        return fields
    }
}

// NSLock serializes the complete record write across all server loggers.
private final class StandardOutputLogSink: @unchecked Sendable {
    static let shared = StandardOutputLogSink()
    private let lock = NSLock()

    func write(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(bytes)
    }
}
