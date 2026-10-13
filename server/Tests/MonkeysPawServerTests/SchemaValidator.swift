import CoreFoundation
import Foundation

// Test-only subset: exact Int64s, emitted 2020-12 keywords and documented
// SyncAPI extensions. This deliberately does not implement arbitrary schemas.
enum SchemaJSON: Equatable {
    case string(String), integer(Int64), number(Double), boolean(Bool), null
    case array([SchemaJSON]), object([String: SchemaJSON])

    init(data: Data) throws {
        try self.init(jsonObject: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private init(jsonObject value: Any) throws {
        if let number = value as? NSNumber {
            // Swift casts also bridge numeric 0/1 to Bool; CF identity retains the literal kind.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .boolean(number.boolValue); return }
            // Read integer spelling before Double so Int64.max does not lose precision.
            if let integer = Int64(number.stringValue) { self = .integer(integer); return }
            // NSNumber.compare can round an underflow back into range; compare decimal spelling.
            if let integer = Int64(exactly: number.doubleValue),
               let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
               decimal == Decimal(integer) {
                self = .integer(integer)
                return
            }
            self = .number(number.doubleValue)
            return
        }
        if let value = value as? String { self = .string(value); return }
        if let value = value as? [Any] { self = .array(try value.map { try Self(jsonObject: $0) }); return }
        if let value = value as? [String: Any] { self = .object(try value.mapValues { try Self(jsonObject: $0) }); return }
        if value is NSNull { self = .null; return }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported JSON value."))
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    var array: [Self]? { if case .array(let value) = self { return value }; return nil }
    var object: [String: Self]? { if case .object(let value) = self { return value }; return nil }
}

struct SchemaValidator {
    enum Failure: Error { case unsupportedSchema }
    enum Mode { case schema, contract }
    let schemas: [String: SchemaJSON]

    func validate(_ value: SchemaJSON, against schema: SchemaJSON, mode: Mode = .contract) throws -> Bool {
        guard let object = schema.object else { throw Failure.unsupportedSchema }
        let supported: Set<String> = [
            "$schema", "$id", "title", "$ref", "type", "const", "enum", "oneOf", "allOf",
            "minimum", "maximum", "minLength", "maxLength", "pattern", "format",
            "items", "minItems", "maxItems", "uniqueItems", "properties", "required",
            "additionalProperties", "minProperties", "propertyNames", "x-max-utf8-bytes",
            "x-syncapi-format", "x-syncapi-rules"
        ]
        guard Set(object.keys).isSubset(of: supported) else { throw Failure.unsupportedSchema }
        if let type = object["type"], type.string == nil { throw Failure.unsupportedSchema }
        let required = try object["required"].map { value -> [String] in
            guard let entries = value.array else { throw Failure.unsupportedSchema }
            return try entries.map {
                guard let key = $0.string else { throw Failure.unsupportedSchema }
                return key
            }
        } ?? []
        // Other keyword value shapes are trusted to the renderer's emitted subset.

        if let reference = object["$ref"]?.string {
            guard let target = schemas[reference] else { throw Failure.unsupportedSchema }
            if try !validate(value, against: target, mode: mode) { return false }
        }
        if let constant = object["const"], constant != value { return false }
        if let values = object["enum"]?.array, !values.contains(value) { return false }
        if let alternatives = object["oneOf"]?.array {
            let matches = try alternatives.filter { try validate(value, against: $0, mode: mode) }
            if matches.count != 1 { return false }
        }
        if let constraints = object["allOf"]?.array {
            for constraint in constraints {
                if try !validate(value, against: constraint, mode: mode) { return false }
            }
        }

        if let type = object["type"]?.string {
            switch (type, value) {
            case ("string", .string), ("integer", .integer), ("boolean", .boolean),
                 ("null", .null), ("array", .array), ("object", .object): break
            default: return false
            }
        }
        switch value {
        case .integer(let number):
            if let minimum = object["minimum"]?.integer, number < minimum { return false }
            if let maximum = object["maximum"]?.integer, number > maximum { return false }
        case .string(let text):
            let count = Int64(text.unicodeScalars.count)
            if let minimum = object["minLength"]?.integer, count < minimum { return false }
            if let maximum = object["maxLength"]?.integer, count > maximum { return false }
            if let pattern = object["pattern"]?.string {
                let regex = try NSRegularExpression(pattern: pattern)
                if regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) == nil { return false }
            }
            if mode == .contract {
                if let maximum = object["x-max-utf8-bytes"]?.integer, text.utf8.count > maximum { return false }
                if let format = object["x-syncapi-format"]?.string {
                    guard format == "utc-milliseconds" else { throw Failure.unsupportedSchema }
                    if !validCalendarDate(text) { return false }
                }
            }
        case .array(let values):
            if let minimum = object["minItems"]?.integer, values.count < minimum { return false }
            if let maximum = object["maxItems"]?.integer, values.count > maximum { return false }
            if object["uniqueItems"] == .boolean(true) {
                for index in values.indices where values[..<index].contains(values[index]) { return false }
            }
            if let items = object["items"] {
                for item in values {
                    if try !validate(item, against: items, mode: mode) { return false }
                }
            }
        case .object(let values):
            if let minimum = object["minProperties"]?.integer, values.count < minimum { return false }
            for key in required { if values[key] == nil { return false } }
            let properties = object["properties"]?.object ?? [:]
            for (key, value) in values {
                if let keySchema = object["propertyNames"],
                   try !validate(.string(key), against: keySchema, mode: mode) { return false }
                if let property = properties[key] {
                    if try !validate(value, against: property, mode: mode) { return false }
                } else if let additional = object["additionalProperties"] {
                    if additional == .boolean(false) { return false }
                    if additional.object != nil,
                       try !validate(value, against: additional, mode: mode) { return false }
                }
            }
            if mode == .contract, let rules = object["x-syncapi-rules"]?.array {
                for rule in rules { if try !validateRule(rule.string, values) { return false } }
            }
        default: break
        }
        return true
    }

    private func validCalendarDate(_ text: String) -> Bool {
        let date = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard date.count == 3, date[0] >= 1, (1...12).contains(date[1]) else { return false }
        let year = date[0]
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[date[1] - 1]).contains(date[2])
    }

    private func validateRule(_ rule: String?, _ object: [String: SchemaJSON]) throws -> Bool {
        switch rule {
        case "group-scope-key":
            guard let groupID = object["group_id"]?.string else { return false }
            return object["key"]?.string == "group:" + groupID
        case "sync-page":
            guard let head = object["head"]?.integer, let mode = object["mode"]?.string,
                  let items = object["items"]?.array else { return false }
            for item in items {
                guard let item = item.object, let seq = item["seq"]?.integer, seq > 0, seq <= head else { return false }
                if mode == "snapshot", item["kind"]?.string != "upsert" || seq != head { return false }
            }
            return true
        case "pull-item-budget":
            guard let scopes = object["scopes"]?.array, let removed = object["removed"]?.array else { return false }
            let keys = scopes.compactMap { $0.object?["key"]?.string }
            let users = scopes.filter { $0.object?["kind"]?.string == "user" }
            let count = scopes.reduce(0) { $0 + ($1.object?["items"]?.array?.count ?? 0) }
            return count <= 200 && Set(keys).count == scopes.count && users.count == 1
                && !keys.contains { removed.contains(.string($0)) }
        default: throw Failure.unsupportedSchema
        }
    }
}
