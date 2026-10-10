import Foundation

public struct SystemClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}
