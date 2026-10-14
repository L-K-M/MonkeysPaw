package ch.lkmc.monkeyspaw.core.domain.ranking

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PromptRankingTest {
    @Test
    fun `sorting compares exact scores even inside fixture tolerance`() {
        val now = Instant.parse("2026-10-11T12:00:00Z")
        val document = PromptCodec.parse("---\ntitle: n\n---\n", "n.md")
        val earlier = PromptRanking.Input("a.md", document, listOf(now.minusNanos(100)))
        val later = PromptRanking.Input("z.md", document, listOf(now))
        val results = PromptRanking.rank(listOf(earlier, later), "n", now)
        assertEquals(listOf("z.md", "a.md"), results.map { it.relativePath })
        assertTrue(results[0].score > results[1].score && results[0].score - results[1].score < 1e-12)
    }

    @Test
    fun `usage snapshots preserve duplicates fractional ages and recording order`() {
        val now = Instant.parse("2026-10-11T12:00:00Z")
        val halfLife = 14 * 86_400L
        val expected = 1 + kotlin.math.sqrt(0.5) + 0.5 + 0.25 + 1.0 / 1024
        assertEquals(expected, PromptRanking.frecency(listOf(now, now.minusSeconds(halfLife / 2),
            now.minusSeconds(halfLife), now.minusSeconds(2 * halfLife), now.minusSeconds(10 * halfLife)), now), 1e-12)
        val events = mutableListOf(now.plusSeconds(1), now.minusSeconds(halfLife), now.minusSeconds(halfLife))
        val input = PromptRanking.Input("a.md", PromptCodec.parse("Body", "a.md"), events)
        events.clear()
        assertEquals(listOf(now.plusSeconds(1), now.minusSeconds(halfLife), now.minusSeconds(halfLife)), input.useEvents)
        assertEquals(2.0, PromptRanking.rank(listOf(input), "", now).single().score)
    }
}
