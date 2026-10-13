package ch.lkmc.monkeyspaw.core.domain.ranking

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class SearchNormalizerTest {
    @Test
    fun `comparison folding preserves Swift differences from full sync folding`() {
        assertEquals("strasse σ é i\u0307", SearchNormalizer.normalize("Straße Σ E\u0301 İ"))
        assertEquals("ꭰᏽꭰᏽ", SearchNormalizer.normalize("ᎠᏵꭰᏽ"))
        val unchanged = "\u1c80\u1c89\ua7cb\ua7cc\ua7ce\ua7d2\ua7d4\ua7da\ua7dc\uD803\uDD50\uD81B\uDEA0"
        assertEquals(unchanged, SearchNormalizer.normalize(unchanged))
        assertEquals("αὶ", SearchNormalizer.normalize("Α\u0345\u0300"))
        assertEquals("ὰι", SearchNormalizer.normalize("Α\u0300\u0345"))
    }

    @Test
    fun `grapheme separators swallow their marks while marked hash is ordinary text`() {
        val query = SearchQuery("ab\u00a0\u0301cd #CODE #\u0301ab")
        assertEquals(listOf("ab", "cd", "#\u0301ab"), query.terms.map { String(it, 0, it.size) })
        assertEquals(listOf("code"), query.tags)
        assertEquals(true, SearchQuery("\u00a0\u0301\t\r\n").isEmpty)
    }

    @Test
    fun `Foundation normalization keeps original class boundaries and expanding mark limit`() {
        assertEquals("q\u0f71\u0f72\u0f71\u0f72", SearchNormalizer.normalize("q\u0f73\u0f73"))
        assertEquals("q" + "\u0308\u0301".repeat(31), SearchNormalizer.normalize("q" + "\u0344".repeat(33)))
        assertEquals("q" + "\u0316".repeat(100) + "\u0300".repeat(100),
            SearchNormalizer.normalize("q" + "\u0316\u0300".repeat(100)))
        assertEquals("\uFFFD", SearchNormalizer.normalize("\u1113\u1175"))
        assertEquals(SearchNormalizer.tagKey("q\u0f73\u0f73"), SearchNormalizer.tagKey("q\u0f71\u0f71\u0f72\u0f72"))
    }

    @Test
    fun `unpaired surrogates are rejected instead of repaired`() {
        for (invalid in listOf("\uD800", "\uDC00")) {
            assertFailsWith<IllegalArgumentException> { SearchNormalizer.normalize(invalid) }
        }
    }
}
