import Foundation

/// A parsed value retains strict types and rejects duplicate keys before a
/// dictionary or Codable decoder can silently choose one of their values.
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
    private let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
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
            guard depth < Limits.llmJSONNestingCap else { throw AssistantError.invalidOutput }
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
                guard properties[key] == nil else { throw AssistantError.invalidOutput }
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
            guard position > start,
                  (try? JSONSerialization.jsonObject(with: Data(bytes[start..<position]),
                                                     options: [.fragmentsAllowed])) is NSNumber else {
                throw AssistantError.invalidOutput
            }
            return .number
        }
    }

    private mutating func string() throws -> String {
        let start = position
        guard consume(34) else { throw AssistantError.invalidOutput }
        var escaped = false
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                guard let decoded = try? JSONSerialization.jsonObject(with: Data(bytes[start..<position]),
                    options: [.fragmentsAllowed]), let string = decoded as? String else {
                    throw AssistantError.invalidOutput
                }
                return string
            }
        }
        throw AssistantError.invalidOutput
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
