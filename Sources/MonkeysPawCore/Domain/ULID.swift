import Foundation

/// A validated 128-bit ULID. Parsing is case-insensitive; output is uppercase.
public struct ULID: Hashable, Sendable {
    public let rawValue: String
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private static let maxTimestamp: UInt64 = (1 << 48) - 1

    public init?(_ value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == 26 else { return nil }
        let upper = bytes.map { (97...122).contains($0) ? $0 - 32 : $0 }
        guard upper[0] <= 55, upper.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        rawValue = String(decoding: upper, as: UTF8.self)
    }

    /// No clock or entropy source is read here. The saving service supplies both.
    /// This encoder has no mutable/monotonic state and never assigns document ids.
    public static func generate(at date: Date, entropy: [UInt8]) throws -> ULID {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard milliseconds.isFinite, milliseconds >= 0,
              milliseconds <= Double(maxTimestamp) else {
            throw ULIDGenerationError.invalidTimestamp
        }
        guard entropy.count == 10 else { throw ULIDGenerationError.invalidEntropyLength }

        var timestamp = UInt64(milliseconds)
        var bytes = Array(repeating: UInt8(0), count: 26)
        for index in (0..<10).reversed() {
            bytes[index] = alphabet[Int(timestamp & 31)]
            timestamp >>= 5
        }
        // Each of the remaining sixteen characters consumes five entropy bits.
        for index in 0..<16 {
            var value: UInt8 = 0
            for bit in 0..<5 {
                let offset = index * 5 + bit
                value = (value << 1) | ((entropy[offset / 8] >> (7 - offset % 8)) & 1)
            }
            bytes[index + 10] = alphabet[Int(value)]
        }
        return ULID(String(decoding: bytes, as: UTF8.self))!
    }
}

public enum ULIDGenerationError: String, Error, Sendable {
    case invalidTimestamp
    case invalidEntropyLength
}
