public enum TemplateToken: Equatable, Sendable {
    case literal(String)
    case escapedOpener
    case placeholder(String)
}

public enum BuiltinName: String, Sendable {
    case clipboard
    case date
    case time
}

/// A single pass over UTF-8 bytes preserves literal text without normalization.
public struct Template: Equatable, Sendable {
    public let tokens: [TemplateToken]
    public let names: [String]
    public let issues: [PromptIssue]
    public var builtins: [BuiltinName] { names.compactMap(BuiltinName.init(rawValue:)) }
    let firstUseOffsets: [String: Int]

    public static func parse(_ body: String) -> Template {
        guard body.utf8.count <= Limits.maxPromptBytes else {
            return Template(tokens: [.literal(body)], names: [], issues: [PromptIssue(.sourceTooLarge)], firstUseOffsets: [:])
        }
        let bytes = Array(body.utf8)
        var tokens = [TemplateToken]()
        var names = [String]()
        var used = Set<String>()
        var issues = [PromptIssue]()
        var offsets = [String: Int]()
        var position = 0
        var literalStart = 0

        func literal(until end: Int) {
            guard end > literalStart else { return }
            tokens.append(.literal(String(decoding: bytes[literalStart..<end], as: UTF8.self)))
        }

        while position < bytes.count {
            if bytes[position] == 92, position + 2 < bytes.count,
               bytes[position + 1] == 123, bytes[position + 2] == 123 {
                literal(until: position)
                tokens.append(.escapedOpener)
                position += 3
                literalStart = position
                continue
            }
            guard bytes[position] == 123, position + 1 < bytes.count, bytes[position + 1] == 123 else {
                position += 1
                continue
            }

            let opener = position
            var end = position + 2
            while end + 1 < bytes.count, !(bytes[end] == 125 && bytes[end + 1] == 125) { end += 1 }
            guard end + 1 < bytes.count else {
                issues.append(PromptIssue(.unbalancedOpener, at: .body(byteOffset: opener)))
                position = bytes.count
                break
            }
            var start = opener + 2
            var nameEnd = end
            while start < nameEnd, bytes[start] == 32 || bytes[start] == 9 { start += 1 }
            while nameEnd > start, bytes[nameEnd - 1] == 32 || bytes[nameEnd - 1] == 9 { nameEnd -= 1 }
            let name = String(decoding: bytes[start..<nameEnd], as: UTF8.self)
            if isValidName(name) {
                literal(until: opener)
                tokens.append(.placeholder(name))
                if used.insert(name).inserted {
                    names.append(name)
                    offsets[name] = opener
                }
                literalStart = end + 2
            } else {
                issues.append(PromptIssue(.invalidPlaceholder, at: .body(byteOffset: opener)))
            }
            position = end + 2
        }
        literal(until: bytes.count)
        return Template(tokens: tokens, names: names, issues: issues, firstUseOffsets: offsets)
    }

    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, isLetter(first) || first == 95 else { return false }
        return bytes.dropFirst().allSatisfy { isLetter($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    static func isReserved(_ name: String) -> Bool {
        BuiltinName(rawValue: name) != nil || deferredNames.contains(name)
    }

    static let deferredNames: Set<String> = ["selection", "cursor", "datetime", "uuid"]

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}
