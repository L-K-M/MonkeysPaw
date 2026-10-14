package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.ProviderStateStore
import java.math.BigDecimal
import java.time.Instant
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Non-streaming completions: two possible format downgrades share the action deadline. */
class OpenAIClient(private val transport: HttpTransport,
                   private val providerState: ProviderStateStore,
                   private val clock: MonotonicClock = MonotonicClock(System::nanoTime),
                   private val nowUTC: () -> Instant = Instant::now) : AssistantClient {
    override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse =
        perform(request, connection, clock.nowNanos() + Limits.llmBudgetNanos)

    override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
        checkActive(deadlineNanos)
        if (!AssistantModelList.validID(connection.modelID)) throw AssistantError.NotConfigured
        val headers = headers(connection, HttpMethod.POST)
        checkActive(deadlineNanos)
        val initialFormat = providerState.format(connection)
        val prompt = when (request.action) {
            is AssistantAction.Write -> AssistantPrompts.write
            is AssistantAction.Review -> AssistantPrompts.review
            is AssistantAction.Improve -> AssistantPrompts.improve
        }
        val schema = if (request.action is AssistantAction.Review) LlmSchemas.review else LlmSchemas.artifact
        val schemaName = if (request.action is AssistantAction.Review) "prompt_review" else "prompt_artifact"
        val body = linkedMapOf<String, Any>("model" to connection.modelID,
            "messages" to listOf(mapOf("role" to "system", "content" to prompt)) + request.wireMessages.map { it.wireValue })
        request.effort?.let { body["reasoning_effort"] = it.rawValue }
        var format = initialFormat
        while (true) {
            checkActive(deadlineNanos)
            when (format) {
                OpenAIResponseFormat.JSON_SCHEMA -> body["response_format"] = mapOf("type" to "json_schema", "json_schema" to
                    mapOf("name" to schemaName, "schema" to schema.wireValue, "strict" to true))
                OpenAIResponseFormat.JSON_OBJECT -> body["response_format"] = mapOf("type" to "json_object")
                OpenAIResponseFormat.NONE -> body.remove("response_format")
            }
            val httpRequest = httpRequest(connection.completionURL, HttpMethod.POST, headers,
                scalarBytes(AssistantJson.encode(body)), deadlineNanos)
            val response = AssistantHTTP.send(httpRequest, transport, nowUTC, AssistantHTTP.StatusPolicy.FORMAT_PROBE)
            checkActive(deadlineNanos)
            if (response.statusCode == 400) {
                val lower = format.lower
                if (lower == null || !OpenAIFormatRejection.rejects(format, response.body)) throw AssistantError.ProviderFailure(400)
                format = lower
                continue
            }

            val envelope = outputEnvelope(response.body)
            val text = outputText(envelope)
            val output = when (val action = request.action) {
                is AssistantAction.Review -> AssistantOutput.Review(LlmOutputDecoder.review(text, action.source))
                else -> AssistantOutput.Artifact(LlmOutputDecoder.artifact(text))
            }
            val usage = usage(envelope)
            // Receipt owns the deadline; parsing must retain an on-time response.
            checkCancellation()
            if (format != initialFormat) providerState.recordSuccess(format, connection)
            return AssistantResponse(output, usage)
        }
    }

    override suspend fun listModels(connection: ProviderConnection): AssistantModelPage =
        listModels(connection, null, clock.nowNanos() + Limits.modelListTimeoutNanos)

    override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage {
        val request = httpRequest(AssistantModelList.url(connection, afterID), HttpMethod.GET,
            headers(connection, HttpMethod.GET), null, deadlineNanos)
        checkActive(deadlineNanos)
        val response = AssistantHTTP.send(request, transport, nowUTC)
        checkActive(deadlineNanos)
        val page = AssistantModelList.decode(response.body, ProviderKind.OPENAI_COMPATIBLE)
        checkActive(deadlineNanos)
        return page
    }

    private fun headers(connection: ProviderConnection, method: HttpMethod): Map<String, String> {
        if (connection.kind != ProviderKind.OPENAI_COMPATIBLE) throw AssistantError.NotConfigured
        return buildMap {
            connection.key?.withValue { key ->
                if (key.trimProviderWhitespace().isEmpty() || key.hasControls()) throw AssistantError.Authentication
                put("Authorization", "Bearer " + key)
            }
            if (method == HttpMethod.POST) put("Content-Type", "application/json")
        }
    }

    private suspend fun checkActive(deadline: Long) {
        checkCancellation()
        if (deadline - clock.nowNanos() <= 0) throw AssistantError.Transport(HttpTransportError.DeadlineExceeded)
    }

    private suspend fun checkCancellation() {
        try { currentCoroutineContext().ensureActive() }
        catch (_: CancellationException) { throw AssistantError.Transport(HttpTransportError.Cancelled) }
    }

    private fun httpRequest(url: String, method: HttpMethod, headers: Map<String, String>, body: ByteArray?, deadline: Long): HttpRequest =
        try { HttpRequest(url, method, headers, body, deadlineNanos = deadline) }
        catch (error: HttpTransportError) { throw AssistantError.Transport(error) }

    private fun outputEnvelope(bytes: ByteArray): LlmJsonValue {
        if (bytes.isEmpty() || bytes.all { it.toInt() in listOf(9, 10, 13, 32) }) throw AssistantError.EmptyResponse
        return LlmJsonParser(bytes, mode = AssistantJsonMode.ENVELOPE).parse()
    }

    private fun outputText(envelope: LlmJsonValue): String {
        val choice = envelope.member("choices").array().firstOrNull() ?: throw AssistantError.EmptyResponse
        val reason = choice.optionalString("finish_reason")
        when (reason) {
            "stop", null -> Unit
            "length" -> throw AssistantError.Truncated
            "content_filter" -> throw AssistantError.Declined
            else -> throw AssistantError.UnexpectedStop(reason)
        }
        val message = choice.member("message")
        // Both optional fields are decoded before refusal, as in Swift's TextChoice.
        val content = message.optionalString("content")
        val refusal = message.optionalString("refusal")
        if (refusal != null && refusal.trimProviderWhitespace().isNotEmpty()) throw AssistantError.Declined
        if (content == null || content.trimProviderWhitespace().isEmpty()) throw AssistantError.EmptyResponse
        if (reason == null) throw AssistantError.UnexpectedStop("missing")
        return content
    }

    private fun usage(envelope: LlmJsonValue): AssistantTokenUsage? = try {
        val value = envelope.member("usage")
        fun tokens(key: String): Long {
            val number = value.member(key) as? LlmJsonValue.Number ?: throw AssistantError.InvalidOutput
            return BigDecimal(number.token).longValueExact().also { if (it < 0) throw AssistantError.InvalidOutput }
        }
        AssistantTokenUsage(tokens("prompt_tokens"), tokens("completion_tokens"))
    } catch (_: Exception) { null }

    override fun toString(): String = "<OpenAI-compatible client>"
}

/** A schema error or a generic 400 is never evidence of unsupported output format. */
private object OpenAIFormatRejection {
    fun rejects(format: OpenAIResponseFormat, bytes: ByteArray): Boolean {
        val objectValue = try { LlmJsonParser(bytes, mode = AssistantJsonMode.SERIALIZATION).parse() as? LlmJsonValue.Object }
            catch (_: AssistantError) { null } ?: return false
        val error = objectValue.members["error"] as? LlmJsonValue.Object
        fun text(value: LlmJsonValue?): String? = (value as? LlmJsonValue.Text)?.value
        val param = text(error?.members?.get("param"))?.lowercase(Locale.ROOT)
        if (param != null && param !in formatParams) return false
        val code = text(error?.members?.get("code"))?.lowercase(Locale.ROOT)
        val raw = text(error?.members?.get("message")) ?: text(objectValue.members["error"]).orEmpty()
        val message = raw.lowercase(Locale.ROOT).replace(Regex("[\"'`]"), "").replace(':', ' ')
            .split(whitespace).filter { it.isNotEmpty() }.joinToString(" ")
        if (listOf("invalid schema", "invalid json schema", "invalid json_schema", "schema keyword", "schema validation").any { it in message }) return false
        if (param in formatParams && code in setOf("unsupported_parameter", "unsupported_value", "unknown_parameter")) return true
        return listOf(format.rawValue, "response_format").any { subject ->
            listOf("$subject is not supported", "$subject not supported", "$subject is unsupported",
                "$subject is not implemented", "$subject format is not supported", "$subject response format is not supported",
                "does not support $subject", "doesn't support $subject", "unsupported $subject", "unknown parameter $subject",
                "unrecognized request argument $subject", "unrecognized request argument supplied $subject", "unrecognized parameter $subject")
                .any { Regex("(?U)\\b" + Regex.escape(it) + "(?!\\w|\\.\\w)").containsMatchIn(message) }
        }
    }

    private val formatParams = setOf("response_format", "response_format.type")
    // Swift Character.isWhitespace uses Unicode White_Space, including NEL and NBSP.
    private val whitespace = Regex("[\\u0009-\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]+")
}
