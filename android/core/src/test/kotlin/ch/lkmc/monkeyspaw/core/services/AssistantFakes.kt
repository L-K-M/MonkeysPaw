package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*

internal fun assistantArtifact(body: String = "Use {{topic}}.", notes: String = "Changed the prompt.") =
    LlmArtifact("Generated", "Reusable", listOf("test"), emptyList(), body, notes)

internal fun assistantResponse(body: String = "Use {{topic}}.") =
    AssistantResponse(AssistantOutput.Artifact(assistantArtifact(body)), AssistantTokenUsage(11, 7))

internal class AssistantFakeClient : AssistantClient {
    data class Call(val request: AssistantRequest, val deadline: Long)
    val calls = mutableListOf<Call>()
    val pages = ArrayDeque<AssistantModelPage>()
    val pageCalls = mutableListOf<Pair<String?, Long>>()
    private val answers = ArrayDeque<suspend () -> AssistantResponse>()
    var onCall: (suspend () -> Unit)? = null

    fun answer(response: AssistantResponse) { answers.addLast { response } }
    fun fail(error: AssistantError) { answers.addLast { throw error } }
    fun hold(): CompletableDeferred<AssistantResponse> = CompletableDeferred<AssistantResponse>().also { reply ->
        // A deliberately uncooperative provider exercises replies after cancellation.
        answers.addLast { withContext(NonCancellable) { reply.await() } }
    }

    override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse = error("Missing deadline")
    override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
        calls.add(Call(request, deadlineNanos))
        onCall?.invoke()
        return if (answers.isEmpty()) assistantResponse() else answers.removeFirst().invoke()
    }

    override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("Missing deadline")
    override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage {
        pageCalls.add(afterID to deadlineNanos)
        return if (pages.isEmpty()) AssistantModelPage(emptyList()) else pages.removeFirst()
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
internal class AssistantHarness(private val test: TestScope,
    private val kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE, source: String? = null) {
    val worker = StandardTestDispatcher(test.testScheduler)
    val provider = ProviderSettingsHarness(io = worker)
    val client = AssistantFakeClient()
    private var entropyCounter = 0
    val monotonic = MonotonicClock { test.testScheduler.currentTime * 1_000_000 }
    val service = makeService()
    var context = AssistantContext(UUID.randomUUID(), null, source?.let(::snapshot))
    lateinit var session: AssistantSession

    fun makeService(io: CoroutineDispatcher = worker): AssistantService = AssistantService(provider.service,
        client, client, io, Clock { Instant.parse("2026-10-14T00:00:00Z") },
        Entropy { count -> ByteArray(count) { (++entropyCounter).toByte() } }, monotonic, worker)

    suspend fun configure() {
        provider.service.save(ProviderDraft(kind = kind, modelID = "manual-model", key = ProviderKeyEdit.typed("fixture-key")))
        context = context.copy(profile = service.selectedProfile)
        session = AssistantSession(service, test.backgroundScope, { context }, monotonic)
    }

    fun edit(source: String, notify: Boolean = true) {
        val previous = checkNotNull(context.editor)
        context = context.copy(editor = previous.copy(source = source, revision = previous.revision + 1))
        if (notify) session.contextChanged()
    }

    fun snapshot(source: String) = AssistantEditorSnapshot(source, "a.md", 1, 1, FileStamp("checked"))
}

internal class AssistantHeldDispatcher : CoroutineDispatcher() {
    private val tasks = ArrayDeque<Runnable>()
    override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.addLast(block) }
    fun release() { if (tasks.isNotEmpty()) tasks.removeFirst().run() }
    fun releaseAll() { while (tasks.isNotEmpty()) release() }
}
