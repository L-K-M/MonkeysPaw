import Foundation

public enum ServerLimits {
    /// Listen on the container network; deployment controls published ports (§8.6).
    static let defaultHTTPHost = "0.0.0.0"

    /// The internal HTTP port exposed by the server image (§8.6).
    static let defaultHTTPPort = 8_080

    /// Reject zero and out-of-range ports before serving or checking health.
    static let httpPortRange = 1...Int(UInt16.max)

    /// Bound Docker health probes so an unresponsive server cannot hang them.
    public static let healthcheckTimeout: TimeInterval = 5

    static let defaultDataDirectory = "/data"
    static let databaseFilename = "monkeyspaw.db"
    static let databaseBusyTimeoutMilliseconds = 5_000
    static let databasePoolTimeoutSeconds: Int64 = 10
    static let usernameMaxBytes = 64
    static let defaultAdminUsername = "admin"
    static let bcryptCost: UInt8 = 12
    static let passwordMinimumLength = 12
    static let passwordMaximumBytes = 72
    static let deviceTokenEncodedBytes = 43
    static let deviceSeenUpdateInterval: TimeInterval = 5 * 60
    static let snapshotLifetimeSeconds = 15 * 60
    static let snapshotMaxBytes = 64 * 1_024 * 1_024
    static let snapshotTotalMaxBytes = 256 * 1_024 * 1_024
}
