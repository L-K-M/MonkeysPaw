import Foundation

/// Parsed values retain strict types. Artifact output rejects duplicate keys
/// before a dictionary or Codable decoder can silently choose a value.
indirect enum LlmJSONValue {
    case object([String: LlmJSONValue])
    case array([LlmJSONValue])
    case string(String)
    case boolean(Bool)
    case number
    case null

    var array: [LlmJSONValue] {
        get throws {
            guard case .array(let value) = self else { throw AssistantError.invalidOutput }
            return value
        }
    }
    var string: String {
        get throws {
            guard case .string(let value) = self else { throw AssistantError.invalidOutput }
            return value
        }
    }
    var boolean: Bool {
        get throws {
            guard case .boolean(let value) = self else { throw AssistantError.invalidOutput }
            return value
        }
    }

    func member(_ key: String) throws -> LlmJSONValue {
        guard case .object(let properties) = self, let value = properties[key] else {
            throw AssistantError.invalidOutput
        }
        return value
    }
}

enum LlmJSONRecovery {
    static func object(in output: String) throws -> [UInt8] {
        guard output.utf8.count <= Limits.responseCap else { throw AssistantError.invalidOutput }
        let bytes = Array(output.utf8)
        let thinkingOpener = Array("<think>".utf8)
        var position = 0
        var start: Int?
        var stack = [UInt8]()
        var inString = false
        var escaped = false

        // Only the selected object owns string/bracket state. Complete array
        // preambles remain wrappers, so recovery never unwraps [artifact].
        while position < bytes.count {
            let byte = bytes[position]
            if start == nil {
                if byte == 60, bytes[position...].starts(with: thinkingOpener) {
                    position = try endOfThinking(in: bytes, from: position)
                    continue
                }
                if byte == 91 {
                    var parser = LlmJSONParser(bytes: bytes, position: position)
                    if let (_, end) = try? parser.parsePrefix() {
                        position = end
                        continue
                    }
                }
                guard byte == 123 else {
                    position += 1
                    continue
                }
                start = position
            }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                position += 1
                continue
            }
            if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                stack.append(byte == 123 ? 125 : 93)
                guard stack.count <= Limits.llmJSONNestingCap else { throw AssistantError.invalidOutput }
            } else if byte == 125 || byte == 93, !stack.isEmpty {
                guard stack.removeLast() == byte else { throw AssistantError.invalidOutput }
                if stack.isEmpty, let start { return Array(bytes[start...position]) }
            }
            position += 1
        }
        throw AssistantError.invalidOutput
    }

    private static func endOfThinking(in bytes: [UInt8], from start: Int) throws -> Int {
        let opening = Array("<think>".utf8)
        let closing = Array("</think>".utf8)
        var position = start + opening.count
        var depth = 1
        while position < bytes.count {
            if bytes[position...].starts(with: opening) {
                depth += 1
                position += opening.count
            } else if bytes[position...].starts(with: closing) {
                depth -= 1
                position += closing.count
                if depth == 0 { return position }
            } else { position += 1 }
        }
        throw AssistantError.invalidOutput
    }
}

struct LlmJSONParser {
    enum Mode { case output, serialization }
    private let bytes: [UInt8]
    private let mode: Mode
    private var position = 0

    init(bytes: [UInt8], position: Int = 0, mode: Mode = .output) {
        self.bytes = bytes
        self.mode = mode
        self.position = position
        if mode == .serialization, position == 0, bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.position = 3
        }
    }

    mutating func parse() throws -> LlmJSONValue {
        let (parsed, _) = try parsePrefix()
        whitespace()
        guard position == bytes.count else { throw AssistantError.invalidOutput }
        return parsed
    }

    mutating func parsePrefix() throws -> (LlmJSONValue, Int) {
        let parsed = try value(depth: 0)
        return (parsed, position)
    }

    private mutating func value(depth: Int) throws -> LlmJSONValue {
        whitespace()
        guard position < bytes.count else { throw AssistantError.invalidOutput }
        // Depth counts enclosing containers; a scalar at the cap opens none.
        if bytes[position] == 123 || bytes[position] == 91 {
            let cap = mode == .output ? Limits.llmJSONNestingCap : Limits.assistantEnvelopeNestingCap
            guard depth < cap else { throw AssistantError.invalidOutput }
        }
        switch bytes[position] {
        case 123:
            position += 1
            whitespace()
            var properties = [String: LlmJSONValue]()
            if consume(125) { return .object(properties) }
            repeat {
                whitespace()
                let key = try string()
                if mode == .output, properties[key] != nil { throw AssistantError.invalidOutput }
                whitespace()
                guard consume(58) else { throw AssistantError.invalidOutput }
                properties[key] = try value(depth: depth + 1)
                whitespace()
            } while consume(44)
            guard consume(125) else { throw AssistantError.invalidOutput }
            return .object(properties)
        case 91:
            position += 1
            whitespace()
            var items = [LlmJSONValue]()
            if consume(93) { return .array(items) }
            repeat {
                items.append(try value(depth: depth + 1))
                whitespace()
            } while consume(44)
            guard consume(93) else { throw AssistantError.invalidOutput }
            return .array(items)
        case 34: return .string(try string())
        case 116: try literal("true"); return .boolean(true)
        case 102: try literal("false"); return .boolean(false)
        case 110: try literal("null"); return .null
        default:
            let start = position
            while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) {
                position += 1
            }
            if mode == .serialization {
                let token = String(decoding: bytes[start..<position], as: UTF8.self)
                guard Double(token)?.isFinite == true,
                      token.range(of: #"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z"#,
                                  options: .regularExpression) != nil else { throw AssistantError.invalidOutput }
                return .number
            }
            guard position > start,
                  (try? JSONSerialization.jsonObject(with: Data(bytes[start..<position]),
                                                     options: [.fragmentsAllowed])) is NSNumber else {
                throw AssistantError.invalidOutput
            }
            return .number
        }
    }

    private mutating func string() throws -> String {
        guard consume(34) else { throw AssistantError.invalidOutput }
        var decoded = ""
        var start = position
        while position < bytes.count {
            let byte = bytes[position]
            guard byte >= 32 else { throw AssistantError.invalidOutput }
            if byte != 34 && byte != 92 {
                position += 1
                continue
            }

            // Foundation decodes raw string runs differently on macOS and Linux.
            if bytes[start..<position].starts(with: [0xEF, 0xBB, 0xBF]) { start += 3 }
            // String(validating:as:) needs macOS 15. Invalid UTF-8 decodes to U+FFFD,
            // so only valid input round-trips byte for byte.
            let run = bytes[start..<position]
            let raw = String(decoding: run, as: UTF8.self)
            guard raw.utf8.elementsEqual(run) else { throw AssistantError.invalidOutput }
            decoded += raw
            position += 1
            if byte == 34 { return decoded }
            guard position < bytes.count else { throw AssistantError.invalidOutput }
            let escape = bytes[position]
            position += 1
            switch escape {
            case 34, 47, 92: decoded.unicodeScalars.append(Unicode.Scalar(escape))
            case 98: decoded += "\u{08}"
            case 102: decoded += "\u{0C}"
            case 110: decoded += "\n"
            case 114: decoded += "\r"
            case 116: decoded += "\t"
            case 117:
                var scalar = try hexQuad()
                if (0xD800...0xDBFF).contains(scalar) {
                    guard consume(92), consume(117) else { throw AssistantError.invalidOutput }
                    let low = try hexQuad()
                    guard (0xDC00...0xDFFF).contains(low) else { throw AssistantError.invalidOutput }
                    scalar = 0x10000 + (scalar - 0xD800) * 0x400 + (low - 0xDC00)
                }
                guard let unicode = Unicode.Scalar(scalar) else { throw AssistantError.invalidOutput }
                decoded.unicodeScalars.append(unicode)
            default: throw AssistantError.invalidOutput
            }
            start = position
        }
        throw AssistantError.invalidOutput
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw AssistantError.invalidOutput }
        var scalar: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch bytes[position] {
            case 48...57: digit = UInt32(bytes[position] - 48)
            case 65...70: digit = UInt32(bytes[position] - 55)
            case 97...102: digit = UInt32(bytes[position] - 87)
            default: throw AssistantError.invalidOutput
            }
            scalar = scalar * 16 + digit
            position += 1
        }
        return scalar
    }

    private mutating func literal(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes[position...].starts(with: expected) else { throw AssistantError.invalidOutput }
        position += expected.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private mutating func whitespace() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }
}
