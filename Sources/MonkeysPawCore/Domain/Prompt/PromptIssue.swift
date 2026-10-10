/// Stable content diagnostics shared by editors, generated drafts and servers.
/// Messages deliberately contain no source, metadata values or Yams error text.
public struct PromptIssue: Equatable, Sendable {
    public let code: PromptIssueCode
    public let severity: PromptIssueSeverity
    public let location: PromptIssueLocation?
    public var message: String { code.message }

    init(_ code: PromptIssueCode, at location: PromptIssueLocation? = nil) {
        self.code = code
        self.severity = code == .invalidPlaceholder || code == .unusedField ? .warning : .error
        self.location = location
    }
}

public enum PromptIssueSeverity: String, Sendable {
    case warning
    case error
}

public enum PromptIssueLocation: Equatable, Sendable {
    /// One-based source line and Unicode-scalar column, including the opener.
    case frontMatter(line: Int, column: Int)
    /// Zero-based UTF-8 offset within the Markdown body.
    case body(byteOffset: Int)
}

public enum PromptIssueCode: String, Sendable {
    case sourceTooLarge = "source.too_large"
    case invalidUTF8 = "source.invalid_utf8"
    case unclosedFrontMatter = "front_matter.unclosed"
    case invalidYAML = "yaml.invalid"
    case frontMatterNotMapping = "yaml.root_not_mapping"
    case duplicateKey = "yaml.duplicate_key"
    case anchorOrAlias = "yaml.anchor_or_alias"
    case mergeKey = "yaml.merge_key"
    case nonPortableScalar = "yaml.scalar_not_portable"
    case nonPortableTag = "yaml.tag_not_portable"
    case invalidID = "metadata.invalid_id"
    case invalidMetadataType = "metadata.invalid_type"
    case invalidFormat = "metadata.invalid_format"
    case unsupportedFormat = "format.unsupported"
    case invalidFieldName = "field.invalid_name"
    case reservedFieldName = "field.reserved_name"
    case invalidFieldDeclaration = "field.invalid_declaration"
    case unknownFieldType = "field.unknown_type"
    case invalidFieldProperty = "field.invalid_property"
    case invalidFieldBoolean = "field.invalid_boolean"
    case invalidFieldOptions = "field.invalid_options"
    case invalidFieldDefault = "field.invalid_default"
    case unusedField = "field.unused"
    case invalidPlaceholder = "template.invalid_placeholder"
    case unbalancedOpener = "template.unbalanced_opener"

    fileprivate var message: String {
        switch self {
        case .sourceTooLarge: return "Keep the prompt source within \(Limits.maxPromptBytes) UTF-8 bytes."
        case .invalidUTF8: return "Encode the prompt file as UTF-8."
        case .unclosedFrontMatter: return "Close the front matter with a delimiter line (---)."
        case .invalidYAML: return "Fix the YAML syntax in the front matter."
        case .frontMatterNotMapping: return "Use a mapping for front matter."
        case .duplicateKey: return "Use each mapping key only once."
        case .anchorOrAlias: return "Replace YAML anchors and aliases with literal values."
        case .mergeKey: return "Replace YAML merge keys with explicit entries."
        case .nonPortableScalar: return "Use a portable scalar spelling, or quote a literal string."
        case .nonPortableTag: return "Use a shared YAML Core-schema tag, or a literal string."
        case .invalidID: return "Supply a valid 26-character ULID, or omit the id."
        case .invalidMetadataType: return "Use the declared type for this metadata property."
        case .invalidFormat: return "Use a positive integer for the file format."
        case .unsupportedFormat: return "This file format is newer than supported. Open it read-only."
        case .invalidFieldName: return "Use a valid placeholder name for the field."
        case .reservedFieldName: return "Remove the reserved field name. Builtins have no controls."
        case .invalidFieldDeclaration: return "Use a mapping for each field declaration."
        case .unknownFieldType: return "Use text, multiline or choice as the field type."
        case .invalidFieldProperty: return "Use the declared type for this field property."
        case .invalidFieldBoolean: return "Use true or false for this field property."
        case .invalidFieldOptions: return "Give choice fields a nonempty list of string or label/value options."
        case .invalidFieldDefault: return "Use a string default that matches a choice option when applicable."
        case .unusedField: return "This declared field is not used in the body."
        case .invalidPlaceholder: return "This closed construct is literal text, not a placeholder."
        case .unbalancedOpener: return "Close the placeholder opener, or escape it with a backslash."
        }
    }
}
