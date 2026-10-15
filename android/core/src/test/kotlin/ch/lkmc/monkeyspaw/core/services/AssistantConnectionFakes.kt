package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AnthropicClient
import ch.lkmc.monkeyspaw.core.llm.OpenAIClient
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.serialization.json.*
import kotlin.test.assertEquals

internal class ConnectionQueuedDispatcher : CoroutineDispatcher() {
    private val jobs = ConcurrentLinkedQueue<Runnable>()
    var isRunning = false
        private set

    override fun dispatch(context: CoroutineContext, block: Runnable) { jobs.add(block) }

    fun drain() {
        isRunning = true
        try { while (true) (jobs.poll() ?: break).run() }
        finally { isRunning = false }
    }
}

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
internal class ConnectionHarness(
    val scheduler: TestCoroutineScheduler,
    val io: CoroutineDispatcher = StandardTestDispatcher(scheduler, "connection-io"),
    val completion: CoroutineDispatcher = StandardTestDispatcher(scheduler, "connection-completion"),
    origin: Long = 123L,
) {
    var clockShift = 0L
    val clock = MonotonicClock { origin + scheduler.currentTime * 1_000_000L + clockShift }
    val provider = ProviderSettingsHarness(io = io)
    val requests = mutableListOf<HttpRequest>()
    val replies = ArrayDeque<suspend (HttpRequest) -> HttpResponse>()
    val transport = HttpTransport { request ->
        requests.add(request)
        if (replies.isEmpty()) throw AssertionError("Unexpected connection request")
        replies.removeFirst().invoke(request)
    }
    val service = AssistantConnectionService(provider.service, AnthropicClient(transport, clock) { utc },
        OpenAIClient(transport, ProviderStateStore(provider.files), clock) { utc }, io, completion, clock,
        timer = StandardTestDispatcher(scheduler, "connection-deadline"))

    fun draft(kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE): ProviderDraft = ProviderDraft(
        kind = kind, modelID = "manual-model", key = ProviderKeyEdit.typed("fixture-only-key"))

    fun enqueue(vararg responses: HttpResponse) { responses.forEach { response -> replies.add { response } } }

    fun start(draft: ProviderDraft = draft()): Pair<AssistantConnectionTest, MutableList<ConnectionTestResult>> {
        val results = mutableListOf<ConnectionTestResult>()
        return service.testConnection(draft) { results.add(it) } to results
    }

    fun run(draft: ProviderDraft = draft()): ConnectionTestResult {
        val (_, results) = start(draft)
        scheduler.runCurrent()
        assertEquals(1, results.size)
        return results.single()
    }

    fun assertNoWrites() {
        assertEquals(emptyList(), provider.files.attemptedWrites)
        assertEquals(emptyList(), provider.secrets.writes)
        assertEquals(emptyList(), provider.secrets.deletions)
    }

    companion object {
        val utc: Instant = Instant.parse("2026-10-14T00:00:00Z")

        fun page(models: List<ModelDescriptor> = emptyList(), more: Boolean = false,
                 first: String? = null, last: String? = null): HttpResponse = HttpResponse(200, body = JsonObject(buildMap {
            put("data", JsonArray(models.map { model -> JsonObject(buildMap {
                put("id", JsonPrimitive(model.id))
                model.displayName?.let { put("display_name", JsonPrimitive(it)) }
                put("unknown", JsonPrimitive("ignored"))
            }) }))
            put("has_more", JsonPrimitive(more))
            first?.let { put("first_id", JsonPrimitive(it)) }
            last?.let { put("last_id", JsonPrimitive(it)) }
            put("unknown", JsonObject(emptyMap()))
        }).toString().encodeToByteArray())
    }
}
