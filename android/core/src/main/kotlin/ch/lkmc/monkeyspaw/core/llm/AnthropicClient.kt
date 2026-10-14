package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantAction
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantModelPage
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantOutput
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantRequest
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantResponse
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantTokenUsage
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderConnection
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderKind
import ch.lkmc.monkeyspaw.core.domain.llm.hasControls
import ch.lkmc.monkeyspaw.core.domain.llm.trimProviderWhitespace
import ch.lkmc.monkeyspaw.core.ports.HttpMethod
import ch.lkmc.monkeyspaw.core.ports.HttpRequest
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import java.math.BigDecimal
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** A single Messages attempt; HTTP-400 format probes belong only to OpenAI-compatible providers. */
class AnthropicClient(private val transport: HttpTransport,
                      private val clock: MonotonicClock = MonotonicClock(System::nanoTime),
                      private val nowUTC: () -> Instant = Instant::now) : AssistantClient {
    override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse =
        perform(request, connection, clock.nowNanos() + Limits.llmBudgetNanos)

    override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
        checkActive(deadlineNanos)
        if (!AssistantModelList.validID(connection.modelID)) throw AssistantError.NotConfigured
        val headers = headers(connection, HttpMethod.POST)
        val prompt = when (request.action) {
            is AssistantAction.Write -> AssistantPrompts.write
            is AssistantAction.Review -> AssistantPrompts.review
            is AssistantAction.Improve -> AssistantPrompts.improve
        }
        val schema = if (request.action is AssistantAction.Review) LlmSchemas.review else LlmSchemas.artifact
        val config = linkedMapOf<String, Any>("format" to mapOf("type" to "json_schema", "schema" to schema.wireValue))
        request.effort?.let { config["effort"] = it.rawValue }
        val body = linkedMapOf<String, Any>("model" to connection.modelID, "max_tokens" to Limits.anthropicMaxTokens,
            "system" to prompt, "messages" to request.wireMessages.map { it.wireValue }, "output_config" to config)
        if (isOfficial(connection)) body["fallbacks"] = "default"
        val httpRequest = httpRequest(connection.completionURL, HttpMethod.POST, headers,
            scalarBytes(AssistantJson.encode(body)), deadlineNanos)
        val response = AssistantHTTP.send(httpRequest, transport, nowUTC)
        val bytes = response.body
        if (bytes.isEmpty() || bytes.all { it.toInt() in listOf(9, 10, 13, 32) }) throw AssistantError.EmptyResponse
        val envelope = LlmJsonParser(bytes, mode = AssistantJsonMode.ENVELOPE).parse()
        val reason = envelope.optionalString("stop_reason")
        when (reason) {
            "end_turn", "stop_sequence", null -> Unit
            "max_tokens", "model_context_window_exceeded" -> throw AssistantError.Truncated
            "refusal" -> throw AssistantError.Declined
            else -> throw AssistantError.UnexpectedStop(reason)
        }
        val text = envelope.member("content").array().joinToString("") {
            if (it.member("type").string() == "text") it.member("text").string() else ""
        }
        if (text.trimProviderWhitespace().isEmpty()) throw AssistantError.EmptyResponse
        if (reason == null) throw AssistantError.UnexpectedStop("missing")
        val output = when (val action = request.action) {
            is AssistantAction.Review -> AssistantOutput.Review(LlmOutputDecoder.review(text, action.source))
            else -> AssistantOutput.Artifact(LlmOutputDecoder.artifact(text))
        }
        return AssistantResponse(output, usage(envelope))
    }

    override suspend fun listModels(connection: ProviderConnection): AssistantModelPage =
        listModels(connection, null, clock.nowNanos() + Limits.modelListTimeoutNanos)

    override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage {
        checkActive(deadlineNanos)
        val request = httpRequest(AssistantModelList.url(connection, afterID), HttpMethod.GET,
            headers(connection, HttpMethod.GET), null, deadlineNanos)
        val response = AssistantHTTP.send(request, transport, nowUTC)
        checkActive(deadlineNanos)
        val page = AssistantModelList.decode(response.body)
        checkActive(deadlineNanos)
        return page
    }

    private suspend fun checkActive(deadline: Long) {
        try { currentCoroutineContext().ensureActive() }
        catch (_: CancellationException) { throw AssistantError.Transport(HttpTransportError.Cancelled) }
        if (deadline - clock.nowNanos() <= 0) throw AssistantError.Transport(HttpTransportError.DeadlineExceeded)
    }

    private fun headers(connection: ProviderConnection, method: HttpMethod): Map<String, String> {
        if (connection.kind != ProviderKind.ANTHROPIC) throw AssistantError.NotConfigured
        val key = connection.key?.withValue { it } ?: throw AssistantError.Authentication
        if (key.trimProviderWhitespace().isEmpty() || key.hasControls()) throw AssistantError.Authentication
        return buildMap {
            put("x-api-key", key); put("anthropic-version", "2023-06-01")
            if (method == HttpMethod.POST) {
                put("Content-Type", "application/json")
                if (isOfficial(connection)) put("anthropic-beta", "server-side-fallback-2026-07-01")
            }
        }
    }

    private fun isOfficial(connection: ProviderConnection): Boolean =
        connection.baseURL.substringAfter("://").substringBefore('/').substringBefore(':') == "api.anthropic.com"

    private fun httpRequest(url: String, method: HttpMethod, headers: Map<String, String>, body: ByteArray?, deadline: Long): HttpRequest =
        try { HttpRequest(url, method, headers, body, deadlineNanos = deadline) }
        catch (error: HttpTransportError) { throw AssistantError.Transport(error) }

    private fun usage(envelope: LlmJsonValue): AssistantTokenUsage? = try {
        val value = envelope.member("usage")
        fun tokens(key: String): Long {
            val number = value.member(key) as? LlmJsonValue.Number ?: throw AssistantError.InvalidOutput
            return BigDecimal(number.token).longValueExact().also { if (it < 0) throw AssistantError.InvalidOutput }
        }
        AssistantTokenUsage(tokens("input_tokens"), tokens("output_tokens"))
    } catch (_: Exception) { null }

    override fun toString(): String = "<Anthropic client>"
}
