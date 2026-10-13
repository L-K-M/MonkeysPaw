package ch.lkmc.monkeyspaw.core.domain.format

/** Reparse edited source before rendering or writing; the preserved YAML tree stays internal. */
class PromptDocument internal constructor(
    val source: String,
    val body: String,
    val frontMatter: FrontMatter,
    val template: Template,
    val decodingIssues: List<PromptIssue> = emptyList(),
    internal val preservedHeader: YamlNode.Mapping? = null,
    internal val declarationLocations: Map<String, PromptIssueLocation> = emptyMap(),
) {
    val issues: List<PromptIssue> get() = PromptValidator.validate(this)
    val isReadOnly: Boolean get() = frontMatter.format.isFuture
    val canRender: Boolean get() = !isReadOnly && issues.none { it.severity == PromptIssueSeverity.ERROR }

    val effectiveFields: List<PromptField>
        get() {
            val declarations = linkedMapOf<String, PromptField>()
            for (field in frontMatter.fields) declarations.putIfAbsent(field.name, field)
            return template.names.filterNot(Template::isReserved).map { name ->
                declarations[name] ?: PromptField(name, isImplicit = true)
            }
        }
}
