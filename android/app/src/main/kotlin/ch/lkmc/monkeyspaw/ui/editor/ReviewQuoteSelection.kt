package ch.lkmc.monkeyspaw.ui.editor

import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import java.nio.charset.CharacterCodingException

/** Native selection offsets, never byte offsets or persisted editor state. */
internal data class ReviewQuoteSelection(val start: Int, val endExclusive: Int)

/** Recheck the exact quote and both scalar boundaries before converting UTF-8 to UTF-16. */
internal fun reviewQuoteSelection(source: String, quote: String, range: LlmReview.QuoteMatch.Matched): ReviewQuoteSelection? {
    return try {
        val bytes = source.encodeToByteArray(throwOnInvalidSequence = true)
        val quoted = quote.encodeToByteArray(throwOnInvalidSequence = true)
        val start = range.startByte
        val end = range.endByteExclusive
        if (start < 0 || end <= start || end > bytes.size ||
            !bytes.copyOfRange(start, end).contentEquals(quoted)) return null
        val prefix = bytes.decodeToString(endIndex = start, throwOnInvalidSequence = true)
        val matched = bytes.decodeToString(startIndex = start, endIndex = end, throwOnInvalidSequence = true)
        ReviewQuoteSelection(prefix.length, prefix.length + matched.length)
    } catch (error: CharacterCodingException) { null }
}
