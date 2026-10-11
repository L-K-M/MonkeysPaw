/// The composition root supplies MONKEYSPAW_LOG; Core never reads the environment.
public struct LogLevelPolicy: Sendable {
    private let threshold: LogLevel

    public init(environmentValue: String? = nil) {
        switch environmentValue?.lowercased() {
        case "debug": threshold = .debug
        case "info": threshold = .info
        case "warning", "warn": threshold = .warning
        case "error": threshold = .error
        default: threshold = .warning
        }
    }

    public func allows(_ level: LogLevel) -> Bool {
        level.priority >= threshold.priority
    }
}

private extension LogLevel {
    var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}
