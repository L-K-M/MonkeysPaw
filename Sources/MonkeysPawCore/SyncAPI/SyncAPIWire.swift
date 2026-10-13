import Foundation

/// Values are read through Decoder, retaining exact Int64s and Swift strings.
/// No Foundation JSON bridging, dates, normalization or key strategies intervene.
enum APIValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), boolean(Bool), null
    case array([APIValue]), object([String: APIValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let value = try? c.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? c.decode(Int64.self) { self = .integer(value); return }
        if let value = try? c.decode(String.self) { self = .string(value); return }
        if let value = try? c.decode([APIValue].self) { self = .array(value); return }
        if let value = try? c.decode([String: APIValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid SyncAPI JSON value.")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .boolean(let value): try c.encode(value)
        case .null: try c.encodeNil()
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    static func dto(_ value: some APIObjectDTO) -> Self { .object(value.object) }
    static func dtos(_ values: [some APIObjectDTO]) -> Self { .array(values.map(dto)) }
    static func nullableString(_ value: String?) -> Self { value.map(Self.string) ?? .null }
}

enum APIContractError: Error { case invalidValue }

protocol APIObjectDTO: SyncAPIDTO {
    init(object: [String: APIValue]) throws
    var object: [String: APIValue] { get }
}

extension APIObjectDTO {
    public init(from decoder: Decoder) throws {
        let value = try APIValue(from: decoder)
        do {
            try Self.schema.validate(value)
            guard case .object(let object) = value else { throw APIContractError.invalidValue }
            try self.init(object: object)
        } catch {
            // Diagnostics must never include credentials, prompt text or input values.
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid " + Self.schemaName + " contract."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        let value = APIValue.object(object)
        do { try Self.schema.validate(value) } catch {
            throw EncodingError.invalidValue(Self.schemaName, .init(codingPath: encoder.codingPath,
                                                                   debugDescription: "Invalid SyncAPI contract."))
        }
        try value.encode(to: encoder)
    }
}

extension Dictionary where Key == String, Value == APIValue {
    func string(_ key: String) throws -> String {
        guard case .string(let value) = self[key] else { throw APIContractError.invalidValue }
        return value
    }
    func integer(_ key: String) throws -> Int64 {
        guard case .integer(let value) = self[key] else { throw APIContractError.invalidValue }
        return value
    }
    func boolean(_ key: String) throws -> Bool {
        guard case .boolean(let value) = self[key] else { throw APIContractError.invalidValue }
        return value
    }
    func array(_ key: String) throws -> [APIValue] {
        guard case .array(let value) = self[key] else { throw APIContractError.invalidValue }
        return value
    }
    func dto<T: APIObjectDTO>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard case .object(let value) = self[key] else { throw APIContractError.invalidValue }
        return try T(object: value)
    }
    func dtos<T: APIObjectDTO>(_ key: String, as type: T.Type = T.self) throws -> [T] {
        try array(key).map {
            guard case .object(let value) = $0 else { throw APIContractError.invalidValue }
            return try T(object: value)
        }
    }
    func optionalString(_ key: String) throws -> String? {
        if self[key] == nil || self[key] == .null { return nil }
        return try string(key)
    }
    func rawEnum<T: RawRepresentable>(_ key: String, as type: T.Type = T.self) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: try string(key)) else { throw APIContractError.invalidValue }
        return value
    }
}

extension SyncAPISchema {
    func validate(_ value: APIValue) throws {
        switch (self, value) {
        case (.string(let constraints), .string(let text)): try constraints.validate(text)
        case (.integer(let minimum, let maximum), .integer(let number)):
            guard minimum <= number, number <= maximum else { throw APIContractError.invalidValue }
        case (.boolean, .boolean), (.null, .null): break
        case (.array(let items, let minimum, let maximum, let unique), .array(let values)):
            guard values.count >= minimum, maximum.map({ values.count <= $0 }) ?? true else { throw APIContractError.invalidValue }
            for item in values { try items.validate(item) }
            if unique {
                for index in values.indices where values[..<index].contains(values[index]) { throw APIContractError.invalidValue }
            }
        case (.object(let fields, let minimum, let rules), .object(let object)):
            let allowed = Set(fields.map(\.name))
            let required = Set(fields.filter(\.required).map(\.name))
            guard allowed.count == fields.count, object.count >= minimum,
                  Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else {
                throw APIContractError.invalidValue
            }
            for field in fields {
                if let value = object[field.name] { try field.schema.validate(value) }
            }
            for rule in rules { try rule.validate(object) }
        case (.map(let keys, let values), .object(let object)):
            for (key, value) in object { try keys.validate(key); try values.validate(value) }
        case (.oneOf(let alternatives), _):
            guard alternatives.filter({ (try? $0.validate(value)) != nil }).count == 1 else { throw APIContractError.invalidValue }
        case (.reference(let name), _):
            guard let schema = SyncAPI.schemas.first(where: { $0.name == name })?.schema else { throw APIContractError.invalidValue }
            try schema.validate(value)
        default: throw APIContractError.invalidValue
        }
    }
}

extension SyncAPIString {
    private static let regexCache = APIRegexCache()

    func validate(_ text: String) throws {
        let length = text.unicodeScalars.count
        guard length >= minimumLength, maximumLength.map({ length <= $0 }) ?? true,
              maximumUTF8Bytes.map({ text.utf8.count <= $0 }) ?? true,
              allowedValues.map({ $0.contains(text) }) ?? true else { throw APIContractError.invalidValue }
        if let pattern {
            let regex = try Self.regexCache.expression(pattern)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard regex.firstMatch(in: text, range: range)?.range == range else { throw APIContractError.invalidValue }
        }
        switch format {
        case .ulid:
            guard let id = ULID(text), id.rawValue.utf8.elementsEqual(text.utf8) else { throw APIContractError.invalidValue }
        case .uuid:
            guard text.utf8.count == 36, let id = UUID(uuidString: text), id.uuidString.lowercased() == text else {
                throw APIContractError.invalidValue
            }
        case .scopeKey:
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, ["user", "group"].contains(String(parts[0])) else { throw APIContractError.invalidValue }
            try SyncAPIString(format: .ulid).validate(String(parts[1]))
        case .utcMilliseconds: try validateTimestamp(text)
        case nil: break
        }
    }

    private func validateTimestamp(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard bytes.count == 24 else { throw APIContractError.invalidValue }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90]
        for (index, byte) in bytes.enumerated() {
            guard separators[index].map({ byte == $0 }) ?? (48...57).contains(byte) else { throw APIContractError.invalidValue }
        }
        func number(_ start: Int, _ end: Int) -> Int { bytes[start..<end].reduce(0) { $0 * 10 + Int($1 - 48) } }
        let year = number(0, 4), month = number(5, 7), day = number(8, 10)
        guard year >= 1, (1...12).contains(month), number(11, 13) <= 23,
              number(14, 16) <= 59, number(17, 19) <= 59 else { throw APIContractError.invalidValue }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { throw APIContractError.invalidValue }
    }
}

/// Patterns come from schema descriptions; the lock owns all cache access.
private final class APIRegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var expressions: [String: NSRegularExpression] = [:]

    func expression(_ pattern: String) throws -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let cached = expressions[pattern] { return cached }

        let compiled = try NSRegularExpression(pattern: pattern)
        expressions[pattern] = compiled
        return compiled
    }
}
