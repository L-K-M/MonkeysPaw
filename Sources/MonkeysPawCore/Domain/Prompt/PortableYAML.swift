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

    private static let decimalChunkRadix: UInt64 = 1_000_000_000
    private static let decimalChunkDigits = 9
    private static let radixProductThreshold = 128

    private static func decimalInteger(_ string: String) -> String {
        let negative = string.first == "-"
        let unsigned = string.first == "-" || string.first == "+" ? String(string.dropFirst()) : string
        let bitsPerDigit: Int
        if unsigned.hasPrefix("0x") {
            bitsPerDigit = 4
        } else if unsigned.hasPrefix("0o") {
            bitsPerDigit = 3
        } else {
            let value = unsigned.drop(while: { $0 == "0" })
            return value.isEmpty ? "0" : (negative ? "-" : "") + value
        }

        // Align groups from the right. Balanced composition avoids repeatedly
        // scanning a growing decimal value for every group of input digits.
        let digits = Array(unsigned.dropFirst(2).utf8.drop(while: { $0 == 48 }))
        let groupWidth = UInt32.bitWidth / bitsPerDigit
        let radix = UInt64(1) << bitsPerDigit
        var values = [[UInt64]]()
        var group: UInt64 = 0
        var groupDigits = 0
        var width = digits.count % groupWidth
        if width == 0 { width = groupWidth }
        for byte in digits {
            let digit: UInt64
            switch byte {
            case 48...57: digit = UInt64(byte - 48)
            case 65...70: digit = UInt64(byte - 55)
            case 97...102: digit = UInt64(byte - 87)
            default: return string
            }
            guard digit < radix else { return string }
            group = (group << bitsPerDigit) | digit
            groupDigits += 1
            if groupDigits == width {
                values.append(radixChunks(group))
                group = 0
                groupDigits = 0
                width = groupWidth
            }
        }

        var power = radixChunks(UInt64(1) << (groupWidth * bitsPerDigit))
        while values.count > 1 {
            var combined = [[UInt64]]()
            combined.reserveCapacity((values.count + 1) / 2)
            var index = 0
            if values.count % 2 == 1 {
                combined.append(values[0])
                index = 1
            }
            while index < values.count {
                var value = radixProduct(values[index], power)
                addRadixChunks(values[index + 1], to: &value)
                combined.append(value)
                index += 2
            }
            values = combined
            if values.count > 1 { power = radixProduct(power, power) }
        }

        let decimal = values.first ?? []
        var value = String(decimal.last ?? 0)
        value.reserveCapacity(decimal.count * decimalChunkDigits)
        for chunk in decimal.dropLast().reversed() {
            let text = String(chunk)
            value += String(repeating: "0", count: decimalChunkDigits - text.utf8.count) + text
        }
        return value == "0" ? value : (negative ? "-" : "") + value
    }

    // These little-endian decimal chunks are private to radix conversion.
    // Empty represents zero; the highest stored chunk is always nonzero.
    private static func radixChunks(_ value: UInt64) -> [UInt64] {
        var remaining = value
        var chunks = [UInt64]()
        while remaining > 0 {
            chunks.append(remaining % decimalChunkRadix)
            remaining /= decimalChunkRadix
        }
        return chunks
    }

    private static func addRadixChunks(_ addend: [UInt64], to value: inout [UInt64], offset: Int = 0) {
        guard !addend.isEmpty else { return }
        // One spare zero absorbs any final carry. Buffers cannot resize while
        // borrowed, and every target stays within this allocated count.
        let count = max(value.count, offset + addend.count) + 1
        value += repeatElement(0, count: count - value.count)
        let divisor = decimalChunkRadix
        addend.withUnsafeBufferPointer { input in
            value.withUnsafeMutableBufferPointer { output in
                let source = input.baseAddress!, target = output.baseAddress!
                let inputCount = input.count
                var carry: UInt64 = 0
                var index = 0
                while index < inputCount || carry > 0 {
                    let position = offset + index
                    let sum = target[position] + (index < inputCount ? source[index] : 0) + carry
                    carry = sum >= divisor ? 1 : 0
                    target[position] = sum - carry * divisor
                    index += 1
                }
            }
        }
        while value.last == 0 { value.removeLast() }
    }

    private static func subtractRadixChunks(_ subtrahend: [UInt64], from value: inout [UInt64]) {
        guard !subtrahend.isEmpty else { return }
        var borrow: UInt64 = 0
        let divisor = decimalChunkRadix
        subtrahend.withUnsafeBufferPointer { input in
            value.withUnsafeMutableBufferPointer { output in
                let source = input.baseAddress!, target = output.baseAddress!
                let inputCount = input.count, count = output.count
                var index = 0
                while index < count {
                    let amount = (index < inputCount ? source[index] : 0) + borrow
                    let chunk = target[index]
                    borrow = chunk < amount ? 1 : 0
                    target[index] = chunk + borrow * divisor - amount
                    index += 1
                }
            }
        }
        // Only nonnegative cross products are subtracted below.
        assert(borrow == 0)
        while value.last == 0 { value.removeLast() }
    }

    /// Balanced radix products use Karatsuba above the small-product threshold.
    /// The base case's product + existing chunk + carry is below (10^9)^2,
    /// so checked UInt64 arithmetic preserves every carry without overflow.
    private static func radixProduct(_ lhs: [UInt64], _ rhs: [UInt64]) -> [UInt64] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }
        if min(lhs.count, rhs.count) <= radixProductThreshold {
            var result = [UInt64](repeating: 0, count: lhs.count + rhs.count)
            let divisor = decimalChunkRadix
            lhs.withUnsafeBufferPointer { leftBuffer in
                rhs.withUnsafeBufferPointer { rightBuffer in
                    result.withUnsafeMutableBufferPointer { chunks in
                        let leftWords = leftBuffer.baseAddress!, rightWords = rightBuffer.baseAddress!
                        let words = chunks.baseAddress!
                        let leftCount = leftBuffer.count, rightCount = rightBuffer.count
                        var leftIndex = 0
                        while leftIndex < leftCount {
                            let left = leftWords[leftIndex]
                            var carry: UInt64 = 0
                            var rightIndex = 0
                            while rightIndex < rightCount {
                                let index = leftIndex + rightIndex
                                let product = left * rightWords[rightIndex] + words[index] + carry
                                carry = product / divisor
                                words[index] = product - carry * divisor
                                rightIndex += 1
                            }
                            // Earlier rows end one position before this carry slot.
                            words[leftIndex + rightCount] = carry
                            leftIndex += 1
                        }
                    }
                }
            }
            while result.last == 0 { result.removeLast() }
            return result
        }

        let split = max(lhs.count, rhs.count) / 2
        let leftLow = Array(lhs.prefix(split)), leftHigh = Array(lhs.dropFirst(split))
        let rightLow = Array(rhs.prefix(split)), rightHigh = Array(rhs.dropFirst(split))
        let low = radixProduct(leftLow, rightLow)
        let high = radixProduct(leftHigh, rightHigh)
        var leftSum = leftLow, rightSum = rightLow
        addRadixChunks(leftHigh, to: &leftSum)
        addRadixChunks(rightHigh, to: &rightSum)
        var middle = radixProduct(leftSum, rightSum)
        subtractRadixChunks(low, from: &middle)
        subtractRadixChunks(high, from: &middle)
        var result = low
        addRadixChunks(middle, to: &result, offset: split)
        addRadixChunks(high, to: &result, offset: split * 2)
        return result
    }
}
