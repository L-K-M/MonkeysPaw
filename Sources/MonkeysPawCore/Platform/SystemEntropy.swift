public struct SystemEntropy: EntropySource {
    public init() {}

    public func bytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw SystemEntropyError.invalidCount }

        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        let bytesPerDraw = MemoryLayout<UInt64>.size

        while bytes.count < count {
            var draw = generator.next()
            for _ in 0..<min(bytesPerDraw, count - bytes.count) {
                bytes.append(UInt8(truncatingIfNeeded: draw))
                draw >>= 8
            }
        }

        return bytes
    }
}

public enum SystemEntropyError: String, Error, Sendable {
    case invalidCount
}
