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
    fun `text relevance outranks usage and favorites`() {
        val now = Instant.parse("2026-10-11T12:00:00Z")
        val popular = List(40) { now }
        val title = PromptRanking.Input("title.md", PromptCodec.parse(
            "---\ntitle: Performance Improvements\ntags: [performance, code]\n---\n", "title.md"))
        val tag = PromptRanking.Input("tag.md", PromptCodec.parse(
            "---\ntitle: Improve App 2\ntags: [performance, code]\nfavorite: true\n---\n", "tag.md"), popular)
        val description = PromptRanking.Input("description.md", PromptCodec.parse(
            "---\ntitle: Improve App 3\ntags: [code]\ndescription: performance\nfavorite: true\n---\n", "description.md"), popular)
        val body = PromptRanking.Input("body.md", PromptCodec.parse(
            "---\ntitle: Improve App 1\ntags: [code]\nfavorite: true\n---\nperformance", "body.md"), popular)
        val inputs = listOf(body, tag, description, title)

        for (query in listOf("performance", "PERFORMANCE", "prfrmnc", "#code performance", "performance code")) {
            assertEquals(listOf("title.md", "tag.md", "description.md", "body.md"),
                PromptRanking.rank(inputs, query, now).map { it.relativePath }, query)
        }
        val results = PromptRanking.rank(inputs, "performance", now)
        assertTrue(results[0].score < results[3].score, "Adaptive scores must not override stronger text matches.")
        val adaptiveOrder = listOf("body.md", "tag.md", "description.md", "title.md")
        assertEquals(adaptiveOrder, PromptRanking.rank(inputs, "", now).map { it.relativePath })
        assertEquals(adaptiveOrder, PromptRanking.rank(inputs, "#code", now).map { it.relativePath })
    }

    @Test
    fun `stronger match within one field outranks popularity`() {
        val now = Instant.parse("2026-10-11T12:00:00Z")
        val exact = PromptRanking.Input("exact.md", PromptCodec.parse("---\ntitle: Review\n---\n", "exact.md"))
        val longer = PromptRanking.Input("longer.md", PromptCodec.parse(
            "---\ntitle: Review changes\nfavorite: true\n---\n", "longer.md"), List(40) { now })

        assertEquals(listOf("exact.md", "longer.md"),
            PromptRanking.rank(listOf(longer, exact), "review", now).map { it.relativePath })
        assertEquals(listOf("longer.md", "exact.md"),
            PromptRanking.rank(listOf(longer, exact), "", now).map { it.relativePath })
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
