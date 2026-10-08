import Foundation

/// A portable destination for diagnostics, since os.Logger is Apple-only.
///
/// Never log secrets (keys, tokens, passwords), prompt content, field values,
/// or provider/tool error bodies (§12). Callers log only safe metadata.
public protocol LogSink {
    /// Implementations must serialize mutable state for concurrent callers.
    func write(_ level: LogLevel, _ message: String)
}

public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Writes `monkeyspaw <level>: <message>` and a newline to standard error.
///
/// stderr leaves stdout available for machine-readable output. A shared lock
/// keeps whole events together even when separate sinks write concurrently.
public struct StandardErrorLog: LogSink {
    private static let lock = NSLock()
    private let output: FileHandle

    public init() {
        self.init(output: .standardError)
    }

    // Tests capture bytes without redirecting process-wide stderr.
    init(output: FileHandle) {
        self.output = output
    }

    public func write(_ level: LogLevel, _ message: String) {
        let line = Data("\(AppIdentity.binaryName) \(level.rawValue): \(message)\n".utf8)

        Self.lock.lock()
        defer { Self.lock.unlock() }

        output.write(line)
    }
}
