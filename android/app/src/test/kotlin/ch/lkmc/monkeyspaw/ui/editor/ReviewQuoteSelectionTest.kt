package ch.lkmc.monkeyspaw.ui.editor

import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview.QuoteMatch.Matched
import kotlin.test.*

internal class ReviewQuoteSelectionTest {
    @Test fun `checked ranges convert exact scalar boundaries without normalizing combining marks`() {
        val source = "😀 e\u0301\r\nCafe\u0301 🙂 tail"
        for (quote in listOf("😀", "e\u0301", "\u0301", "Cafe\u0301", "🙂", " tail")) {
            val start = source.indexOf(quote)
            val byteStart = source.substring(0, start).encodeToByteArray().size
            assertEquals(ReviewQuoteSelection(start, start + quote.length),
                reviewQuoteSelection(source, quote, Matched(byteStart, byteStart + quote.encodeToByteArray().size)))
        }
    }

    @Test fun `unverified out of bounds empty mismatched partial scalar and malformed UTF16 ranges refuse selection`() {
        val source = "😀 Cafe\u0301"
        for (range in listOf(Matched(-1, 4), Matched(0, Int.MAX_VALUE), Matched(4, 0), Matched(0, 0), Matched(1, 4), Matched(0, 3))) {
            assertNull(reviewQuoteSelection(source, "😀", range))
        }
        assertNull(reviewQuoteSelection(source, "Café", Matched(5, source.encodeToByteArray().size)))
        assertNull(reviewQuoteSelection("\uD800 quote", "quote", Matched(2, 7)))
        assertNull(reviewQuoteSelection("?", "\uD800", Matched(0, 1)))
        assertNull(reviewQuoteSelection(source, "", Matched(4, 4)))
    }
}
