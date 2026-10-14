package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import java.time.Instant
import ch.lkmc.monkeyspaw.core.llm.AssistantHTTP
import ch.lkmc.monkeyspaw.core.ports.HttpMethod
import ch.lkmc.monkeyspaw.core.ports.HttpRequest
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertFails
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.*

internal class LlmExchangeConformanceTest {
    @Test fun closedMembersAndChangedRequestAndResultExpectationsCannotPass() {
        val fixture = Corpus.load().cases(Category.LLM).single { it.name == "anthropic-write-official-unset" }
        val paths = listOf(emptyList(), listOf("setup"), listOf("actions", "0"), listOf("actions", "0", "profile"), listOf("actions", "0", "intent"),
            listOf("actions", "0", "exchanges", "0"), listOf("actions", "0", "exchanges", "0", "request"),
            listOf("actions", "0", "exchanges", "0", "response"), listOf("actions", "0", "expected"), listOf("actions", "0", "expected", "cache"))
        for (path in paths) {
            val altered = replace(fixture.envelope, path) { JsonObject(it.objectValue() + ("unconsumed" to JsonPrimitive(true))) }
            assertFailsWith<CorpusException>(path.joinToString("/")) { LlmFixtureConsumer.consume(listOf(fixture.copy(envelope = altered.objectValue()))) }
        }
        val changes = listOf(
            listOf("schema") to JsonPrimitive(true), listOf("setup", "nowMonotonicMs") to JsonPrimitive(false),
            listOf("setup", "capabilityState") to JsonObject(emptyMap()), listOf("actions", "0", "budgetMs") to JsonPrimitive(false),
            listOf("actions", "0", "exchanges", "0", "request", "deadlineMs") to JsonPrimitive(299999),
            listOf("actions", "0", "exchanges", "0", "request", "requestByteCap") to JsonPrimitive(3000000),
            listOf("actions", "0", "exchanges", "0", "request", "headers", "authorization") to JsonPrimitive("Bearer fixture-only"),
            listOf("actions", "0", "expected", "requestCount") to JsonPrimitive(2),
            listOf("actions", "0", "intent", "brief") to JsonPrimitive("../brief.txt"),
            listOf("actions", "0", "expected", "cache", "writes") to JsonPrimitive(1),
        )
        for ((path, value) in changes) {
            val altered = replace(fixture.envelope, path) { value }
            assertFails(path.joinToString("/")) { LlmFixtureConsumer.consume(listOf(fixture.copy(envelope = altered.objectValue()))) }
        }
    }

    @Test fun rawByteGoldensAndNestedTypedOutputGoldensAreChecked() {
        val fixture = Corpus.load().cases(Category.LLM).single { it.name == "anthropic-write-official-unset" }
        val temporary = Files.createTempFile("llm-exchange-", ".json")
        try {
            Files.writeString(temporary, "{}")
            for (name in listOf("1-request.json", "1-expected.json")) {
                val file = fixture.source(name)
                val altered = fixture.copy(sources = fixture.sources + (name to file.copy(path = temporary)))
                assertFails { LlmFixtureConsumer.consume(listOf(altered)) }
            }
        } finally { Files.delete(temporary) }
    }

    @Test fun missingBodyCannotBecomeAnExpectedNetworkFailure() = runBlocking<Unit> {
        val request = HttpRequest("https://fixture.example", HttpMethod.POST, deadlineNanos = 1)
        val transport = HttpTransport { actual ->
            LlmExchangeConsumer.assertRequestBody("{}".toByteArray(), actual.body)
            throw HttpTransportError.NetworkFailure
        }
        assertFailsWith<AssertionError> {
            AssistantHTTP.send(request, transport, { Instant.parse("2026-10-13T00:00:00Z") })
        }
    }

    private fun replace(value: JsonElement, path: List<String>, transform: (JsonElement) -> JsonElement): JsonElement {
        if (path.isEmpty()) return transform(value)
        val key = path.first()
        return if (value is JsonArray) JsonArray(value.mapIndexed { index, item ->
            if (index == key.toInt()) replace(item, path.drop(1), transform) else item
        }) else JsonObject(value.objectValue() + (key to replace(value.objectValue()[key] ?: JsonNull, path.drop(1), transform)))
    }
}
