package ch.lkmc.monkeyspaw.ui.assistant

import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.llm.AnthropicClient
import ch.lkmc.monkeyspaw.core.llm.OpenAIClient
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.ui.editor.EditorDecision
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
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
internal class WriteViewModelTest : TemporaryFiles() {
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
            val work = Runnable {
                executing = true
                try { block.run() } finally { executing = false }
            }
            if (held) tasks.addLast(work) else delegate.dispatch(context, work)
        }
        fun releaseAll() { held = false; while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    private class Client : AssistantClient {
        val calls = mutableListOf<AssistantRequest>()
        var response = response()
        var failure: AssistantError? = null
        var held: CompletableDeferred<AssistantResponse>? = null
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse = error("Missing deadline")
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
            calls.add(request)
            failure?.let { throw it }
            return held?.let { withContext(NonCancellable) { it.await() } } ?: response
        }
        override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("Unexpected model request")
        override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage =
            error("Unexpected model request")
        companion object {
            fun response(body: String = "  文書 e\u0301 {{topic}}\r\n\n") = AssistantResponse(AssistantOutput.Artifact(
                LlmArtifact("Candidate", "Reusable", listOf("writing"), listOf(LlmArtifact.Field("topic", FieldKind.CHOICE,
                    "Topic", "Pick a topic", "", listOf(FieldOption("First", "first"), FieldOption("Second", "second")),
                    optional = false, remember = true)), body, "Session-only notes")), AssistantTokenUsage(11, 7))
        }
    }

    private inner class Harness(private val test: TestScope, val kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE) {
        val root = temporary.resolve("write-${sequence++}")
        val promptRoot = root.resolve("library")
        val recordsRoot = root.resolve("state")
        val io = Worker(dispatcher)
        val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
        val monotonic = MonotonicClock { test.testScheduler.currentTime * 1_000_000 }
        val prompts = AndroidPromptStore(promptRoot.toFile())
        private val records = AndroidStateStore(recordsRoot.toFile())
        val writes = mutableListOf<String>()
        var provenanceFailure = false
        var createFailure = false
        var afterCreate: (() -> Unit)? = null
        var access = AssistantAccessState.PRIVATE_PROMPT
        val authority = AssistantAccess { access }
        private var entropy = 0
        val random = Entropy { count -> ByteArray(count) { (++entropy).toByte() } }
        val libraryService = LibraryService(object : PromptStore by prompts {
            override fun create(bytes: ByteArray, path: String) {
                if (createFailure) throw StoreError.IOFailure
                assertTrue(io.executing, "Publication belongs to the IO seam")
                prompts.create(bytes, path)
                writes.add(path)
                afterCreate?.invoke()
            }
        }, object : StateStore by records {
            override fun writePrivate(bytes: ByteArray, path: String) {
                if (provenanceFailure && path.endsWith("/head.json")) throw StoreError.IOFailure
                records.writePrivate(bytes, path)
            }
        }, clock, random, authority)
        val repository = LibraryRepository(libraryService, EditingService(libraryService), prompts, io)
        val library = LibraryViewModel(repository, dispatcher).also { models.put("library-$sequence", it) }
        val editor = EditorViewModel(repository, dispatcher, clock, applicationScope).also { models.put("editor-$sequence", it) }
        val anthropic = Client()
        val openAI = Client()
        val client get() = if (kind == ProviderKind.ANTHROPIC) anthropic else openAI
        val changes = AssistantProviderChanges()
        lateinit var providers: ProviderSettingsService
        lateinit var graph: AssistantGraph
        lateinit var model: WriteViewModel
        var graphFailure = false
        var graphLoads = 0
        val profile get() = requireNotNull(graph.service.selectedProfile)

        suspend fun configure(source: String? = null, configured: Boolean = true, http: HttpTransport? = null) {
            prompts.prepareRoot()
            if (source != null) {
                put(promptRoot.resolve("original.md"), source.encodeToByteArray())
                editor.open(LibrarySelection(PromptIdentity.at("original.md"), "original.md"))
            }
            val settings = MutableStateFlow(AndroidSettings())
            val store = object : DataStore<AndroidSettings> {
                override val data = settings
                override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings =
                    transform(settings.value).also { settings.value = it }
            }
            val providerFiles = AndroidStateStore(root.resolve("provider-state").toFile(),
                settings = AndroidSettingsStore(store), isMainThread = { false })
            val secrets = object : SecretStore {
                private val stored = mutableMapOf<SecretAccount, StoredSecret>()
                override suspend fun read(account: SecretAccount, source: SecretReadSource) = stored[account]
                override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
                    stored[account] = StoredSecret(value, SecretTier.KEYSTORE); return SecretTier.KEYSTORE
                }
                override suspend fun delete(account: SecretAccount) { stored.remove(account) }
            }
            providers = ProviderSettingsService(ProviderSettingsStore(providerFiles), secrets, dispatcher)
            if (configured) providers.save(ProviderDraft(kind = kind, baseURL = "https://provider.example/v1", modelID = "manual-model",
                key = ProviderKeyEdit.typed("fixture-key")))
            val service = AssistantService(providers,
                http?.let { AnthropicClient(it, monotonic, clock::now) } ?: anthropic,
                http?.let { OpenAIClient(it, ProviderStateStore(providerFiles), monotonic, clock::now) } ?: openAI,
                io, clock, random, monotonic, dispatcher)
            graph = AssistantGraph(service, authority, monotonic)
            model = WriteViewModel(Lazy {
                assertTrue(io.executing, "Graph resolution belongs to the IO seam")
                graphLoads++
                if (graphFailure) throw ProviderSettingsError.ReadFailed
                graph
            }, io, changes).also { models.put("write-$sequence", it); it.bind(editor) }
            editor.onSelectionChanged = library::selectFromEditor
            library.refresh()
            test.runCurrent()
        }

        fun open() { model.open(); test.runCurrent() }
        fun ready(brief: String = "Write a reusable prompt"): AssistantCandidate {
            open()
            model.editBrief(brief)
            model.write()
            test.runCurrent()
            assertEquals(AssistantPhase.READY, model.state.value.assistant?.phase)
            return assertNotNull(model.state.value.assistant?.candidate)
        }
        fun accept(): AssistantAcceptanceOutcome {
            model.accept()
            test.runCurrent()
            return assertNotNull(model.state.value.acceptanceOutcome)
        }
        fun bytes(path: String) = Files.readAllBytes(promptRoot.resolve(path))
        fun assertNothingSaved() {
            assertTrue(writes.isEmpty())
            assertFalse(Files.exists(promptRoot.resolve("Candidate.md")))
            assertFalse(Files.exists(recordsRoot.resolve("history")))
        }
    }

    @Test fun `both fake clients save exactly the displayed candidate and provenance and refresh the library`() = runTest {
        for (kind in ProviderKind.entries) {
            val h = Harness(this, kind)
            h.configure()
            h.open()
            assertTrue(h.client.calls.isEmpty())
            assertEquals("provider.example", h.model.state.value.assistant?.providerHost)
            assertEquals("manual-model", h.model.state.value.assistant?.modelID)
            h.model.setEffort(AssistantEffort.HIGH)
            val candidate = h.ready()
            assertEquals(AssistantEffort.HIGH, h.client.calls.single().effort)
            assertEquals(AssistantAction.Write("Write a reusable prompt"), h.client.calls.single().action)
            assertEquals(AssistantTokenUsage(11, 7), h.model.state.value.assistant?.usage)
            assertTrue(h.model.state.value.canAccept)
            val commit = assertNotNull(h.accept().committed)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(commit.entry.relativePath))
            assertEquals(candidate.content.document.frontMatter.id, commit.entry.document.frontMatter.id)
            assertFalse(String(h.bytes(commit.entry.relativePath), Charsets.UTF_8).contains("Session-only notes"))
            val origin = assertNotNull(h.libraryService.provenance(commit.entry.relativePath))
            assertEquals("provider.example", origin.providerHost)
            assertEquals("manual-model", origin.model)
            assertEquals(AssistantTokenUsage(11, 7), origin.usage)
            assertEquals(h.clock.now(), origin.timestamp)
            assertEquals(commit.entry.relativePath, h.library.state.value.rows.single().selection.relativePath)
            assertEquals(commit.entry.identity, h.library.state.value.selectedPrompt?.selection?.identity)
            assertEquals(AssistantPhase.SAVED, h.model.state.value.assistant?.phase)
            assertFalse(h.model.state.value.canAccept)
            h.model.accept()
            runCurrent()
            assertEquals(1, h.writes.size)
        }
    }

    @Test fun `both production protocols send the brief and effort without importing private editor or Fill values`() = runTest {
        for (kind in ProviderKind.entries) {
            val calls = mutableListOf<HttpRequest>()
            val artifact = buildJsonObject {
                put("title", "Candidate"); put("description", "Reusable"); put("tags", JsonArray(emptyList()))
                put("fields", JsonArray(emptyList())); put("body", "Use {{topic}}."); put("notes", "UI notes")
            }.toString()
            val transport = HttpTransport { request ->
                calls.add(request)
                val body = if (kind == ProviderKind.ANTHROPIC) buildJsonObject {
                    put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", artifact) }) })
                    put("stop_reason", "end_turn")
                    put("usage", buildJsonObject { put("input_tokens", 11); put("output_tokens", 7) })
                } else buildJsonObject {
                    put("choices", buildJsonArray { add(buildJsonObject {
                        put("message", buildJsonObject { put("content", artifact) }); put("finish_reason", "stop")
                    }) })
                    put("usage", buildJsonObject { put("prompt_tokens", 11); put("completion_tokens", 7) })
                }
                HttpResponse(200, body = body.toString().encodeToByteArray())
            }
            val h = Harness(this, kind)
            val privateText = "private-${UUID.randomUUID()}"
            val fillValue = "remembered-${UUID.randomUUID()}"
            h.configure("---\nprivate: true\nfields:\n  secret:\n    default: $fillValue\n---\n$privateText {{secret}}", http = transport)
            h.open()
            h.model.setEffort(AssistantEffort.LOW)
            val candidate = h.ready("Brief <data>")
            val request = Json.parseToJsonElement(String(assertNotNull(calls.single().body), Charsets.UTF_8)).jsonObject
            val encoded = request.toString()
            assertTrue(encoded.contains("Brief &lt;data&gt;"))
            assertFalse(encoded.contains(privateText))
            assertFalse(encoded.contains(fillValue))
            assertEquals("low", request[if (kind == ProviderKind.ANTHROPIC) "output_config" else "reasoning_effort"]?.let {
                if (kind == ProviderKind.ANTHROPIC) it.jsonObject["effort"]?.jsonPrimitive?.content else it.jsonPrimitive.content
            })
            val commit = assertNotNull(h.accept().committed)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(commit.entry.relativePath))
            assertEquals(1, calls.size)
        }
    }

    @Test fun `Reject after a committed result resets the session and preserves the saved prompt`() = runTest {
        for (warning in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            val candidate = h.ready()
            h.provenanceFailure = warning
            val outcome = h.accept()
            val commit = assertNotNull(outcome.committed)
            h.model.reject()
            runCurrent()
            assertEquals(AssistantPhase.IDLE, h.model.state.value.assistant?.phase)
            assertNull(h.model.state.value.assistant?.artifact)
            assertNull(h.model.state.value.acceptanceOutcome)
            assertEquals(outcome, h.editor.state.value.assistantAcceptanceOutcome)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(commit.entry.relativePath))
            assertEquals(1, h.library.state.value.rows.size)
            assertEquals(1, h.writes.size)
        }
    }

    @Test fun `invalid draft disables Accept and feedback retries explicitly with the transcript`() = runTest {
        val h = Harness(this)
        h.configure()
        h.client.response = Client.response("Unclosed {{topic")
        h.open()
        h.model.editBrief("Keep this brief")
        h.model.write()
        runCurrent()
        assertEquals(AssistantPhase.DRAFT, h.model.state.value.assistant?.phase)
        assertTrue(h.model.state.value.assistant!!.issues.any { it.severity == PromptIssueSeverity.ERROR })
        assertFalse(h.model.state.value.canAccept)
        h.model.accept()
        h.assertNothingSaved()
        assertTrue(h.model.state.value.canRetry)
        h.model.editFeedback("Close the placeholder")
        assertEquals(1, h.client.calls.size)
        h.client.response = Client.response()
        h.model.retryWithFeedback()
        runCurrent()
        assertEquals(2, h.client.calls.size)
        val retry = h.client.calls.last()
        assertEquals("Close the placeholder", retry.feedback)
        assertEquals(AssistantAction.Write("Keep this brief"), retry.action)
        assertEquals(2, retry.transcript.size)
        assertTrue(h.model.state.value.canAccept)
        assertEquals("Keep this brief", h.model.state.value.brief)
        assertEquals("Close the placeholder", h.model.state.value.feedback)
    }

    @Test fun `Reject Back and clearing the ViewModel retire late replies and write nothing`() = runTest {
        for (working in listOf(false, true)) for (departure in 0..3) {
            val h = Harness(this)
            h.configure()
            val reply = if (working) CompletableDeferred<AssistantResponse>().also { h.client.held = it } else null
            h.open()
            h.model.editBrief("Session brief")
            h.model.write()
            runCurrent()
            when (departure) {
                0 -> h.model.reject()
                1 -> h.model.close()
                2 -> h.model.cancel()
                else -> models.clear()
            }
            reply?.complete(Client.response())
            runCurrent()
            assertNull(h.model.state.value.assistant?.candidate)
            assertFalse(h.model.state.value.canAccept)
            if (departure == 1 || departure == 3) {
                assertFalse(h.model.state.value.isOpen)
                assertEquals("", h.model.state.value.brief)
            } else assertEquals("Session brief", h.model.state.value.brief)
            h.assertNothingSaved()
        }
    }

    @Test fun `activity rebind and a recreated collector preserve working and ready sessions without resending`() = runTest {
        val h = Harness(this)
        h.configure()
        val reply = CompletableDeferred<AssistantResponse>().also { h.client.held = it }
        h.open()
        h.model.editBrief("Keep through rotation")
        h.model.write()
        runCurrent()
        h.model.bind(h.editor)
        h.model.open()
        assertEquals(AssistantPhase.WORKING, h.model.state.first().assistant?.phase)
        assertEquals("Keep through rotation", h.model.state.value.brief)
        assertEquals(1, h.client.calls.size)
        reply.complete(Client.response())
        runCurrent()
        val candidate = h.model.state.value.assistant?.candidate
        h.model.bind(h.editor)
        h.model.open()
        assertSame(candidate, h.model.state.first().assistant?.candidate)
        assertEquals(1, h.client.calls.size)
        assertEquals(1, h.graphLoads)
    }

    @Test fun `missing provider and typed offline failures preserve useful inputs without automatic retries`() = runTest {
        val missing = Harness(this)
        missing.configure(configured = false)
        missing.open()
        missing.model.editBrief("Useful brief")
        assertEquals(AssistantUnavailable.PROVIDER, missing.model.state.value.unavailable)
        assertFalse(missing.model.state.value.canWrite)
        missing.model.write()
        runCurrent()
        assertTrue(missing.client.calls.isEmpty())
        assertEquals("Useful brief", missing.model.state.value.brief)
        for (failure in listOf(AssistantError.Transport(HttpTransportError.NetworkFailure), AssistantError.Authentication,
            AssistantError.ModelNotFound, AssistantError.RateLimited(12.0), AssistantError.Declined,
            AssistantError.UnexpectedStop("provider-body-${UUID.randomUUID()}"))) {
            val h = Harness(this)
            h.configure()
            h.client.failure = failure
            h.open()
            h.model.editBrief("Retain brief")
            h.model.editFeedback("Retain feedback")
            h.model.setEffort(AssistantEffort.MEDIUM)
            h.model.write()
            runCurrent()
            assertEquals(failure, assertIs<AssistantFailure.Assistant>(h.model.state.value.assistant?.failure).error)
            assertEquals("Retain brief", h.model.state.value.brief)
            assertEquals("Retain feedback", h.model.state.value.feedback)
            assertEquals(AssistantEffort.MEDIUM, h.model.state.value.effort)
            assertTrue(h.model.state.value.canRetry)
            assertFalse(h.model.state.value.canAccept)
            assertEquals(1, h.client.calls.size)
            h.assertNothingSaved()
        }
    }

    @Test fun `elapsed and usage stop on completion and cancellation`() = runTest {
        val h = Harness(this)
        h.configure()
        val reply = CompletableDeferred<AssistantResponse>().also { h.client.held = it }
        h.open()
        h.model.editBrief("Timed brief")
        h.model.write()
        runCurrent()
        advanceTimeBy(3100)
        runCurrent()
        assertTrue(h.model.state.value.assistant!!.elapsedSeconds >= 3)
        reply.complete(Client.response())
        runCurrent()
        val elapsed = h.model.state.value.assistant?.elapsedSeconds
        advanceTimeBy(1500)
        runCurrent()
        assertEquals(elapsed, h.model.state.value.assistant?.elapsedSeconds)
        assertEquals(AssistantTokenUsage(11, 7), h.model.state.value.assistant?.usage)
        h.model.cancel()
        advanceTimeBy(1500)
        runCurrent()
        assertEquals(0.0, h.model.state.value.assistant?.elapsedSeconds)
        assertNull(h.model.state.value.assistant?.usage)
    }

    @Test fun `buffer away and back withdraws acceptance until an explicit fresh diff`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        val candidate = h.ready()
        h.editor.edit("Away")
        h.editor.edit("Original")
        assertNull(h.model.state.value.assistant?.candidate)
        assertFalse(h.model.state.value.canAccept)
        h.model.accept()
        h.assertNothingSaved()
        h.model.showDiff()
        runCurrent()
        assertTrue(h.model.state.value.canAccept)
        assertContentEquals(candidate.content.canonicalBytes, h.model.state.value.assistant?.candidate?.content?.canonicalBytes)
        assertEquals(1, h.client.calls.size)
    }

    @Test fun `credential only and profile away and back transitions synchronously retire ready and working requests`() = runTest {
        for (working in listOf(false, true)) for (credentialsOnly in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            val reply = if (working) CompletableDeferred<AssistantResponse>().also { h.client.held = it } else null
            h.open()
            h.model.editBrief("Useful inputs")
            h.model.write()
            runCurrent()
            val id = h.profile.id
            if (!credentialsOnly) h.providers.selectProfile(null)
            h.changes.changed()
            assertNull(h.model.state.value.assistant?.candidate)
            assertEquals(AssistantPhase.IDLE, h.model.state.value.assistant?.phase)
            if (!credentialsOnly) h.providers.selectProfile(id)
            h.changes.changed()
            reply?.complete(Client.response())
            runCurrent()
            assertFalse(h.model.state.value.canAccept)
            assertEquals("Useful inputs", h.model.state.value.brief)
            h.assertNothingSaved()
        }
    }

    @Test fun `dirty Write uses the existing guard and Back cancels only its acceptance`() = runTest {
        for (choice in EditorDecision.entries) {
            val h = Harness(this)
            h.configure("Original")
            h.editor.edit("Unsaved")
            h.ready()
            h.model.accept()
            val decision = assertNotNull(h.editor.state.value.pendingDecision)
            h.editor.resolveDecision(decision.id, choice)
            runCurrent()
            assertTrue(h.writes.isEmpty())
            assertFalse(Files.exists(h.promptRoot.resolve("Candidate.md")))
            assertFalse(h.model.state.value.isAccepting)
        }
        val h = Harness(this)
        h.configure("Original")
        h.editor.edit("Unsaved")
        h.ready()
        h.editor.reload()
        val earlier = assertNotNull(h.editor.state.value.pendingDecision)
        assertEquals(AssistantUnavailable.BUSY, h.model.state.value.unavailable)
        assertTrue(h.model.state.value.canAccept)
        h.model.accept()
        assertEquals(1, h.editor.state.value.queuedActions.size)
        h.model.close()
        assertEquals(earlier, h.editor.state.value.pendingDecision)
        assertTrue(h.editor.state.value.queuedActions.isEmpty())
        h.assertNothingSaved()
        h.editor.resolveDecision(earlier.id, EditorDecision.CANCEL)
    }

    @Test fun `stale access at publication refuses a queued write even without a context notification`() = runTest {
        val h = Harness(this)
        h.configure()
        h.ready()
        h.io.held = true
        h.model.accept()
        runCurrent()
        h.access = AssistantAccessState.UNAVAILABLE
        h.io.releaseAll()
        runCurrent()
        assertIs<AssistantAcceptanceOutcome.Failed>(h.model.state.value.acceptanceOutcome)
        h.assertNothingSaved()
    }

    @Test fun `saved provenance warnings disable another acceptance retry or diff and keep library commit`() = runTest {
        val h = Harness(this)
        h.configure()
        val candidate = h.ready()
        h.provenanceFailure = true
        val result = assertIs<AssistantAcceptanceOutcome.CommittedWithProvenanceWarning>(h.accept())
        assertEquals(R.string.assistant_provenance_warning, assistantOutcomeResource(result))
        assertContentEquals(candidate.content.canonicalBytes, h.bytes(result.commit.entry.relativePath))
        assertEquals(1, h.library.state.value.rows.size)
        assertFalse(h.model.state.value.canAccept)
        assertFalse(h.model.state.value.canRetry)
        assertFalse(h.model.state.value.canShowDiff)
        h.model.accept(); h.model.retryWithFeedback(); h.model.showDiff()
        runCurrent()
        assertEquals(1, h.writes.size)
        assertEquals(1, h.client.calls.size)
    }

    @Test fun `cancellation or Back during publication retains the actual committed warning through the editor`() = runTest {
        for (back in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            val candidate = h.ready()
            h.provenanceFailure = true
            h.afterCreate = { if (back) h.model.close() else h.model.cancel() }
            h.model.accept()
            runCurrent()
            val actual = assertIs<AssistantAcceptanceOutcome.CommittedWithProvenanceWarning>(h.editor.state.value.assistantAcceptanceOutcome)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(actual.commit.entry.relativePath))
            assertEquals(1, h.library.state.value.rows.size)
            if (back) assertFalse(h.model.state.value.isOpen)
            else assertEquals(actual, h.model.state.value.acceptanceOutcome)
            assertFalse(h.model.state.value.canAccept)
            assertEquals(1, h.writes.size)
        }
    }

    @Test fun `credential change retires a queued publication before the IO worker runs`() = runTest {
        val h = Harness(this)
        h.configure()
        h.ready()
        h.io.held = true
        h.model.accept()
        runCurrent()
        h.changes.changed()
        h.io.releaseAll()
        runCurrent()
        assertNull(h.model.state.value.acceptanceOutcome?.committed)
        assertFalse(h.model.state.value.canAccept)
        h.assertNothingSaved()
    }

    @Test fun `failed checked save retains inputs and the exact identity for explicit Show diff`() = runTest {
        val h = Harness(this)
        h.configure()
        val candidate = h.ready()
        h.createFailure = true
        assertIs<AssistantAcceptanceOutcome.Failed>(h.accept())
        assertEquals("Write a reusable prompt", h.model.state.value.brief)
        h.assertNothingSaved()
        h.createFailure = false
        h.model.showDiff()
        runCurrent()
        assertEquals(candidate.content.document.frontMatter.id, h.model.state.value.assistant?.candidate?.content?.document?.frontMatter?.id)
        assertNull(h.model.state.value.acceptanceOutcome)
        assertTrue(h.model.state.value.canAccept)
        assertNotNull(h.accept().committed)
    }

    @Test fun `graph resolution failure is retryable and late load cannot reopen a closed screen`() = runTest {
        val h = Harness(this)
        h.configure()
        h.graphFailure = true
        h.open()
        assertTrue(h.model.state.value.loadFailed)
        h.model.editBrief("Keep while loading")
        h.graphFailure = false
        h.model.reload()
        runCurrent()
        assertEquals("Keep while loading", h.model.state.value.brief)
        assertTrue(h.model.state.value.canWrite)
        h.model.close()
        h.io.held = true
        h.model.open()
        h.model.close()
        h.io.releaseAll()
        runCurrent()
        assertFalse(h.model.state.value.isOpen)
        assertTrue(h.client.calls.isEmpty())
    }

    @Test fun `session inputs artifacts and provider error bodies stay out of diagnostics and persisted files`() = runTest {
        val h = Harness(this)
        h.configure()
        val sentinel = "brief-${UUID.randomUUID()}"
        h.ready(sentinel)
        h.model.editFeedback(sentinel)
        for (diagnostic in listOf(h.model.toString(), h.model.state.value.toString(), h.model.state.value.assistant.toString(),
            h.model.state.value.assistant?.candidate.toString(), h.model.state.value.assistant?.artifact.toString())) {
            assertFalse(diagnostic.contains(sentinel))
            assertFalse(diagnostic.contains("Session-only notes"))
        }
        h.accept()
        Files.walk(h.root).use { paths -> paths.filter { Files.isRegularFile(it) }.forEach { path ->
            val bytes = String(Files.readAllBytes(path), Charsets.UTF_8)
            assertFalse(bytes.contains(sentinel))
            assertFalse(bytes.contains("Session-only notes"))
            assertFalse(bytes.contains("fixture-key"))
        } }
        assertEquals(R.string.assistant_unexpected_stop,
            assistantFailureResource(AssistantFailure.Assistant(AssistantError.UnexpectedStop(sentinel))))
    }
}
