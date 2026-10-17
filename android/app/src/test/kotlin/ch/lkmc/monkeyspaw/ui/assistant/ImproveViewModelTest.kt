package ch.lkmc.monkeyspaw.ui.assistant

import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.llm.AnthropicClient
import ch.lkmc.monkeyspaw.core.llm.OpenAIClient
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.ui.editor.*
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import dagger.Lazy
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class ImproveViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val applicationScope = CoroutineScope(SupervisorJob() + dispatcher)
    private var sequence = 0

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clear() { models.clear(); applicationScope.cancel(); Dispatchers.resetMain() }

    private class Worker(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        var held = false
        var executing = false
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            val work = Runnable { executing = true; try { block.run() } finally { executing = false } }
            if (held) tasks.addLast(work) else delegate.dispatch(context, work)
        }
        fun releaseAll() { held = false; while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    private class Client : AssistantClient {
        val calls = mutableListOf<AssistantRequest>()
        var artifact = LlmArtifact("Candidate", "Reusable", listOf("writing"), listOf(LlmArtifact.Field("new", FieldKind.CHOICE,
            "Topic", "Pick one", "", listOf(FieldOption("first", "first")), false, true)),
            "  文書 e\u0301 {{new}}\r\n\n", "Session-only notes")
        var held: CompletableDeferred<Unit>? = null
        var failure: AssistantError? = null
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse = error("Missing deadline")
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
            calls.add(request)
            held?.let { withContext(NonCancellable) { it.await() } }
            failure?.let { throw it }
            val output = if (request.action is AssistantAction.Review) AssistantOutput.Review(
                LlmOutputDecoder.review(reviewJSON(), (request.action as AssistantAction.Review).source))
            else AssistantOutput.Artifact(artifact)
            return AssistantResponse(output, AssistantTokenUsage(11, 7))
        }
        override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("Unexpected listing")
        override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage = error("Unexpected listing")
    }

    private inner class Harness(private val test: TestScope, val kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE) {
        val root = temporary.resolve("improve-${sequence++}")
        val promptRoot = root.resolve("library")
        val recordRoot = root.resolve("state")
        val prompts = AndroidPromptStore(promptRoot.toFile())
        val records = AndroidStateStore(recordRoot.toFile())
        val io = Worker(dispatcher)
        val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
        val monotonic = MonotonicClock { test.testScheduler.currentTime * 1_000_000 }
        var access = AssistantAccessState.PRIVATE_PROMPT
        val authority = AssistantAccess { access }
        val writes = mutableListOf<String>()
        var writeFailure = false
        var provenanceFailure = false
        var afterPublish: (() -> Unit)? = null
        private var entropy = 0
        val random = Entropy { size -> ByteArray(size) { (++entropy).toByte() } }
        val libraryService = LibraryService(object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) {
                assertTrue(io.executing)
                if (writeFailure) throw StoreError.IOFailure
                prompts.write(bytes, path); writes.add(path); afterPublish?.invoke()
            }
            override fun create(bytes: ByteArray, path: String) {
                assertTrue(io.executing)
                prompts.create(bytes, path); writes.add(path); afterPublish?.invoke()
            }
        }, object : StateStore by records {
            override fun writePrivate(bytes: ByteArray, path: String) {
                if (provenanceFailure && path.endsWith("/head.json")) throw StoreError.IOFailure
                records.writePrivate(bytes, path)
            }
        }, clock, random, authority)
        val editingService = EditingService(libraryService)
        val repository = LibraryRepository(libraryService, editingService, prompts, io)
        val editor = EditorViewModel(repository, dispatcher, clock, applicationScope).also { models.put("editor-$sequence", it) }
        val library = LibraryViewModel(repository, dispatcher).also { models.put("library-$sequence", it) }
        val changes = AssistantProviderChanges()
        val anthropic = Client()
        val openAI = Client()
        val client get() = if (kind == ProviderKind.ANTHROPIC) anthropic else openAI
        lateinit var providers: ProviderSettingsService
        lateinit var graph: AssistantGraph
        lateinit var model: ImproveViewModel
        lateinit var review: ReviewViewModel
        var graphFailure = false
        var graphLoads = 0
        var path = "original.md"
        val original = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\ntitle: Original\nfavorite: true\ncustom: {nested: [value, false]}\n---\nOriginal 😀 {{old}}\r\nNo newline"

        suspend fun configure(source: ByteArray? = original.encodeToByteArray(), configured: Boolean = true, http: HttpTransport? = null) {
            prompts.prepareRoot()
            if (source != null) {
                put(promptRoot.resolve(path), source)
                editor.open(LibrarySelection(PromptIdentity.at(path), path))
            }
            val settings = MutableStateFlow(AndroidSettings())
            val store = object : DataStore<AndroidSettings> {
                override val data = settings
                override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings =
                    transform(settings.value).also { settings.value = it }
            }
            val providerFiles = AndroidStateStore(root.resolve("providers").toFile(),
                settings = AndroidSettingsStore(store), isMainThread = { false })
            val secrets = object : SecretStore {
                private val values = mutableMapOf<SecretAccount, StoredSecret>()
                override suspend fun read(account: SecretAccount, source: SecretReadSource) = values[account]
                override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
                    values[account] = StoredSecret(value, SecretTier.KEYSTORE); return SecretTier.KEYSTORE
                }
                override suspend fun delete(account: SecretAccount) { values.remove(account) }
            }
            providers = ProviderSettingsService(ProviderSettingsStore(providerFiles), secrets, dispatcher)
            if (configured) providers.save(ProviderDraft(kind = kind, baseURL = "https://improve.example/v1", modelID = "improve-model",
                key = ProviderKeyEdit.typed("fixture-key")))
            val service = AssistantService(providers,
                http?.let { AnthropicClient(it, monotonic, clock::now) } ?: anthropic,
                http?.let { OpenAIClient(it, ProviderStateStore(providerFiles), monotonic, clock::now) } ?: openAI,
                io, clock, random, monotonic, dispatcher)
            graph = AssistantGraph(service, authority, monotonic)
            val lazy = Lazy {
                assertTrue(io.executing, "Graph resolves on IO")
                graphLoads++
                if (graphFailure) throw ProviderSettingsError.ReadFailed
                graph
            }
            model = ImproveViewModel(lazy, io, changes).also { models.put("improve-$sequence", it); it.bind(editor) }
            review = ReviewViewModel(lazy, io, changes).also { models.put("review-$sequence", it); it.bind(editor) }
            editor.onSelectionChanged = library::selectFromEditor
            library.refresh()
            test.runCurrent()
        }

        fun open(withReview: Boolean = false) {
            if (withReview) {
                review.open(); test.runCurrent(); review.review(); test.runCurrent()
                review.toggleFinding(1)
                assertTrue(review.state.value.canImproveWithThese)
                review.openImprove(model)
                assertEquals(ReviewDestination.IMPROVE, review.state.value.destination)
            } else model.open()
            test.runCurrent()
        }
        fun ready(withReview: Boolean = false): AssistantCandidate {
            open(withReview)
            model.editInstruction("Make it clearer <instruction> & shorter")
            model.improve(); test.runCurrent()
            assertEquals(AssistantPhase.READY, model.state.value.assistant?.phase)
            return assertNotNull(model.state.value.assistant?.candidate)
        }
        fun accept(): AssistantAcceptanceOutcome {
            model.accept(); test.runCurrent()
            return assertNotNull(model.state.value.acceptanceOutcome)
        }
        fun files(): Map<String, List<Byte>> = Files.walk(root).use { paths ->
            paths.filter { Files.isRegularFile(it) }.toList().associate { root.relativize(it).toString() to Files.readAllBytes(it).toList() }
        }
        fun bytes(file: String = path): ByteArray = Files.readAllBytes(promptRoot.resolve(file))
    }

    @Test fun `both clients improve with or without review and save identical displayed bytes as a new history revision`() = runTest {
        for (kind in ProviderKind.entries) for (withReview in listOf(false, true)) {
            val h = Harness(this, kind)
            h.configure()
            h.editor.edit(h.original + "\nUnsaved {{clipboard}}")
            runCurrent()
            val before = h.files()
            val candidate = h.ready(withReview)
            assertEquals(before, h.files(), "Generating and preparing a diff must not write")
            val action = assertIs<AssistantAction.Improve>(h.client.calls.last().action)
            assertEquals(h.editor.state.value.source, action.source)
            assertEquals("Make it clearer <instruction> & shorter", action.instruction)
            assertEquals(if (withReview) listOf("Unmatched") else emptyList(), action.selectedFindings.map { it.quote })
            assertEquals(AssistantMutationAccess.CURRENT_SCOPE, candidate.mutationAccess)
            assertTrue(candidate.content.document.frontMatter.favorite)
            assertTrue(candidate.content.document.source.contains("nested:"))
            assertEquals(listOf(PlaceholderChange.Removed("old"), PlaceholderChange.Removed("clipboard"), PlaceholderChange.Added("new")),
                candidate.diff.placeholderWarnings)
            val displayed = (candidate.diff.frontMatter + candidate.diff.body).filter { it.kind != LineDiffLine.Kind.REMOVED }.joinToString("") { it.text }
            assertContentEquals(candidate.content.canonicalBytes, displayed.encodeToByteArray())
            assertEquals(displayed, candidate.content.document.source)
            assertEquals("improve.example", h.model.state.value.assistant?.providerHost)
            assertEquals("improve-model", h.model.state.value.assistant?.modelID)
            assertEquals(AssistantTokenUsage(11, 7), h.model.state.value.assistant?.usage)
            val committed = assertNotNull(h.accept().committed)
            assertEquals(h.path, committed.entry.relativePath)
            assertContentEquals(displayed.encodeToByteArray(), h.bytes())
            assertEquals(candidate.content.document.frontMatter.id, committed.entry.document.frontMatter.id)
            assertContentEquals(h.original.encodeToByteArray(), h.editingService.history(committed.entry.identity, h.path).single().sourceBytes)
            assertEquals("improve-model", h.libraryService.provenance(h.path)?.model)
            assertFalse(h.bytes().decodeToString().contains("Session-only notes"))
            assertFalse(h.editor.state.value.dirty)
            assertFalse(h.model.state.value.canAccept)
            assertFalse(h.model.state.value.canRetry)
            assertFalse(h.model.state.value.canShowDiff)
            h.model.accept(); runCurrent()
            assertEquals(listOf(h.path), h.writes)
            assertEquals(committed.entry.identity, h.library.state.value.selectedPrompt?.selection?.identity)
        }
    }

    @Test fun `production protocols escape source instruction and selected findings with explicit retries only`() = runTest {
        for (kind in ProviderKind.entries) for (withReview in listOf(false, true)) {
            val calls = mutableListOf<HttpRequest>()
            val transport = HttpTransport { request ->
                calls.add(request)
                val output = if (withReview && calls.size == 1) reviewJSON() else artifactJSON()
                val reply = if (kind == ProviderKind.ANTHROPIC) buildJsonObject {
                    put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", output) }) })
                    put("stop_reason", "end_turn")
                } else buildJsonObject {
                    put("choices", buildJsonArray { add(buildJsonObject {
                        put("message", buildJsonObject { put("content", output) }); put("finish_reason", "stop")
                    }) })
                }
                HttpResponse(200, body = reply.toString().encodeToByteArray())
            }
            val h = Harness(this, kind)
            h.configure(http = transport)
            h.editor.edit("Current & <data> {{old}} {{clipboard}}")
            runCurrent()
            val candidate = h.ready(withReview)
            val message = Json.parseToJsonElement(calls.last().body!!.decodeToString()).jsonObject["messages"]!!.jsonArray.last().jsonObject["content"]!!.jsonPrimitive.content
            assertTrue(message.contains("Current &amp; &lt;data&gt; {{old}} {{clipboard}}"))
            assertTrue(message.contains("Make it clearer &lt;instruction&gt; &amp; shorter"))
            assertEquals(withReview, message.contains("Unmatched"))
            assertFalse(message.contains("Original 😀"))
            val count = calls.size
            h.model.bind(h.editor); h.model.open(); h.model.state.first(); runCurrent()
            assertEquals(count, calls.size)
            assertContentEquals(candidate.content.canonicalBytes, h.accept().committed!!.entry.document.source.encodeToByteArray())
        }
    }

    @Test fun `selected findings remain in the same review session until explicit Improve and stale selections are dropped`() = runTest {
        val h = Harness(this)
        h.configure(); h.open(withReview = true)
        assertEquals(1, h.client.calls.size)
        assertSame(h.review.state.value.assistant, h.model.state.value.assistant)
        assertEquals(setOf(1), h.model.state.value.assistant?.selectedFindings)
        assertFalse(h.model.state.value.canRetry, "Improve must never retry the inherited Review action")
        h.editor.edit("Away"); h.editor.edit(h.original); runCurrent()
        assertTrue(h.model.state.value.assistant!!.selectedFindings.isEmpty())
        h.model.editInstruction("Instruction alone")
        h.model.improve(); runCurrent()
        assertTrue(assertIs<AssistantAction.Improve>(h.client.calls.last().action).selectedFindings.isEmpty())
        assertEquals(2, h.client.calls.size)
        h.model.close()
        assertFalse(h.review.state.value.isOpen)
        assertNull(h.review.state.value.assistant)
    }

    @Test fun `opening Improve after a failed Review cannot retry the inherited Review request`() = runTest {
        val h = Harness(this)
        h.configure(); h.review.open(); runCurrent()
        h.client.failure = AssistantError.Transport(HttpTransportError.NetworkFailure)
        h.review.review(); runCurrent()
        h.review.openImprove(h.model); runCurrent()
        assertTrue(h.model.state.value.isOpen)
        assertFalse(h.model.state.value.canRetry)
        h.model.retryWithFeedback(); runCurrent()
        assertEquals(1, h.client.calls.size)
        h.client.failure = null
        h.model.editInstruction("Instruction only"); h.model.improve(); runCurrent()
        assertIs<AssistantAction.Improve>(h.client.calls.last().action)
        assertEquals(AssistantPhase.READY, h.model.state.value.assistant?.phase)
    }

    @Test fun `retry uses fresh source and instruction keeps transcript and effort and drops findings after edits`() = runTest {
        for (kind in ProviderKind.entries) for (changed in listOf(false, true)) {
            val h = Harness(this, kind)
            h.configure(); h.open(withReview = true)
            h.model.setEffort(AssistantEffort.HIGH)
            h.model.improve(); runCurrent()
            val previous = h.client.calls.last()
            assertEquals(1, assertIs<AssistantAction.Improve>(previous.action).selectedFindings.size)
            h.model.setEffort(AssistantEffort.LOW)
            if (changed) h.editor.edit("Fresh 😀 e\u0301 {{old}}")
            runCurrent()
            h.model.editInstruction("New instruction")
            h.model.editFeedback("Focus on freshness")
            assertEquals(2, h.client.calls.size)
            h.model.retryWithFeedback(); runCurrent()
            val retried = h.client.calls.last()
            val action = assertIs<AssistantAction.Improve>(retried.action)
            assertEquals(h.editor.state.value.source, action.source)
            assertEquals("New instruction", action.instruction)
            assertEquals(if (changed) emptyList() else listOf("Unmatched"), action.selectedFindings.map { it.quote })
            assertEquals(AssistantEffort.HIGH, retried.effort)
            assertEquals("Focus on freshness", retried.feedback)
            assertEquals(2, retried.transcript.size)
            assertEquals(AssistantPhase.READY, h.model.state.value.assistant?.phase)
            assertTrue(h.writes.isEmpty())
        }
    }

    @Test fun `invalid artifact merge and bounded diff failure keep draft notes without an acceptable candidate`() = runTest {
        for (complex in listOf(false, true)) {
            val h = Harness(this)
            val source = if (complex) (0..1100).joinToString("") { "old-$it\n" } else h.original
            h.configure(source.encodeToByteArray())
            val baseline = h.files()
            h.client.artifact = LlmArtifact("Candidate", "", emptyList(), emptyList(),
                if (complex) (0..1100).joinToString("") { "new-$it\n" } else "Unclosed {{topic", "Keep these notes")
            h.open(); h.model.editInstruction("Change"); h.model.improve(); runCurrent()
            val result = h.model.state.value.assistant!!
            assertNull(result.candidate)
            assertFalse(h.model.state.value.canAccept)
            assertEquals("Keep these notes", result.artifact?.notes)
            if (complex) {
                assertEquals(LineDiffError.ComparisonTooComplex, assertIs<AssistantFailure.Diff>(result.failure).error)
                assertEquals(R.string.assistant_diff_failed, assistantFailureResource(result.failure!!))
            } else assertTrue(result.issues.any { it.severity == PromptIssueSeverity.ERROR })
            h.model.accept(); h.model.reject(); runCurrent()
            assertEquals(baseline, h.files())
        }
    }

    @Test fun `buffer away and back refuses acceptance until explicit Show diff with a fresh revision`() = runTest {
        for (withReview in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            val before = h.files()
            val candidate = h.ready(withReview)
            h.editor.edit("Away"); h.editor.edit(h.original)
            assertNull(h.model.state.value.assistant?.candidate)
            assertFalse(h.model.state.value.canAccept)
            h.model.accept(); runCurrent()
            assertEquals(before, h.files())
            h.model.showDiff(); runCurrent()
            val fresh = assertNotNull(h.model.state.value.assistant?.candidate)
            assertNotEquals(candidate.context.editor?.revision, fresh.context.editor?.revision)
            assertEquals(h.editor.assistantSnapshot, fresh.context.editor)
            assertContentEquals(candidate.content.canonicalBytes, fresh.content.canonicalBytes)
            assertEquals(if (withReview) 2 else 1, h.client.calls.size)
            assertContentEquals(fresh.content.canonicalBytes, h.accept().committed!!.entry.document.source.encodeToByteArray())
        }
    }

    @Test fun `queued publication rechecks changed buffer credentials and live access without writes`() = runTest {
        for (transition in 0..2) {
            val h = Harness(this)
            h.configure(); h.ready(withReview = true)
            val before = h.files()
            h.io.held = true
            h.model.accept(); runCurrent()
            when (transition) {
                0 -> { h.editor.edit("Away"); h.editor.edit(h.original) }
                1 -> h.changes.changed()
                else -> h.access = AssistantAccessState.GROUP_VIEWER // No notification: publication still checks authority.
            }
            h.io.releaseAll(); runCurrent()
            assertTrue(h.writes.isEmpty())
            assertEquals(before, h.files())
            assertNull(h.model.state.value.acceptanceOutcome?.committed)
            assertFalse(h.model.state.value.canAccept)
        }
    }

    @Test fun `acceptance can queue behind earlier editor guards and Reject cancels only its own work`() = runTest {
        for (withReview in listOf(false, true)) {
            val h = Harness(this)
            h.configure(); h.editor.edit(h.original + "\nUnsaved"); runCurrent()
            h.ready(withReview)
            val before = h.files()
            h.editor.reload()
            val earlier = assertNotNull(h.editor.state.value.pendingDecision)
            assertEquals(ReviewUnavailable.BUSY, h.model.state.value.unavailable)
            assertTrue(h.model.state.value.canAccept)
            h.model.accept()
            assertEquals(1, h.editor.state.value.queuedActions.size)
            h.model.reject()
            assertEquals(earlier, h.editor.state.value.pendingDecision)
            assertTrue(h.editor.state.value.queuedActions.isEmpty())
            h.editor.resolveDecision(earlier.id, EditorDecision.CANCEL); runCurrent()
            assertEquals(before, h.files())
            assertEquals(h.original + "\nUnsaved", h.editor.state.value.source)
        }
        for (choice in EditorDecision.entries) {
            val h = Harness(this)
            h.access = AssistantAccessState.GROUP_VIEWER
            h.configure(); h.editor.edit(h.original + "\nUnsaved"); runCurrent()
            h.ready(withReview = true)
            h.model.accept()
            runCurrent()
            val guard = assertNotNull(h.editor.state.value.pendingDecision)
            h.editor.resolveDecision(guard.id, choice); runCurrent()
            assertFalse(Files.exists(h.promptRoot.resolve("Candidate.md")))
            assertFalse(h.model.state.value.isAccepting)
            assertFalse(h.model.state.value.canAccept)
        }
    }

    @Test fun `Review owner teardown retires borrowed Improve before a noncooperative provider completes`() = runTest {
        val h = Harness(this)
        h.configure(); h.open(withReview = true)
        val late = CompletableDeferred<Unit>().also { h.client.held = it }
        h.model.improve(); runCurrent()
        val before = h.files()
        h.review.close()
        assertFalse(h.model.state.value.isOpen)
        assertFalse(h.review.state.value.isOpen)
        late.complete(Unit); runCurrent()
        assertNull(h.model.state.value.assistant)
        assertNull(h.review.state.value.assistant)
        assertEquals(before, h.files())
    }

    @Test fun `changed disk opens the existing conflict and retains artifact for a new explicit diff`() = runTest {
        val h = Harness(this)
        h.configure(); h.editor.edit(h.original + "\nUnsaved"); runCurrent()
        h.ready()
        put(h.promptRoot.resolve(h.path), "External {{old}}".encodeToByteArray())
        val result = assertIs<AssistantAcceptanceOutcome.Conflict>(h.accept())
        assertIs<AssistantAcceptanceConflict.Modified>(result.reason)
        assertNotNull(h.editor.state.value.conflict)
        assertNotNull(h.model.state.value.assistant?.artifact)
        assertEquals(h.original + "\nUnsaved", h.editor.state.value.source)
        assertEquals("External {{old}}", h.bytes().decodeToString())
        h.editor.resolveConflict(EditorConflictChoice.TAKE_THEIRS); runCurrent()
        h.model.showDiff(); runCurrent()
        assertEquals("External {{old}}", h.model.state.value.assistant?.candidate?.context?.editor?.source)
        assertTrue(h.model.state.value.canAccept)
        assertTrue(h.writes.isEmpty())
    }

    @Test fun `Reject Back and teardown preserve every file editor buffer stamp and history with late replies`() = runTest {
        for (withReview in listOf(false, true)) for (working in listOf(false, true)) for (departure in 0..2) {
            val h = Harness(this)
            h.configure()
            val before = h.files()
            val snapshot = h.editor.assistantSnapshot
            h.open(withReview)
            val late = if (working) CompletableDeferred<Unit>().also { h.client.held = it } else null
            h.model.editInstruction("Session instruction"); h.model.editFeedback("Session feedback")
            h.model.improve(); runCurrent()
            if (working) { advanceTimeBy(2100); runCurrent(); assertTrue(h.model.state.value.assistant!!.elapsedSeconds >= 2) }
            when (departure) { 0 -> h.model.reject(); 1 -> h.model.close(); else -> models.clear() }
            late?.complete(Unit); runCurrent()
            assertEquals(before, h.files())
            assertTrue(h.writes.isEmpty())
            if (departure != 2) assertEquals(snapshot, h.editor.assistantSnapshot)
            assertNull(h.model.state.value.assistant?.candidate)
            assertNull(h.model.state.value.assistant?.artifact)
            assertEquals(0.0, h.model.state.value.assistant?.elapsedSeconds ?: 0.0)
            advanceTimeBy(2100); runCurrent()
            assertEquals(0.0, h.model.state.value.assistant?.elapsedSeconds ?: 0.0)
            if (departure != 0) assertFalse(h.model.state.value.isOpen)
        }
    }

    @Test fun `live group editor owner and viewer routes keep scope or exclusively create a fresh root copy`() = runTest {
        for (access in listOf(AssistantAccessState.GROUP_EDITOR, AssistantAccessState.GROUP_OWNER, AssistantAccessState.GROUP_VIEWER))
            for (withReview in listOf(false, true)) {
                val h = Harness(this)
                h.path = "Groups/team/original.md"; h.access = access
                h.configure()
                val originalID = h.editor.assistantSnapshot!!.loadedID
                val candidate = h.ready(withReview)
                val copy = access == AssistantAccessState.GROUP_VIEWER
                assertEquals(copy, h.model.state.value.isPrivateCopy)
                assertEquals(copy, candidate.content.document.frontMatter.id != originalID)
                val commit = h.accept().committed!!
                assertTrue(h.model.state.value.isOpen, "Copy adoption must retain the actual saved outcome")
                assertEquals(if (copy) "Candidate.md" else h.path, commit.entry.relativePath)
                assertContentEquals(candidate.content.canonicalBytes, h.bytes(commit.entry.relativePath))
                if (copy) {
                    assertContentEquals(h.original.encodeToByteArray(), h.bytes())
                    assertTrue(h.editingService.history(commit.entry.identity, commit.entry.relativePath).isEmpty())
                } else assertContentEquals(h.original.encodeToByteArray(), h.editingService.history(commit.entry.identity, h.path).single().sourceBytes)
                assertFalse(h.model.state.value.canAccept)
            }
    }

    @Test fun `invalid private read-only validating unavailable and busy sources visibly refuse Improve`() = runTest {
        for ((source, reason) in listOf(
            "---\nprivate: true\n---\nPrivate".encodeToByteArray() to ReviewUnavailable.PRIVATE,
            "Unclosed {{topic".encodeToByteArray() to ReviewUnavailable.INVALID,
            "---\nformat: 2\n---\nFuture".encodeToByteArray() to ReviewUnavailable.READ_ONLY,
            byteArrayOf(0xff.toByte()) to ReviewUnavailable.READ_ONLY,
            null to ReviewUnavailable.SOURCE,
        )) {
            val h = Harness(this)
            h.configure(source); h.open(); h.model.editInstruction("Change")
            assertEquals(reason, h.model.state.value.unavailable)
            assertFalse(h.model.state.value.canImprove)
            h.model.improve(); runCurrent()
            assertTrue(h.client.calls.isEmpty())
        }
        val h = Harness(this)
        h.configure(); h.open()
        h.editor.edit("---\nprivate: true\n---\nPrivate")
        h.model.editInstruction("Change"); h.model.improve()
        assertEquals(ReviewUnavailable.VALIDATING, h.model.state.value.unavailable)
        runCurrent(); assertEquals(ReviewUnavailable.PRIVATE, h.model.state.value.unavailable)
        h.editor.edit(h.original + "\nUnsaved"); runCurrent(); h.editor.reload()
        assertEquals(ReviewUnavailable.BUSY, h.model.state.value.unavailable)
        h.model.improve(); runCurrent(); assertTrue(h.client.calls.isEmpty())
        val missing = Harness(this)
        missing.configure(configured = false); missing.open()
        assertEquals(ReviewUnavailable.PROVIDER, missing.model.state.value.unavailable)
        val blocked = Harness(this)
        blocked.configure(); blocked.access = AssistantAccessState.UNAVAILABLE; blocked.open()
        assertEquals(ReviewUnavailable.ACCESS, blocked.model.state.value.unavailable)
    }

    @Test fun `same-session editing during a held request keeps a stale draft until explicit fresh Show diff`() = runTest {
        val h = Harness(this)
        h.configure(); h.open()
        val late = CompletableDeferred<Unit>().also { h.client.held = it }
        h.model.editInstruction("Change"); h.model.improve(); runCurrent()
        h.editor.edit("Fresh {{old}}"); runCurrent()
        late.complete(Unit); runCurrent()
        assertNotNull(h.model.state.value.assistant?.artifact)
        assertTrue(h.model.state.value.assistant!!.isStale)
        assertNull(h.model.state.value.assistant?.candidate)
        h.model.showDiff(); runCurrent()
        assertEquals("Fresh {{old}}", h.model.state.value.assistant?.candidate?.context?.editor?.source)
        assertTrue(h.model.state.value.canAccept)
        assertEquals(1, h.client.calls.size)
    }

    @Test fun `loaded identity survives an omitted buffer ID and failed saves preserve displayed identity for a new diff`() = runTest {
        val h = Harness(this)
        h.configure(); h.editor.edit("Unsaved without ID {{old}}"); runCurrent()
        val candidate = h.ready()
        assertEquals(h.editor.assistantSnapshot?.loadedID, candidate.content.document.frontMatter.id)
        assertEquals(listOf(PlaceholderChange.Renamed("old", "new")), candidate.diff.placeholderWarnings)
        h.writeFailure = true
        assertIs<AssistantAcceptanceOutcome.Failed>(h.accept())
        assertNotNull(h.model.state.value.assistant?.artifact)
        h.writeFailure = false
        h.model.showDiff(); runCurrent()
        assertNull(h.model.state.value.acceptanceOutcome)
        assertContentEquals(candidate.content.canonicalBytes, h.model.state.value.assistant?.candidate?.content?.canonicalBytes)
        assertContentEquals(candidate.content.canonicalBytes, h.accept().committed!!.entry.document.source.encodeToByteArray())
    }

    @Test fun `committed provenance warnings survive cancellation and prevent another save retry`() = runTest {
        for (withReview in listOf(false, true)) for (close in listOf(false, true)) {
            val h = Harness(this)
            h.configure(); val candidate = h.ready(withReview)
            h.provenanceFailure = true
            h.afterPublish = { if (close) h.model.close() else h.model.cancel() }
            h.model.accept(); runCurrent()
            val outcome = assertIs<AssistantAcceptanceOutcome.CommittedWithProvenanceWarning>(h.editor.state.value.assistantAcceptanceOutcome)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes())
            if (!close) assertSame(outcome, h.model.state.value.acceptanceOutcome)
            else { assertFalse(h.model.state.value.isOpen); assertFalse(h.review.state.value.isOpen) }
            h.model.accept(); h.model.retryWithFeedback(); h.model.showDiff(); runCurrent()
            assertEquals(listOf(h.path), h.writes)
        }
    }

    @Test fun `rebind and collection recreation never resend and session access or credential transitions retire work`() = runTest {
        for (withReview in listOf(false, true)) for (transition in 0..3) {
            val h = Harness(this)
            h.configure(); val candidate = h.ready(withReview)
            val count = h.client.calls.size
            h.model.bind(h.editor); h.model.open(); h.model.state.first(); runCurrent()
            assertSame(candidate, h.model.state.value.assistant?.candidate)
            assertEquals(count, h.client.calls.size)
            when (transition) {
                0 -> h.changes.changed()
                1 -> { h.access = AssistantAccessState.GROUP_VIEWER; h.model.contextChanged(); h.access = AssistantAccessState.PRIVATE_PROMPT; h.model.contextChanged() }
                2 -> h.editor.close()
                else -> { val id = h.graph.service.selectedProfile!!.id; h.providers.selectProfile(null); h.changes.changed(); h.providers.selectProfile(id); h.changes.changed() }
            }
            runCurrent()
            assertNull(h.model.state.value.assistant?.candidate)
            assertFalse(h.model.state.value.canAccept)
            assertTrue(h.writes.isEmpty())
            if (transition == 2) assertFalse(h.model.state.value.isOpen)
        }
    }

    @Test fun `provider failures retain useful instruction without resending and graph reload cannot reopen a retired session`() = runTest {
        val h = Harness(this)
        h.configure(); h.graphFailure = true; h.open()
        assertTrue(h.model.state.value.loadFailed)
        assertNull(h.model.state.value.assistant)
        assertFalse(h.model.state.value.canEdit, "Instruction edits require a loaded assistant session")
        h.model.editFeedback("Unavailable feedback"); h.model.setEffort(AssistantEffort.HIGH)
        assertEquals("", h.model.state.value.feedback)
        assertNull(h.model.state.value.effort)
        h.graphFailure = false; h.model.reload(); runCurrent()
        assertTrue(h.model.state.value.canEdit)
        h.model.editInstruction("Useful instruction")
        h.client.failure = AssistantError.Transport(HttpTransportError.NetworkFailure)
        h.model.improve(); runCurrent()
        assertEquals("Useful instruction", h.model.state.value.assistant?.instruction)
        assertTrue(h.model.state.value.canRetry)
        assertEquals(1, h.client.calls.size)
        h.model.close(); h.io.held = true; h.model.open(); h.editor.close()
        h.io.releaseAll(); runCurrent()
        assertFalse(h.model.state.value.isOpen)
        assertEquals(1, h.client.calls.size)
    }

    @Test fun `instructions feedback notes and findings stay out of diagnostics and Reject persistence`() = runTest {
        val h = Harness(this)
        h.configure(); val baseline = h.files(); h.open(withReview = true)
        val sentinel = "improve-${UUID.randomUUID()}"
        h.client.artifact = LlmArtifact("Candidate", "", emptyList(), emptyList(), "Changed", sentinel)
        h.model.editInstruction(sentinel); h.model.editFeedback(sentinel); h.model.improve(); runCurrent()
        for (diagnostic in listOf(h.model.toString(), h.model.state.value.toString(), h.model.state.value.assistant.toString(),
            h.model.state.value.assistant?.artifact.toString(), h.model.state.value.assistant?.candidate.toString())) {
            assertFalse(diagnostic.contains(sentinel))
        }
        h.model.reject(); runCurrent()
        assertEquals(baseline, h.files())
        assertNull(h.model.state.value.assistant?.artifact)
        h.model.close()
        assertEquals("", h.model.state.value.feedback)
        assertNull(h.model.state.value.assistant)
    }

    companion object {
        private fun reviewJSON(): String = buildJsonObject {
            put("summary", "Summary")
            put("findings", buildJsonArray {
                for (quote in listOf("Original", "Unmatched")) add(buildJsonObject {
                    put("severity", "medium"); put("criterion", "clarity"); put("quote", quote)
                    put("problem", "Problem $quote"); put("suggestion", "Suggestion $quote")
                })
            })
        }.toString()
        private fun artifactJSON(): String = buildJsonObject {
            put("title", "Candidate"); put("description", "Reusable"); put("tags", JsonArray(emptyList()))
            put("fields", JsonArray(emptyList())); put("body", "Changed {{new}}\r\n"); put("notes", "Session-only notes")
        }.toString()
    }
}
