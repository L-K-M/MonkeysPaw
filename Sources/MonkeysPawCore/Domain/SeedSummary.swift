public struct SeedSummary: Equatable, Sendable {
    public let seededCount: Int
    /// Paths already occupied at publication time, without any replacement.
    /// A library initially containing a prompt returns zero for both counts.
    public let skippedExistingCount: Int
}
