package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption

/** Wire values only. L2 adds schemas, strict decoding and content validation. Notes stay session-only. */
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

    companion object {
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
        operator fun invoke(summary: String, findings: List<Finding>): LlmReview = LlmReview(summary, findings.immutableCopy())
    }
}
