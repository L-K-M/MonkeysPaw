package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueLocation
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantOutput
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import ch.lkmc.monkeyspaw.core.llm.LlmJsonParser
import ch.lkmc.monkeyspaw.core.llm.LlmJsonRecovery
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal object LlmFixtureConsumer {
    data class Coverage(val cases: Int, val files: Set<String>, val expectations: Int)

    fun consume(fixtures: List<FixtureCase>): Coverage {
        val consumed = linkedSetOf<String>()
        var expectations = 0
        for (fixture in fixtures) {
            val label = fixture.envelopeFile.relativePath
            LlmFixtureContracts.read(fixture.envelope) // Recheck mutated expectations at semantic entry.
            corpusRequire(consumed.add(label), "Duplicate LLM envelope consumption")
            fun bytes(name: String): ByteArray {
                val file = fixture.source(name)
                corpusRequire(consumed.add(file.relativePath), "Duplicate LLM source consumption")
                return file.bytes()
            }
            val envelope = fixture.envelope
            if (envelope["kind"].stringValue() == "exchange") {
                expectations += LlmExchangeConsumer.consume(envelope, ::bytes)
                continue
            }
            val expected = fixture.expected
            val kind = envelope["kind"].stringValue()
            if (kind == "merge") {
                assertEquals(typedIntegers(expected), LlmMergeFixtures.consume(envelope, ::bytes), "$label merge result")
            } else if (kind == "schema") {
                val outputKind = envelope["outputKind"].stringValue()
                val actual = if (outputKind == "artifact") LlmArtifact.jsonSchema else LlmReview.jsonSchema
                assertBytesEqual(bytes(expected["bytes"].stringValue()), actual, "$label schema bytes")
            } else {
                val outputKind = envelope["outputKind"].stringValue()
                val sourceName = envelope["source"].stringValue()
                val sourceBytes = bytes(sourceName)
                var output = if (sourceName.endsWith(".bin")) swiftReplacementUtf8(sourceBytes) else strictUtf8(sourceBytes)
                envelope["prefix"]?.objectValue()?.let { prefix ->
                    val text = strictUtf8(bytes(prefix["source"].stringValue()))
                    output = expanded(text, prefix["repeat"].integerValue().intValueExact(), Limits.responseCap + 1) + output
                }
                corpusRequire(output.toByteArray(Charsets.UTF_8).size <= Limits.responseCap + 1, "Expanded LLM output too large")
                val reviewed = if (outputKind == "review") {
                    expanded(strictUtf8(bytes(envelope["reviewedSource"].stringValue())),
                        envelope["reviewedRepeat"]?.integerValue()?.intValueExact() ?: 1, Limits.maxPromptBytes + 1)
                } else ""
                val recovered = try { LlmJsonRecovery.objectIn(output) } catch (_: AssistantError.InvalidOutput) { null }
                if (expected["recovered"] == JsonNull) assertNull(recovered, "$label recovery")
                else assertBytesEqual(bytes(expected["recovered"].stringValue()),
                    recovered ?: error("Expected recovered object in $label"), "$label recovered bytes")
                val parsed = recovered != null && try { LlmJsonParser(recovered).parse(); true }
                    catch (_: AssistantError.InvalidOutput) { false }
                assertEquals(expected["parsed"].booleanValue(), parsed, "$label JSON validity")
                // One complete, typed snapshot equality consumes every nested expectation, including empty arrays/nulls.
                assertEquals(typedIntegers(expected["result"]!!), snapshot(output, reviewed, outputKind), "$label typed result")
            }
            expectations += countExpectations(expected)
        }
        assertEquals(fixtures.flatMap { it.files }.map { it.relativePath }.toSet(), consumed, "LLM file consumption")
        return Coverage(fixtures.size, consumed, expectations)
    }

    private fun expanded(text: String, count: Int, cap: Int): String {
        corpusRequire(count in 1..cap && text.toByteArray(Charsets.UTF_8).size <= cap / count, "Invalid LLM expansion")
        return text.repeat(count)
    }

    private fun snapshot(output: String, reviewed: String, outputKind: String): JsonObject = try {
        snapshot(if (outputKind == "artifact") AssistantOutput.Artifact(LlmOutputDecoder.artifact(output))
            else AssistantOutput.Review(LlmOutputDecoder.review(output, reviewed)))
    } catch (_: AssistantError.InvalidOutput) { buildJsonObject { put("error", "invalidOutput") } }

    fun snapshot(output: AssistantOutput): JsonObject = when (output) {
        is AssistantOutput.Artifact -> {
            val artifact = output.value
            buildJsonObject {
                put("artifact", buildJsonObject {
                    put("title", artifact.title); put("description", artifact.description)
                    put("tags", JsonArray(artifact.tags.map(::JsonPrimitive)))
                    put("fields", JsonArray(artifact.fields.map { field -> buildJsonObject {
                        put("name", field.name); put("type", field.type.rawValue); put("label", field.label)
                        put("description", field.description); put("default", field.defaultValue)
                        put("options", JsonArray(field.options.map { buildJsonObject {
                            put("label", it.label); put("value", it.value)
                        } }))
                        put("optional", field.optional); put("remember", field.remember)
                    } }))
                    put("body", artifact.body); put("notes", artifact.notes)
                })
                put("issues", JsonArray(artifact.issues.map { issue -> buildJsonObject {
                    put("code", issue.code.rawValue); put("severity", issue.severity.rawValue)
                    put("location", when (val location = issue.location) {
                        null -> JsonNull
                        is PromptIssueLocation.Body -> buildJsonObject { put("bodyByteOffset", location.byteOffset) }
                        is PromptIssueLocation.FrontMatter -> buildJsonObject { put("line", location.line); put("column", location.column) }
                    })
                } }))
            }
        }
        is AssistantOutput.Review -> {
            val review = output.value
            buildJsonObject { put("review", buildJsonObject {
                put("summary", review.summary)
                put("findings", JsonArray(review.findings.map { finding -> buildJsonObject {
                    put("severity", finding.severity.rawValue); put("criterion", finding.criterion.rawValue)
                    put("quote", finding.quote); put("problem", finding.problem); put("suggestion", finding.suggestion)
                    put("quoteMatch", when (val match = finding.quoteMatch) {
                        LlmReview.QuoteMatch.Unmatched -> JsonNull
                        is LlmReview.QuoteMatch.Matched -> buildJsonObject {
                            put("startByte", match.startByte); put("endByteExclusive", match.endByteExclusive)
                        }
                    })
                } }))
            }) }
        }
    }

    // Swift's typed Int decoding accepts integer-valued numeric spellings such as 1.0.
    private fun typedIntegers(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> JsonObject(value.mapValues { typedIntegers(it.value) })
        is JsonArray -> JsonArray(value.map(::typedIntegers))
        is JsonPrimitive -> if (value.isString || value == JsonNull || value.booleanOrNull != null) value
            else JsonPrimitive(value.integerValue())
    }

    private fun countExpectations(value: JsonElement): Int = when (value) {
        is JsonObject -> value.size + value.values.sumOf(::countExpectations)
        is JsonArray -> value.sumOf(::countExpectations)
        else -> 0
    }
}

internal class LlmConformanceTest {
    @Test fun everyLlmExpectationAndByteGoldenIsExecuted() {
        val coverage = LlmFixtureConsumer.consume(Corpus.load().cases(Category.LLM))
        println("llm: ${coverage.cases} cases / ${coverage.files.size} files; ${coverage.expectations} expectations; pending 0.")
    }

    @Test fun everyMergeExpectationAndClosedContractIsEnforced() {
        val fixtures = Corpus.load().cases(Category.LLM)
        val original = fixtures.single { it.name == "merge-improve-typed-metadata" }
        val ready = original.expected["ready"].objectValue()
        val pair = ready["preserved"].arrayValue().first().objectValue()
        val badNode = JsonObject(pair["value"].objectValue() + ("unconsumed" to JsonPrimitive(true)))
        val badPair = JsonObject(pair + ("value" to badNode))
        for ((altered, structural) in listOf(
            JsonObject(ready + ("id" to JsonNull)) to false,
            JsonObject(ready + ("issues" to JsonArray(listOf(buildJsonObject {
                put("code", "field.unused"); put("severity", "warning"); put("location", JsonNull)
            })))) to false,
            JsonObject(ready + ("preserved" to JsonArray(emptyList()))) to false,
            JsonObject(ready + ("preserved" to JsonArray(listOf(badPair)))) to true,
        )) {
            val expected = JsonObject(mapOf("ready" to altered))
            val mutation = original.copy(envelope = JsonObject(original.envelope + ("expected" to expected)))
            if (structural) assertFailsWith<CorpusException> { LlmFixtureConsumer.consume(listOf(mutation)) }
            else assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(mutation)) }
        }
        for ((key, value) in listOf("id" to JsonPrimitive("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"),
            "operation" to JsonPrimitive("copy"), "originalRepeat" to JsonPrimitive(false),
            "artifactBodyRepeat" to JsonPrimitive(0), "artifactBodyRepeat" to JsonPrimitive(262146))) {
            assertFailsWith<CorpusException> { LlmFixtureContracts.read(JsonObject(original.envelope + (key to value))) }
        }
        for ((name, altered) in listOf(
            "merge-invalid-original-priority" to buildJsonObject { put("invalid", JsonArray(emptyList())) },
            "merge-write-cap-header" to buildJsonObject { put("failed", buildJsonObject { put("error", "serializationFailed") }) },
        )) {
            val fixture = fixtures.single { it.name == name }
            val mutation = fixture.copy(envelope = JsonObject(fixture.envelope + ("expected" to altered)))
            assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(mutation)) }
        }
    }

    @Test fun unconsumedNestedExpectationsAndChangedGoldensCannotPass() {
        val fixtures = Corpus.load().cases(Category.LLM)
        val original = fixtures.first { it.name == "artifact-all-fields" }
        val result = original.expected["result"].objectValue()
        val artifact = result["artifact"].objectValue()
        for ((index, altered) in listOf(
            JsonObject(artifact + ("unconsumed" to JsonPrimitive(true))),
            JsonObject(artifact + ("notes" to JsonPrimitive("wrong golden"))),
        ).withIndex()) {
            val expected = JsonObject(original.expected + ("result" to JsonObject(result + ("artifact" to altered))))
            val mutation = original.copy(envelope = JsonObject(original.envelope + ("expected" to expected)))
            if (index == 0) assertFailsWith<CorpusException> { LlmFixtureConsumer.consume(listOf(mutation)) }
            else assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(mutation)) }
        }
    }

    @Test fun falseSchemaBytesAndChangedIssuesOrQuoteRangesCannotPass() {
        val fixtures = Corpus.load().cases(Category.LLM)
        val schema = fixtures.first { it.name == "schema-artifact" }
        val originalFile = schema.source("schema.json")
        val temporary = Files.createTempFile("llm-schema-", ".json")
        try {
            Files.writeString(temporary, "{}")
            val mutated = schema.copy(sources = mapOf("schema.json" to originalFile.copy(path = temporary)))
            assertFailsWith<AssertionError> { LlmFixtureConsumer.consume(listOf(mutated)) }
        } finally { Files.delete(temporary) }

        val artifact = fixtures.first { it.name == "artifact-ordered-issues" }
        val result = artifact.expected["result"].objectValue()
        val expected = JsonObject(artifact.expected + ("result" to JsonObject(result + ("issues" to JsonArray(emptyList())))))
        assertFailsWith<AssertionError> {
            LlmFixtureConsumer.consume(listOf(artifact.copy(envelope = JsonObject(artifact.envelope + ("expected" to expected)))))
        }
        val review = fixtures.first { it.name == "review-utf8-ranges" }
        val reviewResult = review.expected["result"].objectValue()
        val output = reviewResult["review"].objectValue()
        val findings = output["findings"].arrayValue().toMutableList()
        findings[0] = JsonObject(findings[0].objectValue() + ("quoteMatch" to JsonNull))
        val altered = JsonObject(output + ("findings" to JsonArray(findings)))
        val alteredExpected = JsonObject(review.expected + ("result" to JsonObject(reviewResult + ("review" to altered))))
        assertFailsWith<AssertionError> {
            LlmFixtureConsumer.consume(listOf(review.copy(envelope = JsonObject(review.envelope + ("expected" to alteredExpected)))))
        }
    }
}
