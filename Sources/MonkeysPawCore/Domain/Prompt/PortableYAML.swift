import Foundation
import Yams

/// Scalar schema validation operates on composed nodes, never on raw YAML.
/// A marker resolver keeps implicit plain scalars distinct from explicit !!str,
/// even when Yams resolves mapping-key tags during its duplicate check.
enum PortableYAML {
    private static let implicitScalar = Tag.Name(rawValue: "tag:monkeyspaw,2026:implicit-scalar")
    static let syntaxResolver = Resolver.basic.appending(try! Resolver.Rule(implicitScalar, "^[\\s\\S]*$"))
    private static let coreResolver: Resolver = {
        let rules: [(Tag.Name, String)] = [
            (.null, "^(?:null|Null|NULL|~|)$"),
            (.bool, "^(?:true|True|TRUE|false|False|FALSE)$"),
            (.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$"),
            (.float, "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$")
        ]
        return rules.reduce(Resolver.basic) { $0.appending(try! Resolver.Rule($1.0, $1.1)) }
    }()
    private static let legacyBooleans: Set<String> = ["y", "yes", "n", "no", "on", "off"]

    enum Position { case key, value }

    static func normalize(_ node: Node, issues: inout [PromptIssue], position: Position = .value) -> Node {
        let location = location(node)
        if node.anchor != nil {
            issues.append(PromptIssue(.anchorOrAlias, at: location))
            // Yams composes aliases as copies of anchored nodes. Do not traverse
            // this invalid subtree and expand an alias DAG exponentially.
            return Node("null", Tag(.null), .plain)
        }
        switch node {
        case .alias:
            issues.append(PromptIssue(.anchorOrAlias, at: location))
            return Node("null", Tag(.null), .plain)
        case .scalar(let scalar):
            let originalTag = node.tag.rawValue
            let implicit = originalTag == implicitScalar.rawValue
            let legacy = legacyTag(scalar.string)
            let core = coreTag(scalar.string)
            let tag = implicit ? legacy : Tag.Name(rawValue: originalTag)

            if position == .key && tag == .merge {
                issues.append(PromptIssue(.mergeKey, at: location))
            } else if implicit {
                if legacy != core || legacyBooleans.contains(scalar.string.lowercased())
                    || (tag == .bool && scalar.string != "true" && scalar.string != "false")
                    || hasLeadingZero(scalar.string) {
                    issues.append(PromptIssue(.nonPortableScalar, at: location))
                }
            } else if ![Tag.Name.str, .null, .bool, .int, .float].contains(tag) {
                issues.append(PromptIssue(.nonPortableTag, at: location))
            } else if tag != .str && !validExplicitScalar(scalar.string, tag: tag) {
                issues.append(PromptIssue(.nonPortableScalar, at: location))
            }

            return .scalar(.init(scalar.string, Tag(tag), scalar.style, scalar.mark))
        case .sequence(let sequence):
            if node.tag.rawValue != Tag.Name.seq.rawValue {
                issues.append(PromptIssue(.nonPortableTag, at: location))
            }
            let nodes = sequence.map { normalize($0, issues: &issues) }
            return .sequence(.init(nodes, Tag(.seq), sequence.style, sequence.mark))
        case .mapping(let mapping):
            if node.tag.rawValue != Tag.Name.map.rawValue {
                issues.append(PromptIssue(.nonPortableTag, at: location))
            }
            var keys = Set<Data>()
            var pairs = [(Node, Node)]()
            for pair in mapping {
                let key = normalize(pair.key, issues: &issues, position: .key)
                if !keys.insert(Data(keyIdentity(key).utf8)).inserted {
                    issues.append(PromptIssue(.duplicateKey, at: self.location(pair.key)))
                }
                let value = normalize(pair.value, issues: &issues)
                pairs.append((key, value))
            }
            return .mapping(.init(pairs, Tag(.map), mapping.style, mapping.mark))
        }
    }

    static func canonical(_ node: Node) -> Node {
        switch node {
        case .scalar(let scalar):
            let tag = Tag.Name(rawValue: node.tag.rawValue)
            var value = scalar.string
            var style = Node.Scalar.Style.plain
            if tag == .str {
                let sensitive = legacyTag(value) != .str || coreTag(value) != .str
                    || legacyBooleans.contains(value.lowercased())
                style = sensitive || value.contains("\n") || value.contains("\r") ? .doubleQuoted : .any
            } else if tag == .null {
                value = "null"
            } else if tag == .float && coreTag(value) == .int {
                // The emitter omits scalar tags. Keep an explicit !!float 1 a
                // float, and a quoted !!int "1" an integer on the next parse.
                value += ".0"
            } else if tag == .float && legacyTag(value) != .float {
                // Explicit tags can make an otherwise divergent spelling a
                // portable value. Emit a shared spelling before omitting tags.
                value = decimalFloat(value)
                if value == "0" { value = "0.0" }
            }
            return Node(value, Tag(tag), style)
        case .sequence(let sequence):
            return Node(sequence.map(canonical), Tag(.seq), .block)
        case .mapping(let mapping):
            return Node(mapping.map { (canonical($0.key), canonical($0.value)) }, Tag(.map), .block)
        case .alias:
            // Invalid documents never reach the writer.
            return node
        }
    }

    static func location(_ node: Node) -> PromptIssueLocation? {
        node.mark.map { .frontMatter(line: $0.line + 1, column: $0.column) }
    }

    static func string(_ node: Node?) -> String? {
        guard let node, node.tag.rawValue == Tag.Name.str.rawValue else { return nil }
        return node.scalar?.string
    }

    static func boolean(_ node: Node?) -> Bool? {
        guard let node, node.tag.rawValue == Tag.Name.bool.rawValue else { return nil }
        switch node.scalar?.string {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func formatVersion(_ node: Node?) -> PromptFormatVersion? {
        guard let node, node.tag.rawValue == Tag.Name.int.rawValue, let scalar = node.scalar else { return nil }
        guard validExplicitScalar(scalar.string, tag: .int) else { return nil }
        return PromptFormatVersion(decimalValue: decimalInteger(scalar.string))
    }

    private static func legacyTag(_ string: String) -> Tag.Name {
        Resolver.default.resolveTag(of: Node(string))
    }

    private static func coreTag(_ string: String) -> Tag.Name {
        coreResolver.resolveTag(of: Node(string))
    }

    private static func hasLeadingZero(_ string: String) -> Bool {
        let unsigned = string.first == "-" || string.first == "+" ? string.dropFirst() : string[...]
        return unsigned.count > 1 && unsigned.first == "0"
            && unsigned.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validExplicitScalar(_ string: String, tag: Tag.Name) -> Bool {
        if tag == .bool { return string == "true" || string == "false" }
        if tag == .int { return coreTag(string) == .int && !hasLeadingZero(string) }
        if tag == .null { return coreTag(string) == .null }
        // Explicit float integers are decimal, not hex/octal integer lexemes.
        return coreTag(string) == .float || (coreTag(string) == .int
            && !string.hasPrefix("0x") && !string.hasPrefix("0o") && !hasLeadingZero(string))
    }

    /// YAML uniqueness compares typed values, not scalar style or mapping order.
    /// Length framing keeps composite key identities unambiguous.
    private static func keyIdentity(_ node: Node) -> String {
        switch node {
        case .scalar(let scalar):
            let tag = node.tag.rawValue
            var value = scalar.string
            if tag == Tag.Name.int.rawValue { value = decimalInteger(value) }
            if tag == Tag.Name.float.rawValue && validExplicitScalar(value, tag: .float) {
                value = decimalFloat(value)
            }
            if tag == Tag.Name.null.rawValue { value = "null" }
            return framed(tag) + framed(value)
        case .sequence(let sequence): return "sequence" + sequence.map { framed(keyIdentity($0)) }.joined()
        case .mapping(let mapping):
            let pairs = mapping.map { framed(keyIdentity($0.key)) + framed(keyIdentity($0.value)) }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return "mapping" + pairs.map(framed).joined()
        case .alias: return "alias"
        }
    }

    private static func framed(_ value: String) -> String { "\(value.utf8.count):\(value)" }

    /// Compare float keys as exact decimal values. Converting to Double would
    /// collapse distinct high-precision values or overflow large finite keys.
    private static func decimalFloat(_ string: String) -> String {
        let lower = string.lowercased()
        if lower == ".nan" { return ".nan" }
        if lower.hasSuffix(".inf") { return lower.first == "-" ? "-.inf" : ".inf" }
        let negative = lower.first == "-"
        let unsigned = lower.first == "-" || lower.first == "+" ? String(lower.dropFirst()) : lower
        let parts = unsigned.split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fractionCount = mantissa.count == 2 ? mantissa[1].count : 0
        let digits = mantissa.joined().drop(while: { $0 == "0" })
        guard !digits.isEmpty else { return "0" }
        let significant = String(digits.reversed().drop(while: { $0 == "0" }).reversed())
        let adjustment = digits.count - significant.count - fractionCount
        let exponent = adjustedExponent(parts.count == 2 ? String(parts[1]) : "0", by: adjustment)
        return (negative ? "-" : "") + significant + "e" + exponent
    }

    private static func adjustedExponent(_ string: String, by adjustment: Int) -> String {
        let normalized = decimalInteger(string)
        let negative = normalized.first == "-"
        let magnitude = Array((negative ? String(normalized.dropFirst()) : normalized).utf8)
        let delta = Array(String(abs(adjustment)).utf8)
        var result: [UInt8]
        let resultNegative: Bool
        if negative == (adjustment < 0) {
            result = addMagnitudes(magnitude, delta)
            resultNegative = negative
        } else if magnitude.count > delta.count || (magnitude.count == delta.count && !magnitude.lexicographicallyPrecedes(delta)) {
            result = subtractMagnitudes(magnitude, delta)
            resultNegative = negative
        } else {
            result = subtractMagnitudes(delta, magnitude)
            resultNegative = adjustment < 0
        }
        while result.count > 1 && result.first == 48 { result.removeFirst() }
        let value = String(decoding: result, as: UTF8.self)
        return resultNegative && value != "0" ? "-" + value : value
    }

    private static func addMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        let left = Array(lhs.reversed()), right = Array(rhs.reversed())
        var output = [UInt8]()
        var carry = 0
        for index in 0..<max(left.count, right.count) {
            let sum = (index < left.count ? Int(left[index] - 48) : 0)
                + (index < right.count ? Int(right[index] - 48) : 0) + carry
            output.append(UInt8(sum % 10) + 48)
            carry = sum / 10
        }
        if carry > 0 { output.append(UInt8(carry) + 48) }
        return output.reversed()
    }

    private static func subtractMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        let left = Array(lhs.reversed()), right = Array(rhs.reversed())
        var output = [UInt8]()
        var borrow = 0
        for index in left.indices {
            var difference = Int(left[index] - 48) - (index < right.count ? Int(right[index] - 48) : 0) - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 { difference += 10 }
            output.append(UInt8(difference) + 48)
        }
        return output.reversed()
    }

    private static func decimalInteger(_ string: String) -> String {
        let negative = string.first == "-"
        let unsigned = string.first == "-" || string.first == "+" ? String(string.dropFirst()) : string
        var digits = unsigned
        let base: Int
        if unsigned.hasPrefix("0x") {
            base = 16
            digits = String(unsigned.dropFirst(2))
        } else if unsigned.hasPrefix("0o") {
            base = 8
            digits = String(unsigned.dropFirst(2))
        } else {
            let value = unsigned.drop(while: { $0 == "0" })
            return value.isEmpty ? "0" : (negative ? "-" : "") + value
        }
        // Arbitrary-size integer keys stay comparable without imposing a new
        // metadata number bound or constructing untyped Foundation values.
        var decimal: [Int] = [0]
        for byte in digits.lowercased().utf8 {
            let digit = byte >= 97 ? Int(byte - 87) : Int(byte) - 48
            guard (0..<base).contains(digit) else { return string }
            var carry = digit
            for index in decimal.indices {
                let value = decimal[index] * base + carry
                decimal[index] = value % 10
                carry = value / 10
            }
            while carry > 0 { decimal.append(carry % 10); carry /= 10 }
        }
        let value = decimal.reversed().map(String.init).joined()
        return value == "0" ? value : (negative ? "-" : "") + value
    }
}
