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

    static let logErrorTypeMaxBytes = 128

    static let defaultDataDirectory = "/data"
    static let databaseFilename = "monkeyspaw.db"
    static let databaseBusyTimeoutMilliseconds = 5_000
    static let databasePoolTimeoutSeconds: Int64 = 10
    static let usernameMaxBytes = 64
    static let defaultAdminUsername = "admin"
    static let bcryptCost: UInt8 = 12
    static let passwordMinimumLength = 12
    static let passwordMaximumBytes = 72
    static let bootstrapSecretFileMaximumBytes = 4 * 1_024
    public static let operatorPasswordInputMaximumBytes = bootstrapSecretFileMaximumBytes
    static let deviceTokenEncodedBytes = 43
    static let inviteMaximumLifetimeSeconds: Int64 = 7 * 24 * 60 * 60
    static let deviceSeenUpdateInterval: TimeInterval = 5 * 60
    static let loginFreeAttempts = 5
    static let loginInitialLock: TimeInterval = 30
    static let loginMaximumLock: TimeInterval = 15 * 60
    static let loginDecayInterval: TimeInterval = 15 * 60
    // Five doublings of 30 seconds reach the capped 15-minute delay.
    static let loginMaximumFailures = loginFreeAttempts + 5
    static let loginConcurrentRequests = 4
    static let trustedProxyMaxEntries = 64
    static let trustedProxyConfigurationMaxBytes = 4_096
    static let forwardedForMaxBytes = 8_192
    static let forwardedForMaxHops = 64
    static let ipAddressMaxBytes = 45
    static let revisionsPerPrompt = 200
    static let changeRetentionDays = 90
    static let retentionBatchSize = 100
    static let retentionInterval: Duration = .seconds(60 * 60)
    static let syncPageMaxItems = 200
    static let syncPageBytes = 8 * 1_024 * 1_024
    /// Bound transaction work even when a long run collapses to one emitted item.
    static let syncPageMaxChanges = 1_000
    static let snapshotLifetimeSeconds = 15 * 60
    static let snapshotSigningKeyBytes = 32
    static let snapshotMaxBytes = 64 * 1_024 * 1_024
    static let snapshotTotalMaxBytes = 256 * 1_024 * 1_024
}
