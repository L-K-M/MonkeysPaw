package ch.lkmc.monkeyspaw.core.domain.format

/** The editable projection omits identity, format and advanced metadata.
    Those stay in the codec's preserved header, shared with the Source draft. */
@ConsistentCopyVisibility
data class PromptForm private constructor(
    val title: String,
    val description: String,
    val tags: List<String>,
    val isPrivate: Boolean,
    val body: String,
    val fieldSettings: List<PromptFieldSettings>,
) {
    companion object {
        /** A form exists only while the decoded header is supported and valid;
            body template errors do not block projection. */
        internal fun of(document: PromptDocument): PromptForm? {
            if (document.isReadOnly || document.decodingIssues.any { it.severity == PromptIssueSeverity.ERROR }) {
                return null
            }
            val used = document.effectiveFields.map { it.name }.toSet()
            val fields = document.effectiveFields + document.frontMatter.fields.filterNot { it.name in used }
            val declarations = document.preservedHeader?.entries?.firstOrNull {
                PortableYaml.string(it.key) == "fields"
            }?.value as? YamlNode.Mapping
            val defaults = declarations?.entries?.mapNotNull { entry ->
                val properties = entry.value as? YamlNode.Mapping
                if (properties?.entries?.any { PortableYaml.string(it.key) == "default" } == true) PortableYaml.string(entry.key)
                else null
            }?.toSet().orEmpty()
            val settings = fields.map { PromptFieldSettings.of(it, it.name in defaults) }
            return PromptForm(document.frontMatter.title, document.frontMatter.description ?: "",
                document.frontMatter.tags, document.frontMatter.isPrivate, document.body, settings)
        }
    }
}

/** A single-property intent leaves every other header entry untouched. */
sealed interface PromptEdit {
    data class Title(val value: String) : PromptEdit
    data class Description(val value: String) : PromptEdit
    data class Tags(val value: List<String>) : PromptEdit
    data class IsPrivate(val value: Boolean) : PromptEdit
    data class Body(val value: String) : PromptEdit
    data class Field(val settings: PromptFieldSettings) : PromptEdit
}
