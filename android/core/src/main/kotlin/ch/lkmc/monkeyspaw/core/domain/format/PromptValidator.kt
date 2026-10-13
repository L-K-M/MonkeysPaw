package ch.lkmc.monkeyspaw.core.domain.format

object PromptValidator {
    /** Parsing issues, then grammar issues, inferred reserved names, then unused declarations. */
    fun validate(document: PromptDocument): List<PromptIssue> {
        val issues = (document.decodingIssues + document.template.issues).toMutableList()
        val declarations = document.frontMatter.fields.map { it.name }.toSet()
        val used = document.template.names.toSet()

        for (name in document.template.names) {
            if (name in Template.deferredNames && name !in declarations) {
                issues.add(PromptIssue(PromptIssueCode.RESERVED_FIELD_NAME,
                    document.template.firstUseOffsets[name]?.let { PromptIssueLocation.Body(it) }))
            }
        }
        for (field in document.frontMatter.fields) {
            if (field.name !in used) {
                issues.add(PromptIssue(PromptIssueCode.UNUSED_FIELD, document.declarationLocations[field.name]))
            }
        }
        return issues.toList()
    }
}
