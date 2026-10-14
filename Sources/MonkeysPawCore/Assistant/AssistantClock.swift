import Foundation

/// Internal clock seam for deterministic protocol envelopes and Retry-After tests.
struct AssistantClock: Sendable {
    let monotonic: @Sendable () -> ContinuousClock.Instant
    let utc: @Sendable () -> Date

    static let live = AssistantClock(monotonic: { ContinuousClock.now }, utc: { Date() })
}
