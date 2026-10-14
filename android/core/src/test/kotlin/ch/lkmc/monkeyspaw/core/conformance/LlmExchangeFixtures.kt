package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.llm.AnthropicClient
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.util.Locale
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Closed exchange envelope. L6 extends capability variants alongside its real store/client. */
internal object LlmExchangeContracts {
    fun read(root: JsonObject): List<String> {
        root.members(setOf("schema", "category", "kind", "setup", "actions"))
        val references = mutableListOf<String>()
        fun source(value: JsonElement?, extensions: Set<String>) {
            val name = value.stringValue()
            corpusRequire(name.isNotEmpty() && !name.startsWith('.') && '/' !in name && '\\' !in name && name != "case.json" &&
                extensions.any { name.endsWith(it) }, "Unsafe exchange reference")
            references.add(name)
        }
        val setup = root["setup"].objectValue()
        setup.members(setOf("capabilityState", "nowUTC", "nowMonotonicMs"))
        corpusRequire(setup["capabilityState"] == JsonNull, "Anthropic has no capability state")
        val utc = setup["nowUTC"].stringValue()
        corpusRequire(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z").matches(utc) && Instant.parse(utc).toString() == utc, "Invalid UTC origin")
        nonnegative(setup["nowMonotonicMs"])
        val actions = root["actions"].arrayValue()
        corpusRequire(actions.isNotEmpty(), "Empty exchange fixture")
        for (value in actions) {
            val action = value.objectValue()
            action.members(setOf("profile", "intent", "budgetMs", "exchanges", "expected"))
            val profile = action["profile"].objectValue()
            profile.members(setOf("id", "kind", "baseURL", "modelID", "key"))
            ProviderProfileID.parse(profile["id"].stringValue())
            corpusRequire(profile["kind"].stringValue() == "anthropic", "Unknown provider kind")
            profile["baseURL"].stringValue(); profile["modelID"].stringValue(); nullableString(profile["key"])
            val intent = action["intent"].objectValue()
            val kind = intent["kind"].stringValue()
            if (kind == "models") {
                intent.members(setOf("kind", "afterID"))
                nullableString(intent["afterID"])
            } else {
                val data = when (kind) {
                    "write" -> setOf("brief")
                    "review" -> setOf("source")
                    "improve" -> setOf("source", "instruction", "selectedFindings")
                    else -> throw CorpusException("Unknown exchange intent")
                }
                intent.members(setOf("kind", "effort", "transcript", "feedback") + data)
                if (intent["effort"] != JsonNull) corpusRequire(intent["effort"].stringValue() in AssistantEffort.entries.map { it.rawValue }, "Unknown effort")
                data.forEach { source(intent[it], setOf(if (it == "selectedFindings") ".json" else if (it == "source") ".md" else ".txt")) }
                if (intent["feedback"] != JsonNull) source(intent["feedback"], setOf(".txt"))
                intent["transcript"].arrayValue().forEach {
                    val turn = it.objectValue()
                    turn.members(setOf("role", "source"))
                    corpusRequire(turn["role"].stringValue() in AssistantMessage.Role.entries.map { it.rawValue }, "Unknown transcript role")
                    source(turn["source"], setOf(".txt"))
                }
            }
            if (action["budgetMs"] != JsonNull) corpusRequire(action["budgetMs"].integerValue() in (-300000).toBigInteger()..300000.toBigInteger(), "Invalid fixture budget")
            for (item in action["exchanges"].arrayValue()) {
                val exchange = item.objectValue()
                exchange.members(setOf("elapsedMs", "request", "response"))
                nonnegative(exchange["elapsedMs"])
                val request = exchange["request"].objectValue()
                request.members(setOf("method", "url", "headers", "requestByteCap", "responseByteCap", "deadlineMs", "body"))
                corpusRequire(request["method"].stringValue() in setOf("GET", "POST"), "Unknown HTTP method")
                request["url"].stringValue()
                stringMap(request["headers"], lowercase = true)
                positive(request["requestByteCap"]); positive(request["responseByteCap"]); request["deadlineMs"].integerValue()
                if (request["body"] != JsonNull) source(request["body"], setOf(".json"))
                val response = exchange["response"].objectValue()
                nonnegative(response["elapsedMs"])
                corpusRequire(response["elapsedMs"].integerValue() >= exchange["elapsedMs"].integerValue(), "Backwards virtual response clock")
                if ("failure" in response) {
                    response.members(setOf("elapsedMs", "failure"))
                    transportError(response["failure"].stringValue())
                } else {
                    response.members(setOf("elapsedMs", "status", "headers", "body"))
                    corpusRequire(response["status"].integerValue() in 100.toBigInteger()..599.toBigInteger(), "Invalid HTTP status")
                    stringMap(response["headers"])
                    source(response["body"], setOf(".bin", ".json", ".txt"))
                }
            }
            val expected = action["expected"].objectValue()
            expected.members(setOf("output", "page", "usage", "error", "requestCount", "cache"))
            nonnegative(expected["requestCount"])
            corpusRequire(expected["requestCount"].integerValue() == action["exchanges"].arrayValue().size.toBigInteger(), "Unaccounted scripted calls")
            corpusRequire(listOf("output", "page", "error").count { expected[it] != JsonNull } == 1, "Ambiguous exchange result")
            if (expected["output"] != JsonNull) {
                val output = expected["output"].objectValue()
                output.members(setOf("kind", "source"))
                corpusRequire(output["kind"].stringValue() == if (kind == "review") "review" else "artifact", "Wrong typed output")
                source(output["source"], setOf(".json"))
            }
            if (expected["page"] != JsonNull) { corpusRequire(kind == "models", "Page from an action"); page(expected["page"].objectValue()) }
            if (expected["usage"] != JsonNull) {
                val usage = expected["usage"].objectValue()
                usage.members(setOf("inputTokens", "outputTokens"))
                nonnegative(usage["inputTokens"]); nonnegative(usage["outputTokens"])
            }
            if (expected["error"] != JsonNull) error(expected["error"].objectValue())
            val cache = expected["cache"].objectValue()
            cache.members(setOf("format", "writes"))
            corpusRequire(cache["format"].stringValue() == "json_schema" && cache["writes"].integerValue() == java.math.BigInteger.ZERO, "Anthropic cannot learn formats")
        }
        corpusRequire(references.distinct().size == references.size, "Duplicate exchange reference")
        return references
    }

    private fun page(page: JsonObject) {
        page.members(setOf("models", "hasMore", "firstID", "lastID"))
        page["hasMore"].booleanValue(); nullableString(page["firstID"]); nullableString(page["lastID"])
        page["models"].arrayValue().forEach {
            val model = it.objectValue(); model.members(setOf("id", "displayName"))
            model["id"].stringValue(); nullableString(model["displayName"])
        }
    }
    private fun error(value: JsonObject) {
        val payload = when (value["code"].stringValue()) {
            "transport" -> { transportError(value["transport"].stringValue()); setOf("transport") }
            "unexpectedStop" -> { value["reason"].stringValue(); setOf("reason") }
            "providerFailure" -> { value["status"].integerValue(); setOf("status") }
            "rateLimited" -> { if (value["retryAfter"] != JsonNull) corpusRequire(value["retryAfter"].numberValue().signum() >= 0, "Negative retry delay"); setOf("retryAfter") }
            "notConfigured", "authentication", "modelNotFound", "overloaded", "truncated", "declined", "emptyResponse", "invalidOutput" -> emptySet()
            else -> throw CorpusException("Unknown exchange error")
        }
        value.members(setOf("code") + payload)
    }
    private fun nullableString(value: JsonElement?) { if (value != JsonNull) value.stringValue() }
    private fun nonnegative(value: JsonElement?) { corpusRequire(value.integerValue().signum() >= 0 && value.integerValue().bitLength() < 64, "Invalid nonnegative integer") }
    private fun positive(value: JsonElement?) { nonnegative(value); corpusRequire(value.integerValue().signum() > 0, "Invalid positive integer") }
    private fun stringMap(value: JsonElement?, lowercase: Boolean = false) {
        value.objectValue().forEach { (key, item) ->
            corpusRequire(key.isNotEmpty() && (!lowercase || key == key.lowercase(Locale.ROOT)), "Invalid fixture header name")
            item.stringValue()
        }
    }
}

internal object LlmExchangeConsumer {
    fun consume(root: JsonObject, bytes: (String) -> ByteArray): Int = runBlocking {
        val setup = root["setup"].objectValue()
        val origin = setup["nowMonotonicMs"].integerValue().longValueExact() * 1_000_000
        val utc = Instant.parse(setup["nowUTC"].stringValue())
        var expectations = countExpectations(setup)
        for (item in root["actions"].arrayValue()) {
            val action = item.objectValue()
            val expected = action["expected"].objectValue()
            val profile = action["profile"].objectValue()
            val kind = ProviderKind.entries.single { it.rawValue == profile["kind"].stringValue() }
            val connection = ProviderConnection(ProviderProfileID.parse(profile["id"].stringValue()), kind,
                ProviderSettings.normalizeBaseURL(profile["baseURL"].stringValue(), kind), profile["modelID"].stringValue(),
                if (profile["key"] == JsonNull) null else SecretValue(profile["key"].stringValue()))
            val intent = action["intent"].objectValue()
            fun text(value: JsonElement?): String = strictUtf8(bytes(value.stringValue()))
            val assistantRequest = if (intent["kind"].stringValue() == "models") null else {
                val task = when (intent["kind"].stringValue()) {
                    "write" -> AssistantAction.Write(text(intent["brief"]))
                    "review" -> AssistantAction.Review(text(intent["source"]))
                    else -> {
                        val source = text(intent["source"])
                        AssistantAction.Improve(source, text(intent["instruction"]), LlmOutputDecoder.review(text(intent["selectedFindings"]), source).findings)
                    }
                }
                AssistantRequest(task, if (intent["effort"] == JsonNull) null else AssistantEffort.entries.single { it.rawValue == intent["effort"].stringValue() },
                    intent["transcript"].arrayValue().map {
                        val turn = it.objectValue()
                        AssistantMessage(AssistantMessage.Role.entries.single { it.rawValue == turn["role"].stringValue() }, text(turn["source"]))
                    }, if (intent["feedback"] == JsonNull) null else text(intent["feedback"]))
            }
            var elapsedNanos = 0L
            val frames = action["exchanges"].arrayValue()
            var calls = 0
            val transport = HttpTransport { request ->
                val index = calls++
                if (index >= frames.size) throw AssertionError("Unexpected automatic request")
                val frame = frames[index].objectValue()
                val golden = frame["request"].objectValue()
                assertEquals(frame["elapsedMs"].integerValue().longValueExact() * 1_000_000, elapsedNanos, "Send time")
                assertEquals(golden["method"].stringValue(), request.method.rawValue, "Method")
                assertUtf8Equal(golden["url"].stringValue(), request.url, "URL")
                assertEquals(golden["headers"].objectValue().mapValues { it.value.stringValue() }, request.headers.mapKeys { it.key.lowercase(Locale.ROOT) }, "Exact headers")
                assertEquals(golden["requestByteCap"].integerValue().intValueExact(), request.requestByteCap, "Request cap")
                assertEquals(golden["responseByteCap"].integerValue().intValueExact(), request.responseByteCap, "Response cap")
                assertEquals(golden["deadlineMs"].integerValue().longValueExact() * 1_000_000, request.deadlineNanos - origin, "Absolute deadline")
                if (golden["body"] == JsonNull) assertNull(request.body, "GET body")
                else assertBytesEqual(bytes(golden["body"].stringValue()), request.body ?: error("Missing request body"), "Raw request body")
                expectations += countExpectations(golden) + 1
                val reply = frame["response"].objectValue()
                elapsedNanos = reply["elapsedMs"].integerValue().longValueExact() * 1_000_000
                if ("failure" in reply) throw transportError(reply["failure"].stringValue())
                HttpResponse(reply["status"].integerValue().intValueExact(), reply["headers"].objectValue().mapValues { it.value.stringValue() }, bytes(reply["body"].stringValue()))
            }
            val client = AnthropicClient(transport, MonotonicClock { origin + elapsedNanos }, { utc.plusNanos(elapsedNanos) })
            var response: AssistantResponse? = null
            var page: AssistantModelPage? = null
            var failure: AssistantError? = null
            try {
                val budget = action["budgetMs"].takeUnless { it == JsonNull }?.integerValue()?.longValueExact()?.times(1_000_000)
                if (assistantRequest != null) response = if (budget == null) client.perform(assistantRequest, connection)
                    else client.perform(assistantRequest, connection, origin + budget)
                else {
                    val after = intent["afterID"].takeUnless { it == JsonNull }?.stringValue()
                    page = if (budget == null && after == null) client.listModels(connection)
                        else client.listModels(connection, after, origin + (budget ?: Limits.modelListTimeoutNanos))
                }
            } catch (error: AssistantError) { failure = error }
            assertEquals(expected["requestCount"].integerValue().intValueExact(), calls, "Ordered call count")
            assertEquals(errorGolden(expected["error"]!!), failure, "Typed error")
            if (expected["output"] == JsonNull) assertNull(response)
            else {
                val output = expected["output"].objectValue()
                val golden = parseFixtureJson(bytes(output["source"].stringValue())).objectValue()
                LlmFixtureContracts.result(golden, output["kind"].stringValue())
                assertEquals(golden, LlmFixtureConsumer.snapshot(response!!.output), "Typed output")
                expectations += countExpectations(golden)
            }
            assertEquals(expected["page"], page?.let(::pageSnapshot) ?: JsonNull, "Model page")
            assertEquals(expected["usage"], response?.usage?.let {
                buildJsonObject { put("inputTokens", it.inputTokens); put("outputTokens", it.outputTokens) }
            } ?: JsonNull, "Optional usage")
            // Anthropic does not own a capability store or perform format probes.
            assertEquals(JsonNull, setup["capabilityState"])
            assertEquals(buildJsonObject { put("format", "json_schema"); put("writes", 0) }, expected["cache"])
            expectations += countExpectations(expected)
        }
        expectations
    }

    private fun pageSnapshot(page: AssistantModelPage): JsonObject = buildJsonObject {
        put("models", JsonArray(page.models.map { buildJsonObject { put("id", it.id); put("displayName", it.displayName?.let(::JsonPrimitive) ?: JsonNull) } }))
        put("hasMore", page.hasMore); put("firstID", page.firstID?.let(::JsonPrimitive) ?: JsonNull); put("lastID", page.lastID?.let(::JsonPrimitive) ?: JsonNull)
    }
    private fun errorGolden(value: JsonElement): AssistantError? {
        if (value == JsonNull) return null
        val error = value.objectValue()
        return when (error["code"].stringValue()) {
            "transport" -> AssistantError.Transport(transportError(error["transport"].stringValue()))
            "unexpectedStop" -> AssistantError.UnexpectedStop(error["reason"].stringValue())
            "providerFailure" -> AssistantError.ProviderFailure(error["status"].integerValue().intValueExact())
            "rateLimited" -> AssistantError.RateLimited(error["retryAfter"].takeUnless { it == JsonNull }?.numberValue()?.toDouble())
            "notConfigured" -> AssistantError.NotConfigured
            "authentication" -> AssistantError.Authentication
            "modelNotFound" -> AssistantError.ModelNotFound
            "overloaded" -> AssistantError.Overloaded
            "truncated" -> AssistantError.Truncated
            "declined" -> AssistantError.Declined
            "emptyResponse" -> AssistantError.EmptyResponse
            "invalidOutput" -> AssistantError.InvalidOutput
            else -> throw CorpusException("Unknown exchange error")
        }
    }
    private fun countExpectations(value: JsonElement): Int = when (value) {
        is JsonObject -> value.size + value.values.sumOf(::countExpectations)
        is JsonArray -> value.sumOf(::countExpectations)
        else -> 0
    }
}

private fun transportError(code: String): HttpTransportError = when (code) {
    "invalidRequest" -> HttpTransportError.InvalidRequest
    "invalidURL" -> HttpTransportError.InvalidURL
    "insecureURL" -> HttpTransportError.InsecureURL
    "credentialsInURL" -> HttpTransportError.CredentialsInURL
    "serverMismatch" -> HttpTransportError.ServerMismatch
    "redirectRefused" -> HttpTransportError.RedirectRefused
    "requestTooLarge" -> HttpTransportError.RequestTooLarge
    "responseTooLarge" -> HttpTransportError.ResponseTooLarge
    "deadlineExceeded" -> HttpTransportError.DeadlineExceeded
    "cancelled" -> HttpTransportError.Cancelled
    "invalidResponse" -> HttpTransportError.InvalidResponse
    "networkFailure" -> HttpTransportError.NetworkFailure
    else -> throw CorpusException("Unknown transport failure")
}
