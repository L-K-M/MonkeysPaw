public struct SystemEntropy: EntropySource {
    public init() {}

    public func bytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw SystemEntropyError.invalidCount }
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

public enum SystemEntropyError: String, Error, Sendable {
    case invalidCount
}
