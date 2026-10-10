import Foundation

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}
