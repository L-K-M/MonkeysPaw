import Foundation

/// B25: this description owns both the request schema and local type/key checks.
indirect enum LlmSchema {
    case string
    case boolean
    case enumeration([String])
    case array(LlmSchema)
    case object([(String, LlmSchema)])

    var jsonSchema: Data {
        // Descriptors contain only JSON-compatible literals.
        try! JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }

    private var jsonObject: [String: Any] {
        switch self {
        case .string: return ["type": "string"]
        case .boolean: return ["type": "boolean"]
        case .enumeration(let values): return ["type": "string", "enum": values]
        case .array(let item): return ["type": "array", "items": item.jsonObject]
        case .object(let properties):
            return ["type": "object", "additionalProperties": false,
                    "required": properties.map { $0.0 },
                    "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.0, $0.1.jsonObject) })]
        }
    }

    func validate(_ value: LlmJSONValue) throws {
        switch (self, value) {
        case (.string, .string), (.boolean, .boolean): return
        case (.enumeration(let allowed), .string(let string)) where allowed.contains(string): return
        case (.array(let item), .array(let values)):
            for value in values { try item.validate(value) }
        case (.object(let properties), .object(let values)):
            guard Set(values.keys) == Set(properties.map { $0.0 }) else { throw AssistantError.invalidOutput }
            for (key, schema) in properties { try schema.validate(values[key]!) }
        default: throw AssistantError.invalidOutput
        }
    }
}

enum LlmSchemas {
    private static let option = LlmSchema.object([
        ("value", .string), ("label", .string)
    ])
    private static let field = LlmSchema.object([
        ("name", .string), ("type", .enumeration([FieldKind.text, .multiline, .choice].map(\.rawValue))),
        ("label", .string), ("description", .string), ("default", .string),
        ("options", .array(option)), ("optional", .boolean), ("remember", .boolean)
    ])
    static let artifact = LlmSchema.object([
        ("title", .string), ("description", .string), ("tags", .array(.string)),
        ("fields", .array(field)), ("body", .string), ("notes", .string)
    ])
    private static let finding = LlmSchema.object([
        ("severity", .enumeration(LlmReviewSeverity.allCases.map(\.rawValue))),
        ("criterion", .enumeration(LlmRubricCriterion.allCases.map(\.rawValue))),
        ("quote", .string), ("problem", .string), ("suggestion", .string)
    ])
    static let review = LlmSchema.object([
        ("summary", .string), ("findings", .array(finding))
    ])
}
