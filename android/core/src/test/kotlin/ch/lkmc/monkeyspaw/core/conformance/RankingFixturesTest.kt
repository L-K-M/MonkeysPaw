package ch.lkmc.monkeyspaw.core.conformance

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

class RankingFixturesTest {
    @Test
    fun `every ranking fixture is consumed with structural accounting`() {
        val corpus = Corpus.load()
        val cases = corpus.cases(Category.RANKING)
        assertTrue(cases.isNotEmpty())
        val files = RankingFixtures.consume(corpus)
        assertEquals(cases.flatMap { it.files }.map { it.relativePath }.toSet(), files)
        println("Consumed ${cases.size} ranking fixtures (${files.size} files).")
    }

    @Test
    fun `wrong result order score or field order fails semantic consumption`() {
        val fixture = fixture("term-average")
        val results = fixture.expected["results"].arrayValue()
        assertFails { RankingFixtures.check(withResults(fixture, results.reversed())) }
        val first = results.first().objectValue()
        for ((member, value) in mapOf("score" to JsonPrimitive(first["score"].numberValue() + "0.000000000002".toBigDecimal()),
            "matchedFields" to JsonArray(first["matchedFields"].arrayValue().reversed()))) {
            assertFails {
                RankingFixtures.check(withResults(fixture, listOf(JsonObject(first + (member to value))) + results.drop(1)))
            }
        }
    }

    @Test
    fun `absolute score tolerance accepts at most one trillionth`() {
        val fixture = fixture("frecency-cap")
        val results = fixture.expected["results"].arrayValue()
        val first = results.first().objectValue()
        fun adjusted(delta: String): FixtureCase = withResults(fixture,
            listOf(JsonObject(first + ("score" to JsonPrimitive(first["score"].numberValue() + delta.toBigDecimal())))) + results.drop(1))
        RankingFixtures.check(adjusted("0.0000000000005"))
        assertFails { RankingFixtures.check(adjusted("0.000000000002")) }
    }

    @Test
    fun `canonical equivalent result path bytes cannot pass`() {
        val fixture = fixture("nonempty-byte-ties")
        val results = fixture.expected["results"].arrayValue()
        val changed = results.map { value ->
            val result = value.objectValue()
            if (result["path"].stringValue() == "e\u0301.md") {
                JsonObject(result + ("path" to JsonPrimitive("é.md")))
            } else result
        }
        assertFails { RankingFixtures.check(withResults(fixture, changed)) }
    }

    private fun fixture(name: String): FixtureCase = Corpus.load().cases(Category.RANKING).single { it.name == name }

    private fun withResults(fixture: FixtureCase, results: List<kotlinx.serialization.json.JsonElement>): FixtureCase =
        fixture.copy(envelope = JsonObject(fixture.envelope +
            ("expected" to JsonObject(mapOf("results" to JsonArray(results))))))
}
