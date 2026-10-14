package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

internal class AnthropicClientTest {
    private val request = AssistantRequest(AssistantAction.Write("Fixture brief"))
    private val artifact = """{"title":"Fixture","description":"","tags":[],"fields":[],"body":"Ready.","notes":""}"""
    private val clock = MonotonicClock { 123L }
    private val utc = Instant.parse("2026-10-13T00:00:00Z")

    @Test fun cancellationReachesTransportOnceAndKeepsTypedBodyFreeFailure() = runTest {
        val started = CompletableDeferred<Unit>()
        val failure = CompletableDeferred<AssistantError>()
        var calls = 0
        val transport = HttpTransport { calls++; started.complete(Unit); awaitCancellation() }
        val client = AnthropicClient(transport, clock) { utc }
        val task = launch {
            try { client.perform(request, connection()) }
            catch (error: AssistantError) { failure.complete(error) }
        }
        runCurrent()
        started.await()
        task.cancel()
        task.join()
        assertEquals(AssistantError.Transport(HttpTransportError.Cancelled), failure.await())
        assertEquals(1, calls)
    }

    @Test fun arbitraryTransportDiagnosticsAndEchoesCannotReachErrorsOrClientDescription() = runTest {
        val sentinel = UUID.randomUUID().toString()
        var calls = 0
        val client = AnthropicClient(HttpTransport { calls++; throw IllegalArgumentException(sentinel) }, clock) { utc }
        val error = assertFailsWith<AssistantError> { client.listModels(connection(sentinel)) }
        assertEquals(AssistantError.Transport(HttpTransportError.NetworkFailure), error)
        for (text in listOf(error.toString(), error.message.orEmpty(), error.stackTraceToString(), client.toString())) assertFalse(sentinel in text)
        assertNull(error.cause)
        assertEquals(1, calls)
        val echoed = AnthropicClient(HttpTransport { message(reason = sentinel) }, clock) { utc }
        val stop = assertFailsWith<AssistantError.UnexpectedStop> { echoed.perform(request, connection(sentinel)) }
        assertEquals(sentinel, stop.reason)
        assertFalse(sentinel in stop.stackTraceToString())
    }

    @Test fun envelopeAndRequestCapsRemainAtTheProtocolBoundary() = runTest {
        var calls = 0
        val oversize = HttpResponse(401, body = ByteArray(Limits.responseCap + 1) { 32 })
        val client = AnthropicClient(HttpTransport { calls++; oversize }, clock) { utc }
        assertEquals(AssistantError.Transport(HttpTransportError.ResponseTooLarge),
            assertFailsWith<AssistantError> { client.perform(request, connection()) })
        assertEquals(AssistantError.Transport(HttpTransportError.ResponseTooLarge),
            assertFailsWith<AssistantError> { client.listModels(connection()) })
        assertEquals(2, calls)
        val oversized = AssistantRequest(AssistantAction.Write("x".repeat(Limits.httpRequestCap)))
        assertEquals(AssistantError.Transport(HttpTransportError.RequestTooLarge),
            assertFailsWith<AssistantError> { client.perform(oversized, connection()) })
        assertEquals(2, calls)
    }

    @Test fun monotonicDeadlinesSurviveNanoTimeWraparoundAndRejectExpiryBeforeSend() = runTest {
        val origin = Long.MAX_VALUE - Limits.llmBudgetNanos / 2
        var calls = 0
        val client = AnthropicClient(HttpTransport {
            calls++
            assertEquals(Limits.llmBudgetNanos, it.deadlineNanos - origin)
            message()
        }, MonotonicClock { origin }) { utc }
        assertIs<AssistantOutput.Artifact>(client.perform(request, connection()).output)
        assertEquals(AssistantError.Transport(HttpTransportError.DeadlineExceeded),
            assertFailsWith<AssistantError> { client.perform(request, connection(), origin) })
        assertEquals(1, calls)
    }

    @Test fun receiptUsesTheSameModelDeadlineWhileActionOutputMayFinishAfterReceipt() = runTest {
        var now = 100L
        val client = AnthropicClient(HttpTransport { http ->
            now = http.deadlineNanos
            if (http.method == HttpMethod.GET) HttpResponse(200, body = "{\"data\":[]}".toByteArray()) else message()
        }, MonotonicClock { now }) { utc }
        assertIs<AssistantOutput.Artifact>(client.perform(request, connection()).output)
        assertEquals(AssistantError.Transport(HttpTransportError.DeadlineExceeded),
            assertFailsWith<AssistantError> { client.listModels(connection()) })
    }

    @Test fun invalidJvmScalarsCannotSilentlyBecomeRequestReplacementCharacters() = runTest {
        var calls = 0
        val client = AnthropicClient(HttpTransport { calls++; message() }, clock) { utc }
        assertEquals(AssistantError.InvalidOutput, assertFailsWith<AssistantError> {
            client.perform(AssistantRequest(AssistantAction.Write("\uD800")), connection())
        })
        assertEquals(0, calls)
    }

    @Test fun theWrongProtocolCannotSendCredentials() = runTest {
        var calls = 0
        val client = AnthropicClient(HttpTransport { calls++; message() }, clock) { utc }
        val connection = ProviderConnection(ProviderProfileID(), ProviderKind.OPENAI_COMPATIBLE,
            "https://api.openai.com/v1", "fixture-model", SecretValue("fixture-only-api-key"))
        assertEquals(AssistantError.NotConfigured, assertFailsWith<AssistantError> { client.perform(request, connection) })
        assertEquals(AssistantError.NotConfigured, assertFailsWith<AssistantError> { client.listModels(connection) })
        assertEquals(0, calls)
    }

    @Test fun statusPolicyOnlyExposes400ForTheFutureOpenAIProbe() = runTest {
        val http = HttpRequest("https://fixture.example", HttpMethod.POST, deadlineNanos = 1)
        val response = HttpResponse(400, body = "private fixture error".toByteArray())
        val transport = HttpTransport { response }
        assertEquals(AssistantError.ProviderFailure(400), assertFailsWith<AssistantError> {
            AssistantHTTP.send(http, transport, { utc })
        })
        assertSame(response, AssistantHTTP.send(http, transport, { utc }, AssistantHTTP.StatusPolicy.FORMAT_PROBE))
    }

    private fun connection(key: String = "fixture-only-api-key"): ProviderConnection =
        ProviderConnection(ProviderProfileID(), ProviderKind.ANTHROPIC, "https://api.anthropic.com", "claude-opus-5-5", SecretValue(key))

    private fun message(reason: String = "end_turn"): HttpResponse = HttpResponse(200, body = AssistantJson.encode(
        mapOf("stop_reason" to reason, "content" to listOf(mapOf("type" to "text", "text" to artifact)))).toByteArray())
}
