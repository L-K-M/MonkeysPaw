import Foundation

/// The only provider-output entry point: recover, strictly validate, then build
/// values. Artifact-to-file conversion and acceptance belong to later slices.
public enum LlmOutputDecoder {
    public static func artifact(from output: String) throws -> LlmArtifact {
        let object = try validated(output, schema: LlmSchemas.artifact)
        var names = Set<String>()
        let fields: [LlmArtifact.Field] = try object["fields"]!.array.map { value in
            let field = value.object
            let name = field["name"]!.string
            guard names.insert(name).inserted else { throw AssistantError.invalidOutput }
            return LlmArtifact.Field(name: name, type: FieldKind(rawValue: field["type"]!.string)!,
                label: field["label"]!.string, description: field["description"]!.string,
                defaultValue: field["default"]!.string,
                options: field["options"]!.array.map {
                    FieldOption(label: $0.object["label"]!.string, value: $0.object["value"]!.string)
                }, optional: field["optional"]!.boolean, remember: field["remember"]!.boolean)
        }
        return LlmArtifact(title: object["title"]!.string, description: object["description"]!.string,
            tags: object["tags"]!.array.map(\.string), fields: fields,
            body: object["body"]!.string, notes: object["notes"]!.string)
    }

    public static func review(from output: String, source: String) throws -> LlmReview {
        guard source.utf8.count <= Limits.maxPromptBytes else { throw AssistantError.invalidOutput }
        let object = try validated(output, schema: LlmSchemas.review)
        let sourceBytes = Data(source.utf8)
        let findings = object["findings"]!.array.map { value -> LlmReview.Finding in
            let finding = value.object
            let quote = finding["quote"]!.string
            let match: LlmReview.QuoteMatch
            if !quote.isEmpty, let range = sourceBytes.range(of: Data(quote.utf8)) {
                match = .matched(byteRange: range)
            } else { match = .unmatched }
            return LlmReview.Finding(criterion: LlmRubricCriterion(rawValue: finding["criterion"]!.string)!,
                severity: LlmReviewSeverity(rawValue: finding["severity"]!.string)!, quote: quote,
                problem: finding["problem"]!.string, suggestion: finding["suggestion"]!.string,
                quoteMatch: match)
        }
        return LlmReview(summary: object["summary"]!.string, findings: findings)
    }

    private static func validated(_ output: String, schema: LlmSchema) throws -> [String: LlmJSONValue] {
        var parser = LlmJSONParser(bytes: try LlmJSONRecovery.object(in: output))
        let value = try parser.parse()
        try schema.validate(value)
        return value.object
    }
}
