/// A path spelling whose identity and order use exact UTF-8 bytes. This value
/// does not validate or normalize paths; filesystem boundaries still validate.
public struct RelativePath: Hashable, Comparable, Sendable, ExpressibleByStringLiteral {
    public let string: String

    public init(_ string: String) { self.string = string }
    public init(stringLiteral value: String) { self.init(value) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.string.utf8.elementsEqual(rhs.string.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        // String hashing uses canonical equivalence and would merge byte-distinct twins.
        hasher.combine(string.utf8.count)
        for byte in string.utf8 { hasher.combine(byte) }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8)
    }
}
