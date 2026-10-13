package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.ranking.PromptRanking
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal object RankingFixtures {
    fun consume(corpus: Corpus): Set<String> {
        val consumed = linkedSetOf<String>()
        for (fixture in corpus.cases(Category.RANKING)) {
            check(fixture)
            for (file in fixture.files) {
                corpusRequire(consumed.add(file.relativePath), "Duplicate consumption of ${file.relativePath}")
            }
        }
        return consumed
    }

    fun check(fixture: FixtureCase) {
        val label = fixture.envelopeFile.relativePath
        val identities = mutableSetOf<Pair<String, String>>()
        val inputs = fixture.envelope["prompts"].arrayValue().map { value ->
            val prompt = value.objectValue()
            val path = prompt["path"].stringValue()
            val document = PromptCodec.parse(fixture.source(prompt["source"].stringValue()).utf8(),
                path.substringAfterLast('/'))
            corpusRequire(document.canRender, "Ranking source cannot render: $label")
            val id = document.frontMatter.id?.rawValue
            val identity = if (id == null) "path" to path else "id" to id
            corpusRequire(identities.add(identity), "Duplicate ranking identity: $label")
            // Like UsageStore, discard by recording position, never by timestamp order.
            val events = prompt["uses"].arrayValue().map { timestamp(it.stringValue()) }.takeLast(Limits.usageEventCap)
            PromptRanking.Input(path, document, events)
        }
        val actual = PromptRanking.rank(inputs, fixture.envelope["query"].stringValue(),
            timestamp(fixture.envelope["now"].stringValue()))
        val expected = fixture.expected["results"].arrayValue().map { it.objectValue() }
        assertEquals(expected.size, actual.size, "$label result count")
        for ((result, golden) in actual.zip(expected)) {
            assertUtf8Equal(golden["path"].stringValue(), result.relativePath, "$label result order")
            val score = golden["score"].numberValue().toDouble()
            assertTrue(result.score.isFinite() && abs(score - result.score) <= 1e-12,
                "$label ${result.relativePath}: expected $score, got ${result.score}")
            assertEquals(golden["matchedFields"].strings(), result.matchedFields.map { it.rawValue }, "$label matched fields")
        }
    }

    private fun timestamp(value: String): Instant {
        val date = LocalDateTime.parse(value, utcSeconds)
        corpusRequire(date.year in 1..9999 && utcSeconds.format(date) == value, "Noncanonical ranking UTC time")
        return date.toInstant(ZoneOffset.UTC)
    }

    private val utcSeconds = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT)
}
