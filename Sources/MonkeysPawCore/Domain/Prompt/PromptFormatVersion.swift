/// A positive format integer with no machine-word ceiling. Future versions
/// remain identifiable/read-only even when their value cannot fit Swift Int.
public struct PromptFormatVersion: Equatable, Sendable {
    public let decimalValue: String
    public static let current = PromptFormatVersion(decimalValue: String(Limits.promptFormatVersion))!

    public init?(_ value: Int) {
        guard value > 0 else { return nil }
        decimalValue = String(value)
    }

    var isFuture: Bool {
        let current = Self.current.decimalValue
        return decimalValue.count > current.count
            || (decimalValue.count == current.count && decimalValue > current)
    }

    init?(decimalValue: String) {
        guard !decimalValue.isEmpty, decimalValue.utf8.allSatisfy({ (48...57).contains($0) }),
              decimalValue.first != "0" else { return nil }
        self.decimalValue = decimalValue
    }
}
