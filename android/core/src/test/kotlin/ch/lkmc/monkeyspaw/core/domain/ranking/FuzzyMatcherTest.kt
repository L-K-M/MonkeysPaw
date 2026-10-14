package ch.lkmc.monkeyspaw.core.domain.ranking

import kotlin.test.Test
import kotlin.test.assertEquals

class FuzzyMatcherTest {
    @Test
    fun `optimal scores agree with an exhaustive alignment oracle`() {
        var frontier = listOf("")
        val texts = frontier.toMutableList()
        repeat(4) {
            frontier = frontier.flatMap { prefix -> listOf("a", "b", " ").map { prefix + it } }
            texts.addAll(frontier)
        }
        for (text in texts) {
            for (term in listOf("a", "b", "aa", "ab", "ba", "bb", "aaa", "aba", "bab", "bbb")) {
                val raw = positions(term, text).maxOfOrNull { indices ->
                    val starts = indices.count { it == 0 || text[it - 1] == ' ' }
                    val consecutive = indices.zipWithNext().count { (one, two) -> two == one + 1 }
                    term.length + 2 * starts + consecutive
                }
                val actual = FuzzyMatcher.score(term.codePoints().toArray(), FuzzyText(text))
                if (raw == null) {
                    assertEquals(null, actual, "$term in $text")
                } else {
                    val expected = raw.toDouble() / (4 * term.length - 1) * (1 + term.length.toDouble() / text.length) / 2
                    assertEquals(expected, actual!!, 1e-12, "$term in $text")
                }
            }
        }
    }

    private fun positions(term: String, text: String, prefix: List<Int> = emptyList()): List<List<Int>> {
        if (prefix.size == term.length) return listOf(prefix)
        val start = prefix.lastOrNull()?.plus(1) ?: 0
        return (start until text.length).filter { text[it] == term[prefix.size] }
            .flatMap { positions(term, text, prefix + it) }
    }
}
