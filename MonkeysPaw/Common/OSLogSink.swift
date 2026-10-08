import MonkeysPawCore
import os

/// Only safe metadata reaches this sink; callers follow Core's LogSink contract.
struct OSLogSink: LogSink {
    private let logger = Logger(subsystem: AppIdentity.macOSBundleID, category: "app")

    func write(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}
