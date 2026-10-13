import Foundation

/// The only provider-output entry point: recover, strictly validate, then build
/// values. Artifact-to-file conversion and acceptance belong to later slices.
public enum LlmOutputDecoder {
    public static func artifact(from output: String) throws -> LlmArtifact {
        let object = try validated(output, schema: LlmSchemas.artifact)
        var names = Set<String>()
        // Checked reads also reject schema/decoder drift without trapping.
        let fields: [LlmArtifact.Field] = try object.member("fields").array.map { field in
            let name = try field.member("name").string
            guard names.insert(name).inserted else { throw AssistantError.invalidOutput }
            guard let type = FieldKind(rawValue: try field.member("type").string) else {
                throw AssistantError.invalidOutput
            }
            return try LlmArtifact.Field(name: name, type: type,
                label: field.member("label").string, description: field.member("description").string,
                defaultValue: field.member("default").string,
                options: field.member("options").array.map {
                    try FieldOption(label: $0.member("label").string, value: $0.member("value").string)
                }, optional: field.member("optional").boolean, remember: field.member("remember").boolean)
        }
        return try LlmArtifact(title: object.member("title").string, description: object.member("description").string,
            tags: object.member("tags").array.map { try $0.string }, fields: fields,
            body: object.member("body").string, notes: object.member("notes").string)
    }

    public static func review(from output: String, source: String) throws -> LlmReview {
        guard source.utf8.count <= Limits.maxPromptBytes else { throw AssistantError.invalidOutput }
        let object = try validated(output, schema: LlmSchemas.review)
        let sourceBytes = Data(source.utf8)
        let findings = try object.member("findings").array.map { finding -> LlmReview.Finding in
            let quote = try finding.member("quote").string
            guard let criterion = LlmRubricCriterion(rawValue: try finding.member("criterion").string),
                  let severity = LlmReviewSeverity(rawValue: try finding.member("severity").string) else {
                throw AssistantError.invalidOutput
            }
            let match: LlmReview.QuoteMatch
            if !quote.isEmpty, let range = sourceBytes.range(of: Data(quote.utf8)) {
                match = .matched(byteRange: range)
            } else { match = .unmatched }
            return try LlmReview.Finding(criterion: criterion, severity: severity, quote: quote,
                problem: finding.member("problem").string, suggestion: finding.member("suggestion").string,
                quoteMatch: match)
        }
        return try LlmReview(summary: object.member("summary").string, findings: findings)
    }

    private static func validated(_ output: String, schema: LlmSchema) throws -> LlmJSONValue {
        var parser = LlmJSONParser(bytes: try LlmJSONRecovery.object(in: output))
        let value = try parser.parse()
        try schema.validate(value)
        return value
    }
}
