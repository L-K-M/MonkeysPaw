public enum PromptValidator {
    /// Warnings remain visible and never block rendering or server validation.
    public static func validate(_ document: PromptDocument) -> [PromptIssue] {
        var issues = document.decodingIssues + document.template.issues
        let declarations = Set(document.frontMatter.fields.map(\.name))
        let used = Set(document.template.names)

        for name in document.template.names where Template.deferredNames.contains(name) && !declarations.contains(name) {
            let location = document.template.firstUseOffsets[name].map { PromptIssueLocation.body(byteOffset: $0) }
            issues.append(PromptIssue(.reservedFieldName, at: location))
        }
        for field in document.frontMatter.fields where !used.contains(field.name) {
            issues.append(PromptIssue(.unusedField, at: document.declarationLocations[field.name]))
        }
        return issues
    }
}
