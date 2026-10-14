package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.MemoryStore
import ch.lkmc.monkeyspaw.core.services.ProviderStateStore
import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
internal class OpenAIClientTest {
    private val request = AssistantRequest(AssistantAction.Write("Fixture brief"))
    private val artifact = """{"title":"Fixture","description":"","tags":[],"fields":[],"body":"Ready.","notes":""}"""
    private val utc = Instant.parse("2026-10-13T00:00:00Z")
    private val path = "provider-state.json"

    @Test fun ladderHasAtMostThreePostsUnderOneDeadlineAndLearnsAfterValidation() = runTest {
        for (lower in listOf(OpenAIResponseFormat.JSON_OBJECT, OpenAIResponseFormat.NONE)) {
            val files = MemoryStore()
            val connection = connection()
            val formats = mutableListOf<String?>()
            val state = ProviderStateStore(files)
            var now = 123L
            val deadline = now + Limits.llmBudgetNanos
            val client = OpenAIClient(HttpTransport { http ->
                assertEquals(deadline, http.deadlineNanos)
                val format = format(http)
                formats.add(format)
                assertTrue(files.writes.isEmpty() || formats.size > lower.ordinal + 1)
                now += 70_000_000_000
                if (formats.size <= lower.ordinal) unsupported(format!!) else completion()
            }, state, MonotonicClock { now }) { utc }
            assertIs<AssistantOutput.Artifact>(client.perform(request, connection, deadline).output)
            assertEquals(lower, ProviderStateStore(files).format(connection))
            assertEquals(1, files.writes.size)
            assertIs<AssistantOutput.Artifact>(client.perform(request, connection, deadline).output)
            assertEquals(if (lower == OpenAIResponseFormat.NONE) listOf("json_schema", "json_object", null, null)
                else listOf("json_schema", "json_object", "json_object"), formats)
            assertEquals(1, files.writes.size)
        }
    }

    @Test fun thirdRejectionAndEveryFailedLowerResponseLeaveStateUnlearned() = runTest {
        val failures = listOf(
            HttpResponse(400, body = byteArrayOf()), HttpResponse(401, body = byteArrayOf()),
            HttpResponse(429, body = byteArrayOf()), HttpResponse(500, body = byteArrayOf()),
            completion("length"), completion("content_filter"), completion("tool_calls"),
            completion(text = "{}"), completion(text = ""))
        for (failure in failures) {
            val files = MemoryStore()
            val connection = connection()
            var calls = 0
            val formats = mutableListOf<String?>()
            val client = OpenAIClient(HttpTransport {
                formats.add(format(it))
                when (calls++) { 0 -> unsupported("json_schema"); 1 -> failure; else -> completion() }
            }, ProviderStateStore(files), MonotonicClock { 1 }) { utc }
            assertFailsWith<AssistantError> { client.perform(request, connection) }
            assertTrue(files.writes.isEmpty())
            assertNull(files.stamp(path))
            client.perform(request, connection)
            assertEquals(listOf<String?>("json_schema", "json_object", "json_schema"), formats)
        }
        val files = MemoryStore()
        var calls = 0
        val client = OpenAIClient(HttpTransport { calls++; unsupported("response_format") }, ProviderStateStore(files), MonotonicClock { 1 }) { utc }
        assertEquals(AssistantError.ProviderFailure(400), assertFailsWith<AssistantError> { client.perform(request, connection()) })
        assertEquals(3, calls)
        assertTrue(files.writes.isEmpty())
    }

    @Test fun receiptAfterDeadlineNeverProbesOrLearns() = runTest {
        for (reply in listOf(unsupported("json_schema"), completion())) {
            val files = MemoryStore()
            var now = 1L
            var calls = 0
            val client = OpenAIClient(HttpTransport { calls++; now += Limits.llmBudgetNanos; reply },
                ProviderStateStore(files), MonotonicClock { now }) { utc }
            assertEquals(AssistantError.Transport(HttpTransportError.DeadlineExceeded),
                assertFailsWith<AssistantError> { client.perform(request, connection()) })
            assertEquals(1, calls)
            assertTrue(files.writes.isEmpty())
        }
    }

    @Test fun formatRejectionSplitsSwiftWhitespaceCharactersIncludingAttachedMarks() = runTest {
        for ((separator, probes) in listOf(" \u0301" to true, "\u00A0\u0301" to true, "\t\u0301" to false)) {
            val files = MemoryStore()
            var calls = 0
            val client = OpenAIClient(HttpTransport {
                if (calls++ == 0) HttpResponse(400, body = AssistantJson.encode(mapOf("error" to
                    mapOf("message" to "json_schema${separator}is not supported"))).toByteArray())
                else completion()
            }, ProviderStateStore(files), MonotonicClock { 1 }) { utc }
            if (probes) assertIs<AssistantOutput.Artifact>(client.perform(request, connection()).output)
            else assertEquals(AssistantError.ProviderFailure(400), assertFailsWith<AssistantError> { client.perform(request, connection()) })
            assertEquals(if (probes) 2 else 1, calls)
            assertEquals(if (probes) 1 else 0, files.writes.size)
        }
    }

    @Test fun onTimeValidatedResponseSurvivesParsingBeyondTheDeadline() = runTest {
        for (probes in listOf(0, 1)) {
            var now = 0L
            val step = (if (probes == 0) 65 else 45) * 1_000_000_000L
            val files = MemoryStore()
            var calls = 0
            var deadline = 0L
            val client = OpenAIClient(HttpTransport {
                deadline = it.deadlineNanos
                if (calls++ < probes) unsupported("json_schema") else completion()
            }, ProviderStateStore(files), MonotonicClock { val value = now; now += step; value }) { utc }
            assertIs<AssistantOutput.Artifact>(client.perform(request, connection()).output)
            assertTrue(now >= deadline)
            assertEquals(probes + 1, calls)
            assertEquals(probes, files.writes.size)
        }
    }

    @Test fun cacheReadAndWriteFailuresRetainOutputAndUsageAndModelsNeverReadCache() = runTest {
        for (operation in listOf(MemoryStore.Operation.READ, MemoryStore.Operation.WRITE)) {
            val files = MemoryStore()
            val original = """{"version":8,"future":"retain"}"""
            files.put(original, path)
            files.fault = { op, _ -> if (op == operation) StoreError.IOFailure else null }
            var calls = 0
            val client = OpenAIClient(HttpTransport { if (calls++ % 2 == 0) unsupported("json_schema") else completion() },
                ProviderStateStore(files), MonotonicClock { 1 }) { utc }
            repeat(2) {
                val response = client.perform(request, connection())
                assertIs<AssistantOutput.Artifact>(response.output)
                assertEquals(AssistantTokenUsage(12, 34), response.usage)
            }
            files.fault = null
            assertEquals(original, files.text(path))
        }
        val files = MemoryStore()
        files.onRead = { throw AssertionError("Model listing consulted capability state") }
        val client = OpenAIClient(HttpTransport { HttpResponse(200, body = "{\"data\":[]}".toByteArray()) },
            ProviderStateStore(files), MonotonicClock { 1 }) { utc }
        assertTrue(client.listModels(connection(model = "")).models.isEmpty())
        assertEquals(0, files.accesses)
    }

    @Test fun cancellationDuringProbeNeverLearnsAndReachesTransportOncePerAttempt() = runTest {
        for (probes in listOf(0, 1)) {
            val files = MemoryStore()
            val started = CompletableDeferred<Unit>()
            val result = CompletableDeferred<AssistantError>()
            var calls = 0
            val client = OpenAIClient(HttpTransport {
                if (calls++ < probes) unsupported("json_schema")
                else { started.complete(Unit); awaitCancellation() }
            }, ProviderStateStore(files), MonotonicClock { 1 }) { utc }
            val task = launch {
                try { client.perform(request, connection()) }
                catch (error: AssistantError) { result.complete(error) }
            }
            runCurrent(); started.await(); task.cancel(); task.join()
            assertEquals(AssistantError.Transport(HttpTransportError.Cancelled), result.await())
            assertEquals(probes + 1, calls)
            assertTrue(files.writes.isEmpty())
        }
    }

    @Test fun invalidKeyModelOrProtocolNeverSendsAndKeylessCallsHaveNoAnthropicHeaders() = runTest {
        var calls = 0
        val client = OpenAIClient(HttpTransport { http ->
            calls++
            assertEquals(if (http.method == HttpMethod.POST) mapOf("Content-Type" to "application/json") else emptyMap(), http.headers)
            if (http.method == HttpMethod.POST) completion() else HttpResponse(200, body = "{\"data\":[]}".toByteArray())
        }, ProviderStateStore(MemoryStore()), MonotonicClock { 1 }) { utc }
        for (key in listOf("", " \t\n", "fixture\r\nInjected: value")) {
            assertEquals(AssistantError.Authentication, assertFailsWith<AssistantError> { client.perform(request, connection(key = key)) })
            assertEquals(AssistantError.Authentication, assertFailsWith<AssistantError> { client.listModels(connection(key = key)) })
        }
        for (model in listOf("", " \n", "model\n")) {
            assertEquals(AssistantError.NotConfigured, assertFailsWith<AssistantError> { client.perform(request, connection(model = model)) })
        }
        val wrong = ProviderConnection(ProviderProfileID(), ProviderKind.ANTHROPIC, "https://api.anthropic.com", "fixture-model", SecretValue("fixture-only-api-key"))
        assertEquals(AssistantError.NotConfigured, assertFailsWith<AssistantError> { client.perform(request, wrong) })
        assertEquals(AssistantError.NotConfigured, assertFailsWith<AssistantError> { client.listModels(wrong) })
        assertEquals(0, calls)
        client.perform(request, connection(key = null))
        client.listModels(connection(key = null))
        assertEquals(2, calls)
    }

    @Test fun boundaryCapsWraparoundAndUnsafeDiagnosticsKeepTheirTypedFailures() = runTest {
        val origin = Long.MAX_VALUE - Limits.llmBudgetNanos / 2
        var calls = 0
        val client = OpenAIClient(HttpTransport {
            calls++
            assertEquals(Limits.llmBudgetNanos, it.deadlineNanos - origin)
            completion()
        }, ProviderStateStore(MemoryStore()), MonotonicClock { origin }) { utc }
        assertIs<AssistantOutput.Artifact>(client.perform(request, connection()).output)
        assertEquals(AssistantError.Transport(HttpTransportError.DeadlineExceeded),
            assertFailsWith<AssistantError> { client.perform(request, connection(), origin) })
        assertEquals(AssistantError.Transport(HttpTransportError.RequestTooLarge), assertFailsWith<AssistantError> {
            client.perform(AssistantRequest(AssistantAction.Write("x".repeat(Limits.httpRequestCap))), connection())
        })
        assertEquals(AssistantError.InvalidOutput, assertFailsWith<AssistantError> {
            client.perform(AssistantRequest(AssistantAction.Write("\uD800")), connection())
        })
        assertEquals(1, calls)
        for (status in listOf(200, 400, 500)) {
            val capped = OpenAIClient(HttpTransport { HttpResponse(status, body = ByteArray(Limits.responseCap + 1)) },
                ProviderStateStore(MemoryStore()), MonotonicClock { 1 }) { utc }
            assertEquals(AssistantError.Transport(HttpTransportError.ResponseTooLarge),
                assertFailsWith<AssistantError> { capped.perform(request, connection()) })
            assertEquals(AssistantError.Transport(HttpTransportError.ResponseTooLarge),
                assertFailsWith<AssistantError> { capped.listModels(connection()) })
        }
        val sentinel = "fixture-only-private-diagnostic"
        val unsafe = OpenAIClient(HttpTransport { throw IllegalArgumentException(sentinel) }, ProviderStateStore(MemoryStore()))
        val failure = assertFailsWith<AssistantError> { unsafe.perform(request, connection(key = sentinel)) }
        assertEquals(AssistantError.Transport(HttpTransportError.NetworkFailure), failure)
        assertFalse(sentinel in failure.stackTraceToString())
        assertFalse(sentinel in unsafe.toString())
        assertNull(failure.cause)
    }

    private fun connection(key: String? = "fixture-only-api-key", model: String = "fixture-model") =
        ProviderConnection(ProviderProfileID(), ProviderKind.OPENAI_COMPATIBLE, "http://localhost:11434/v1", model, key?.let(::SecretValue))

    private fun completion(reason: String = "stop", text: String = artifact) = HttpResponse(200, body = AssistantJson.encode(
        mapOf("choices" to listOf(mapOf("finish_reason" to reason, "message" to mapOf("content" to text))),
            "usage" to mapOf("prompt_tokens" to 12, "completion_tokens" to 34))).toByteArray())

    private fun unsupported(format: String) = HttpResponse(400, body = AssistantJson.encode(
        mapOf("error" to mapOf("param" to "response_format", "message" to "$format is not supported"))).toByteArray())

    private fun format(http: HttpRequest): String? = LlmJsonParser(http.body!!, mode = AssistantJsonMode.ENVELOPE)
        .parse().optional("response_format")?.optionalString("type")
}
