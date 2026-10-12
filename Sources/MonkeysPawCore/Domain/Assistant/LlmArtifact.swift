import Foundation

/// Only these values may replace prompt metadata; notes are never saved.
public struct LlmArtifact: Equatable, Sendable {
    public let title: String
    public let description: String
    public let tags: [String]
    public let fields: [Field]
    public let body: String
    public let notes: String

    public struct Field: Equatable, Sendable {
        public let name: String
        public let type: FieldKind
        public let label: String
        public let description: String
        /// Empty means no prefill, including for a choice field.
        public let defaultValue: String
        public let options: [FieldOption]
        public let optional: Bool
        public let remember: Bool
    }

    /// The same descriptor validates output and supplies provider requests.
    public static var jsonSchema: Data { LlmSchemas.artifact.jsonSchema }

    /// Content issues remain visible on a draft; errors block later acceptance.
    /// Structural JSON failures never reach this stage or a file converter.
    public var issues: [PromptIssue] {
        var fieldIssues = [PromptIssue]()
        for field in fields {
            if !Template.isValidName(field.name) { fieldIssues.append(PromptIssue(.invalidFieldName)) }
            if Template.isReserved(field.name) { fieldIssues.append(PromptIssue(.reservedFieldName)) }
            if field.type == .choice {
                if field.options.isEmpty { fieldIssues.append(PromptIssue(.invalidFieldOptions)) }
                if !field.defaultValue.isEmpty,
                   !field.options.contains(where: { $0.value == field.defaultValue }) {
                    fieldIssues.append(PromptIssue(.invalidFieldDefault))
                }
            } else if !field.options.isEmpty {
                fieldIssues.append(PromptIssue(.invalidFieldOptions))
            }
        }
        let declarations = fields.map {
            PromptField(name: $0.name, kind: $0.type, label: $0.label, description: $0.description,
                        defaultValue: $0.defaultValue, options: $0.options,
                        optional: $0.optional, remember: $0.remember)
        }
        let document = PromptDocument(source: "", body: body,
            frontMatter: FrontMatter(title: title, description: description, tags: tags, fields: declarations),
            template: Template.parse(body), decodingIssues: fieldIssues)
        return PromptValidator.validate(document)
    }
}
