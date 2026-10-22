package ch.lkmc.monkeyspaw.core.domain.format

/** The editable projection omits identity, format and advanced metadata.
    Those stay in the codec's preserved header, shared with the Source draft. */
@ConsistentCopyVisibility
internal data class PromptForm private constructor(
    val title: String,
    val description: String,
    val tags: List<String>,
    val isPrivate: Boolean,
    val body: String,
) {
    companion object {
        /** A form exists only while the decoded header is supported and valid;
            body template errors do not block projection. */
        internal fun of(document: PromptDocument): PromptForm? {
            if (document.isReadOnly || document.decodingIssues.any { it.severity == PromptIssueSeverity.ERROR }) {
                return null
            }
            return PromptForm(document.frontMatter.title, document.frontMatter.description ?: "",
                document.frontMatter.tags, document.frontMatter.isPrivate, document.body)
        }
    }
}

/** A single-property intent leaves every other header entry untouched. */
internal sealed interface PromptEdit {
    data class Title(val value: String) : PromptEdit
    data class Description(val value: String) : PromptEdit
    data class Tags(val value: List<String>) : PromptEdit
    data class IsPrivate(val value: Boolean) : PromptEdit
    data class Body(val value: String) : PromptEdit
}
