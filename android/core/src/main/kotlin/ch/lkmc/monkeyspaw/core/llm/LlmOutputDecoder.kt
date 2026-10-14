package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReviewSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.LlmRubricCriterion
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText

/** Recover, strictly validate, then build domain values. Content issues remain on drafts. */
object LlmOutputDecoder {
    fun artifact(output: String): LlmArtifact {
        val objectValue = validated(output, LlmSchemas.artifact)
        val names = mutableSetOf<String>()
        val fields = objectValue.member("fields").array().map { field ->
            val name = field.member("name").string()
            if (!names.add(UnicodeText.nfc(name))) throw AssistantError.InvalidOutput
            val type = FieldKind.entries.firstOrNull { it.rawValue == field.member("type").string() }
                ?: throw AssistantError.InvalidOutput
            LlmArtifact.Field(name, type, field.member("label").string(), field.member("description").string(),
                field.member("default").string(), field.member("options").array().map {
                    FieldOption(it.member("label").string(), it.member("value").string())
                }, field.member("optional").boolean(), field.member("remember").boolean())
        }
        return LlmArtifact(objectValue.member("title").string(), objectValue.member("description").string(),
            objectValue.member("tags").array().map { it.string() }, fields,
            objectValue.member("body").string(), objectValue.member("notes").string())
    }

    fun review(output: String, source: String): LlmReview {
        if (source.length > Limits.maxPromptBytes) throw AssistantError.InvalidOutput
        val sourceBytes = scalarBytes(source)
        if (sourceBytes.size > Limits.maxPromptBytes) throw AssistantError.InvalidOutput
        val objectValue = validated(output, LlmSchemas.review)
        val findings = objectValue.member("findings").array().map { finding ->
            val quote = finding.member("quote").string()
            val criterion = LlmRubricCriterion.entries.firstOrNull { it.rawValue == finding.member("criterion").string() }
                ?: throw AssistantError.InvalidOutput
            val severity = LlmReviewSeverity.entries.firstOrNull { it.rawValue == finding.member("severity").string() }
                ?: throw AssistantError.InvalidOutput
            val quoteBytes = scalarBytes(quote)
            val start = firstOccurrence(sourceBytes, quoteBytes)
            val match = if (start == null) LlmReview.QuoteMatch.Unmatched
                else LlmReview.QuoteMatch.Matched(start, start + quoteBytes.size)
            LlmReview.Finding(criterion, severity, quote, finding.member("problem").string(),
                finding.member("suggestion").string(), match)
        }
        return LlmReview(objectValue.member("summary").string(), findings)
    }

    private fun validated(output: String, schema: LlmSchema): LlmJsonValue =
        LlmJsonParser(LlmJsonRecovery.objectIn(output)).parse().also { schema.validate(it) }

    // KMP keeps adversarial repeated-byte quotes bounded by source + quote length.
    private fun firstOccurrence(source: ByteArray, quote: ByteArray): Int? {
        if (quote.isEmpty() || quote.size > source.size) return null
        val prefix = IntArray(quote.size)
        var matched = 0
        for (index in 1 until quote.size) {
            while (matched > 0 && quote[index] != quote[matched]) matched = prefix[matched - 1]
            if (quote[index] == quote[matched]) matched++
            prefix[index] = matched
        }
        matched = 0
        for (index in source.indices) {
            while (matched > 0 && source[index] != quote[matched]) matched = prefix[matched - 1]
            if (source[index] == quote[matched]) matched++
            if (matched == quote.size) return index - matched + 1
        }
        return null
    }
}
