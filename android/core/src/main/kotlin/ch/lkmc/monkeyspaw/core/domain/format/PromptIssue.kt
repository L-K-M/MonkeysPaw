package ch.lkmc.monkeyspaw.core.domain.format

data class PromptIssue(val code: PromptIssueCode, val location: PromptIssueLocation? = null) {
    val severity: PromptIssueSeverity
        get() = when (code) {
            PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNUSED_FIELD,
            PromptIssueCode.GROUP_PRIVATE_REMOVED -> PromptIssueSeverity.WARNING
            else -> PromptIssueSeverity.ERROR
        }
    val message: String get() = code.message
}

enum class PromptIssueSeverity(val rawValue: String) { WARNING("warning"), ERROR("error") }

sealed interface PromptIssueLocation {
    /** One-based source line and Unicode scalar column, including the opening delimiter. */
    data class FrontMatter(val line: Int, val column: Int) : PromptIssueLocation
    /** Zero-based UTF-8 byte offset in the body. */
    data class Body(val byteOffset: Int) : PromptIssueLocation
}

enum class PromptIssueCode(val rawValue: String, internal val message: String) {
    SOURCE_TOO_LARGE("source.too_large", "Keep the prompt source within 262144 UTF-8 bytes."),
    INVALID_UTF8("source.invalid_utf8", "Encode the prompt file as UTF-8."),
    UNCLOSED_FRONT_MATTER("front_matter.unclosed", "Close the front matter with a delimiter line (---)."),
    INVALID_YAML("yaml.invalid", "Fix the YAML syntax in the front matter."),
    FRONT_MATTER_NOT_MAPPING("yaml.root_not_mapping", "Use a mapping for front matter."),
    DUPLICATE_KEY("yaml.duplicate_key", "Use each mapping key only once."),
    ANCHOR_OR_ALIAS("yaml.anchor_or_alias", "Replace YAML anchors and aliases with literal values."),
    MERGE_KEY("yaml.merge_key", "Replace YAML merge keys with explicit entries."),
    NON_PORTABLE_SCALAR("yaml.scalar_not_portable", "Use a portable scalar spelling, or quote a literal string."),
    NON_PORTABLE_TAG("yaml.tag_not_portable", "Use a shared YAML Core-schema tag, or a literal string."),
    INVALID_ID("metadata.invalid_id", "Supply a valid 26-character ULID, or omit the id."),
    INVALID_METADATA_TYPE("metadata.invalid_type", "Use the declared type for this metadata property."),
    GROUP_PRIVATE_REMOVED("metadata.group_private_removed", "The private flag is personal and is removed from group content."),
    INVALID_FORMAT("metadata.invalid_format", "Use a positive integer for the file format."),
    UNSUPPORTED_FORMAT("format.unsupported", "This file format is newer than supported. Open it read-only."),
    INVALID_FIELD_NAME("field.invalid_name", "Use a valid placeholder name for the field."),
    RESERVED_FIELD_NAME("field.reserved_name", "Remove the reserved field name. Builtins have no controls."),
    INVALID_FIELD_DECLARATION("field.invalid_declaration", "Use a mapping for each field declaration."),
    UNKNOWN_FIELD_TYPE("field.unknown_type", "Use text, multiline or choice as the field type."),
    INVALID_FIELD_PROPERTY("field.invalid_property", "Use the declared type for this field property."),
    INVALID_FIELD_BOOLEAN("field.invalid_boolean", "Use true or false for this field property."),
    INVALID_FIELD_OPTIONS("field.invalid_options", "Give choice fields a nonempty list of string or label/value options."),
    INVALID_FIELD_DEFAULT("field.invalid_default", "Use a string default that matches a choice option when applicable."),
    UNUSED_FIELD("field.unused", "This declared field is not used in the body."),
    INVALID_PLACEHOLDER("template.invalid_placeholder", "This closed construct is literal text, not a placeholder."),
    UNBALANCED_OPENER("template.unbalanced_opener", "Close the placeholder opener, or escape it with a backslash."),
}
