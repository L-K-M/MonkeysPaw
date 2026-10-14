package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption
import ch.lkmc.monkeyspaw.core.domain.format.FrontMatter
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptField
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.Template
import ch.lkmc.monkeyspaw.core.domain.format.equalChoiceValues
import ch.lkmc.monkeyspaw.core.llm.LlmSchemas

/** Only these values may replace prompt metadata. Notes stay session-only. */
@ConsistentCopyVisibility
data class LlmArtifact private constructor(
    val title: String,
    val description: String,
    val tags: List<String>,
    val fields: List<Field>,
    val body: String,
    val notes: String,
) {
    @ConsistentCopyVisibility
    data class Field private constructor(
        val name: String,
        val type: FieldKind,
        val label: String,
        val description: String,
        val defaultValue: String,
        val options: List<FieldOption>,
        val optional: Boolean,
        val remember: Boolean,
    ) {
        override fun toString(): String = "<LLM field redacted>"

        companion object {
            operator fun invoke(name: String, type: FieldKind, label: String, description: String, defaultValue: String,
                                options: List<FieldOption>, optional: Boolean, remember: Boolean): Field =
                Field(name, type, label, description, defaultValue, options.immutableCopy(), optional, remember)
        }
    }

    override fun toString(): String = "<LLM artifact redacted>"

    val issues: List<PromptIssue>
        get() {
            val fieldIssues = mutableListOf<PromptIssue>()
            for (field in fields) {
                if (!Template.isValidName(field.name)) fieldIssues.add(PromptIssue(PromptIssueCode.INVALID_FIELD_NAME))
                if (Template.isReserved(field.name)) fieldIssues.add(PromptIssue(PromptIssueCode.RESERVED_FIELD_NAME))
                if (field.type == FieldKind.CHOICE) {
                    if (field.options.isEmpty()) fieldIssues.add(PromptIssue(PromptIssueCode.INVALID_FIELD_OPTIONS))
                    if (field.defaultValue.isNotEmpty() && field.options.none { equalChoiceValues(it.value, field.defaultValue) }) {
                        fieldIssues.add(PromptIssue(PromptIssueCode.INVALID_FIELD_DEFAULT))
                    }
                } else if (field.options.isNotEmpty()) fieldIssues.add(PromptIssue(PromptIssueCode.INVALID_FIELD_OPTIONS))
            }
            val declarations = fields.map { PromptField(it.name, it.type, it.label, it.description,
                it.defaultValue, it.options, it.optional, it.remember) }
            return PromptDocument("", body, FrontMatter(title, description = description, tags = tags, fields = declarations),
                Template.parse(body), fieldIssues).issues
        }

    companion object {
        val jsonSchema: ByteArray get() = LlmSchemas.artifact.jsonSchema
        operator fun invoke(title: String, description: String, tags: List<String>, fields: List<Field>, body: String, notes: String): LlmArtifact =
            LlmArtifact(title, description, tags.immutableCopy(), fields.immutableCopy(), body, notes)
    }
}

enum class LlmRubricCriterion(val rawValue: String) {
    CLARITY("clarity"), CONTEXT("context"), ROLE("role"), DELIMITING("delimiting"), OUTPUT_FORMAT("output_format"),
    EXAMPLES("examples"), REASONING("reasoning"), VERIFIABILITY("verifiability"), DECOMPOSITION("decomposition"), PLACEHOLDERS("placeholders"),
}

enum class LlmReviewSeverity(val rawValue: String) { HIGH("high"), MEDIUM("medium"), LOW("low") }

@ConsistentCopyVisibility
data class LlmReview private constructor(val summary: String, val findings: List<Finding>) {
    data class Finding(
        val criterion: LlmRubricCriterion,
        val severity: LlmReviewSeverity,
        val quote: String,
        val problem: String,
        val suggestion: String,
        val quoteMatch: QuoteMatch,
    ) {
        override fun toString(): String = "<LLM finding redacted>"
    }

    sealed interface QuoteMatch {
        /** Half-open, zero-based UTF-8 byte range in the exact source snapshot. */
        data class Matched(val startByte: Int, val endByteExclusive: Int) : QuoteMatch
        data object Unmatched : QuoteMatch
    }

    override fun toString(): String = "<LLM review redacted>"

    companion object {
        val jsonSchema: ByteArray get() = LlmSchemas.review.jsonSchema
        operator fun invoke(summary: String, findings: List<Finding>): LlmReview = LlmReview(summary, findings.immutableCopy())
    }
}
