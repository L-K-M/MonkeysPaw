package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class LlmDiffConformanceTest {
    @Test fun everyDiffFixtureIsConsumed() {
        val coverage = LlmFixtureConsumer.consume(Corpus.load().cases(Category.LLM).filter { it.envelope["kind"].stringValue() == "diff" })
        println("diff: ${coverage.cases} cases / ${coverage.files.size} files; ${coverage.expectations} expectations; pending 0.")
    }

    @Test fun changedRowsWarningsAndTypedErrorsCannotPass() {
        val fixtures = Corpus.load().cases(Category.LLM)
        val original = fixtures.single { it.name == "diff-lines-composed-decomposed" }
        for ((key, value) in listOf("text" to JsonPrimitive("e\u0301\n"), "originalLine" to JsonPrimitive(2),
            "placeholderWarnings" to JsonArray(listOf(buildJsonObject { put("kind", "removed"); put("name", "fake") })),
            "unconsumed" to JsonPrimitive(true))) {
            val rows = original.expected["rows"].arrayValue().toMutableList()
            rows[0] = JsonObject(rows[0].objectValue() + (key to value))
            val expected = JsonObject(original.expected + ("rows" to JsonArray(rows)))
            val mutation = original.copy(envelope = JsonObject(original.envelope + ("expected" to expected)))
            if (key == "unconsumed") assertFailsWith<CorpusException> { LlmFixtureConsumer.consume(listOf(mutation)) }
            else assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(mutation)) }
        }
        for ((name, key, value) in listOf(
            Triple("diff-artifact-rename", "placeholderWarnings", JsonArray(emptyList())),
            Triple("diff-artifact-rename", "body", JsonArray(emptyList())),
            Triple("diff-lines-work-over-limit", "error", JsonPrimitive("sourceTooLarge")),
        )) {
            val fixture = fixtures.single { it.name == name }
            val mutation = fixture.copy(envelope = JsonObject(fixture.envelope +
                ("expected" to JsonObject(fixture.expected + (key to value)))))
            assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(mutation)) }
        }
    }

    @Test fun closedReferencesRepeatsAndWarningsAreEnforced() {
        val original = Corpus.load().cases(Category.LLM).single { it.name == "diff-lines-empty" }
        for ((key, value) in listOf("originalRepeat" to JsonPrimitive(false), "mergedRepeat" to JsonPrimitive(0),
            "mergedRepeat" to JsonPrimitive(262146), "original" to JsonPrimitive("../original.txt"), "operation" to JsonPrimitive("future"))) {
            assertFailsWith<CorpusException> { LlmFixtureContracts.read(JsonObject(original.envelope + (key to value))) }
        }
        val rename = Corpus.load().cases(Category.LLM).single { it.name == "diff-artifact-rename" }
        val warnings = rename.expected["placeholderWarnings"].arrayValue().toMutableList()
        warnings[0] = JsonObject(warnings[0].objectValue() + ("unconsumed" to JsonNull))
        val expected = JsonObject(rename.expected + ("placeholderWarnings" to JsonArray(warnings)))
        assertFailsWith<CorpusException> {
            LlmFixtureConsumer.consume(listOf(rename.copy(envelope = JsonObject(rename.envelope + ("expected" to expected)))))
        }
    }

    @Test fun bothCanonicalByteGoldensAreConsumed() {
        val fixture = Corpus.load().cases(Category.LLM).single { it.name == "diff-artifact-utf8-token-offsets" }
        val temporary = Files.createTempFile("llm-diff-", ".md")
        try {
            Files.writeString(temporary, "wrong bytes")
            for (name in listOf("candidate.md", "original-canonical.md")) {
                val sources = fixture.sources + (name to fixture.source(name).copy(path = temporary))
                assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(fixture.copy(sources = sources))) }
            }
        } finally { Files.delete(temporary) }
    }
}
