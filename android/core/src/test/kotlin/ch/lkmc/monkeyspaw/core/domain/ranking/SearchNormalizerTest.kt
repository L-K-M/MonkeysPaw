package ch.lkmc.monkeyspaw.core.domain.ranking

import com.ibm.icu.lang.UCharacter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class SearchNormalizerTest {
    @Test
    fun `search uses Unicode 17 full C F folding followed by NFC`() {
        assertEquals(17, UCharacter.getUnicodeVersion().major)
        assertEquals("strasse σ é i\u0307", SearchNormalizer.normalize("Straße Σ E\u0301 İ"))
        assertEquals("ᎠᏵᎠᏵ", SearchNormalizer.normalize("ᎠᏵꭰᏽ"))
        assertEquals("ii\u0307ssı σσ ᎠᎠ вᲊ \u0264\uA7CD \uD803\uDD70\uD81B\uDEBB",
            SearchNormalizer.normalize("Iİẞı Σς ꭰᎠ ᲀᲉ \uA7CB\uA7CC \uD803\uDD50\uD81B\uDEA0"))
        assertEquals("αὶ", SearchNormalizer.normalize("Α\u0345\u0300"))
        assertEquals("ὰι", SearchNormalizer.normalize("Α\u0300\u0345"))
    }

    @Test
    fun `grapheme separators swallow their marks while marked hash is ordinary text`() {
        val query = SearchQuery("ab\u00a0\u0301cd #CODE #\u0301ab")
        assertEquals(listOf("ab", "cd", "#\u0301ab"), query.terms.map { String(it, 0, it.size) })
        assertEquals(listOf("code"), query.tags)
        assertEquals(true, SearchQuery("\u00a0\u0301\t\r\n").isEmpty)
        val newMarks = SearchQuery("ab\u00a0\u1ACFcd #CODE #\u1ACFab")
        assertEquals(listOf("ab", "cd", "#\u1ACFab"), newMarks.terms.map { String(it, 0, it.size) })
        assertEquals(listOf("code"), newMarks.tags)
        assertEquals(true, SearchQuery("\u00a0\u1ACF\t\r\n").isEmpty)
        assertEquals(2, SearchQuery("ab\n\u0301cd").terms.size)
    }

    @Test
    fun `NFC orders every decomposed mark and preserves valid Hangul boundaries`() {
        assertEquals("q\u0f71\u0f71\u0f72\u0f72", SearchNormalizer.normalize("q\u0f73\u0f73"))
        assertEquals("q" + "\u0308\u0301".repeat(33), SearchNormalizer.normalize("q" + "\u0344".repeat(33)))
        assertEquals("q" + "\u0316".repeat(100) + "\u0300".repeat(100),
            SearchNormalizer.normalize("q" + "\u0316\u0300".repeat(100)))
        assertEquals("각", SearchNormalizer.normalize("\u1100\u1161\u11A8"))
        assertEquals("\u1113\u1175", SearchNormalizer.normalize("\u1113\u1175"))
        assertEquals("\uD801\uDDC9", SearchNormalizer.normalize("\uD801\uDDD2\u0307"))
        assertEquals(SearchNormalizer.normalize("q\u0f73\u0f73"), SearchNormalizer.normalize("q\u0f71\u0f71\u0f72\u0f72"))
    }

    @Test
    fun `word classes include Unicode 17 letters and marks but exclude private use`() {
        for (prefix in listOf("Ᲊ", "\uD803\uDD50", "\uD81C\uDC00", "\u1ACF", "\uD81B\uDEA0", "\uD888\uDFB0")) {
            assertEquals(listOf(true, false), FuzzyText(prefix + "b").wordStarts.toList())
        }
        assertEquals(listOf(true, true), FuzzyText("\uF870b").wordStarts.toList())
    }

    @Test
    fun `unpaired surrogates are rejected instead of repaired`() {
        for (invalid in listOf("\uD800", "\uDC00")) {
            assertFailsWith<IllegalArgumentException> { SearchNormalizer.normalize(invalid) }
        }
    }
}
