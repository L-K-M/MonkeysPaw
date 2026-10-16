package ch.lkmc.monkeyspaw.ui.editor

import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*

/** Real rooted stores and the existing editor/repository graph, with controllable publication. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class AssistantAcceptanceTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val applicationScope = CoroutineScope(SupervisorJob() + dispatcher)
    private var sequence = 0

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clear() { models.clear(); applicationScope.cancel(); Dispatchers.resetMain() }

    private class Worker(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        var held = false
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            if (held) tasks.addLast(block) else delegate.dispatch(context, block)
        }
        fun release() { if (tasks.isNotEmpty()) tasks.removeFirst().run() }
        fun releaseAll() { while (tasks.isNotEmpty()) release() }
    }

    private inner class Harness(private val test: TestScope) {
        private val root = temporary.resolve("acceptance-${sequence++}")
        val promptRoot = root.resolve("library")
        val stateRoot = root.resolve("state")
        val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
        val io = Worker(dispatcher)
        val prompts = AndroidPromptStore(promptRoot.toFile())
        private val state = AndroidStateStore(stateRoot.toFile())
        val calls = mutableListOf<AssistantRequest>()
        val writes = mutableListOf<String>()
        var beforeCreate: ((String) -> Unit)? = null
        var afterPublish: ((String) -> Unit)? = null
        var onStamp: ((String) -> Unit)? = null
        var onStateWrite: ((String) -> Unit)? = null
        var provenanceFailure = false
        var historyFailure = false
        var access = AssistantAccessState.PRIVATE_PROMPT
        var graph = UUID.randomUUID()
        var credentials = 0L
        private var entropy = 0
        private val files = object : PromptStore by prompts {
            override fun stamp(path: String): FileStamp? { onStamp?.invoke(path); return prompts.stamp(path) }
            override fun write(bytes: ByteArray, path: String) {
                prompts.write(bytes, path); writes.add(path); afterPublish?.invoke(path)
            }
            override fun create(bytes: ByteArray, path: String) {
                beforeCreate?.invoke(path)
                prompts.create(bytes, path); writes.add(path); afterPublish?.invoke(path)
            }
        }
        private val records = object : StateStore by state {
            override fun writePrivate(bytes: ByteArray, path: String) {
                onStateWrite?.invoke(path)
                if (provenanceFailure && path.endsWith("/head.json")) throw StoreError.IOFailure
                state.writePrivate(bytes, path)
            }
            override fun delete(path: String) {
                if (historyFailure && path.endsWith(".md")) throw StoreError.IOFailure
                state.delete(path)
            }
        }
        val library = LibraryService(files, records, clock, Entropy { count -> ByteArray(count) { (++entropy).toByte() } },
            AssistantAccess { access })
        val repository = LibraryRepository(library, EditingService(library), prompts, io)
        val editor = EditorViewModel(repository, dispatcher, clock, applicationScope).also { models.put(root.toString(), it) }
        lateinit var providers: ProviderSettingsService
        lateinit var service: AssistantService
        lateinit var assistant: AssistantSession

        suspend fun configure(source: String? = null, path: String = "a.md", kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE) {
            prompts.prepareRoot()
            if (source != null) {
                put(promptRoot.resolve(path), source.encodeToByteArray())
                editor.open(LibrarySelection(PromptIdentity.at(path), path))
                test.runCurrent()
            }
            val settings = MutableStateFlow(AndroidSettings())
            val dataStore = object : DataStore<AndroidSettings> {
                override val data = settings
                override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings =
                    transform(settings.value).also { settings.value = it }
            }
            val providerFiles = AndroidStateStore(root.resolve("provider-state").toFile(),
                settings = AndroidSettingsStore(dataStore), isMainThread = { false })
            val secrets = object : SecretStore {
                private val stored = mutableMapOf<SecretAccount, StoredSecret>()
                override suspend fun read(account: SecretAccount, source: SecretReadSource) = stored[account]
                override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
                    stored[account] = StoredSecret(value, SecretTier.KEYSTORE); return SecretTier.KEYSTORE
                }
                override suspend fun delete(account: SecretAccount) { stored.remove(account) }
            }
            providers = ProviderSettingsService(ProviderSettingsStore(providerFiles), secrets, dispatcher)
            providers.save(ProviderDraft(kind = kind, modelID = "model", key = ProviderKeyEdit.typed("fixture-key")))
            val client = object : AssistantClient {
                override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse = error("Missing deadline")
                override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
                    calls.add(request)
                    return AssistantResponse(AssistantOutput.Artifact(LlmArtifact("Candidate", "", emptyList(), emptyList(),
                        "  文書 e\u0301 {{topic}}\r\n\n", "Session-only notes")), AssistantTokenUsage(11, 7))
                }
                override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("No model request")
                override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage = error("No model request")
            }
            val monotonic = MonotonicClock { test.testScheduler.currentTime * 1_000_000 }
            service = AssistantService(providers, client, client, dispatcher, clock,
                Entropy { count -> ByteArray(count) { (++entropy).toByte() } }, monotonic, dispatcher)
            assistant = AssistantSession(service, test.backgroundScope, {
                AssistantContext(graph, service.selectedProfile, editor.assistantSnapshot, access, credentials)
            }, monotonic)
            editor.addAssistantContextObserver { assistant.contextChanged() }
        }

        fun ready(improve: Boolean = false): AssistantCandidate {
            if (improve) { assistant.editInstruction("Clarify"); assistant.improve() }
            else assistant.write("Brief")
            test.runCurrent()
            assertEquals(AssistantPhase.READY, assistant.state.value.phase)
            return assertNotNull(assistant.state.value.candidate)
        }

        fun accept(): AssistantAcceptanceOutcome {
            var result: AssistantAcceptanceOutcome? = null
            assistant.accept(editor) { result = it }
            settle()
            return assertNotNull(result)
        }

        fun settle() { repeat(4) { test.runCurrent(); io.releaseAll() }; test.runCurrent() }
        fun decide(choice: EditorDecision) { editor.resolveDecision(checkNotNull(editor.state.value.pendingDecision).id, choice) }
        fun bytes(path: String = "a.md") = Files.readAllBytes(promptRoot.resolve(path))
        fun text(path: String = "a.md") = bytes(path).decodeToString()
        fun exists(path: String) = Files.exists(promptRoot.resolve(path))
        fun disk(source: String, path: String = "a.md") { put(promptRoot.resolve(path), source.encodeToByteArray()) }
    }

    @Test fun `both fake protocols save exact preview bytes and provenance then reject duplicate taps`() = runTest {
        for (kind in ProviderKind.entries) {
            val h = Harness(this)
            h.configure(kind = kind)
            val candidate = h.ready()
            val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
            h.assistant.accept(h.editor, outcomes::add)
            h.assistant.accept(h.editor, outcomes::add)
            h.settle()
            assertEquals(2, outcomes.size)
            assertEquals(AssistantAcceptanceFailure.NotReady, assertIs<AssistantAcceptanceOutcome.Failed>(outcomes.first()).reason)
            val commit = assertNotNull(outcomes.last().committed)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(commit.entry.relativePath))
            assertEquals(candidate.content.document.frontMatter.id, commit.entry.document.frontMatter.id)
            assertEquals(commit.entry.stamp, h.editor.state.value.stamp)
            assertEquals(commit.entry.relativePath, h.editor.state.value.relativePath)
            assertFalse(h.editor.state.value.dirty)
            assertEquals(AssistantPhase.SAVED, h.assistant.state.value.phase)
            assertIs<AssistantAcceptanceOutcome.Saved>(h.assistant.state.value.acceptanceOutcome)
            assertEquals(AssistantTokenUsage(11, 7), h.library.provenance(commit.entry.relativePath)?.usage)
            assertEquals(1, h.writes.size)
            assertFalse(h.assistant.completeAcceptance(UUID.randomUUID(), outcomes.last()))
        }
    }

    @Test fun `repeated cancelled saves complete separately on the shared main scheduler`() = runTest {
        assertSame(dispatcher.scheduler, testScheduler)
        val h = Harness(this)
        h.configure()
        h.beforeCreate = { throw CancellationException("Publication cancelled") }
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        repeat(2) {
            h.ready()
            h.assistant.accept(h.editor, outcomes::add)
            h.settle()
            assertFalse(h.assistant.state.value.isAccepting)
            assertFalse(h.editor.state.value.writing)
        }
        assertEquals(List<AssistantAcceptanceOutcome>(2) { AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Cancelled) }, outcomes)
        assertEquals(outcomes.last(), h.editor.state.value.assistantAcceptanceOutcome)
        assertTrue(h.writes.isEmpty())
    }

    @Test fun `improve retains checked loaded ID omitted by dirty buffer and uses normal history`() = runTest {
        val h = Harness(this)
        val source = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\nfavorite: true\ncustom: retained\n---\nOriginal\r\n"
        h.configure(source)
        h.editor.edit("Unsaved without ID")
        val candidate = h.ready(improve = true)
        assertEquals(ULID.parse("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"), candidate.content.document.frontMatter.id)
        val commit = assertNotNull(h.accept().committed)
        assertContentEquals(candidate.content.canonicalBytes, h.bytes())
        val revision = h.library.history.revisions(commit.entry.identity).single()
        assertContentEquals(source.encodeToByteArray(), h.library.history.read(revision))
        assertFalse(h.editor.state.value.dirty)
        assertNull(h.editor.state.value.conflict)
        assertNull(h.editor.state.value.pendingDecision)
    }

    @Test fun `improve of unsaved draft creates exclusively after guard and fresh diff`() = runTest {
        val h = Harness(this)
        h.configure()
        h.disk("Occupied", "Candidate.md")
        h.editor.createDraft("Draft.md")
        h.editor.edit("Unsaved draft")
        h.ready(improve = true)
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        assertNotNull(h.editor.state.value.pendingDecision)
        h.decide(EditorDecision.DISCARD)
        h.settle()
        assertEquals(AssistantAcceptanceConflict.ChangedBuffer, assertIs<AssistantAcceptanceOutcome.Conflict>(outcomes.single()).reason)
        assertTrue(h.writes.isEmpty())
        h.assistant.showDiff()
        h.settle()
        val candidate = assertNotNull(h.assistant.state.value.candidate)
        val committed = assertNotNull(h.accept().committed)
        assertEquals("Candidate 2.md", committed.entry.relativePath)
        assertContentEquals(candidate.content.canonicalBytes, h.bytes(committed.entry.relativePath))
        assertEquals("Occupied", h.text("Candidate.md"))
        assertFalse(h.exists("Draft.md"))
        assertFalse(h.editor.state.value.isNew)
        assertFalse(h.editor.state.value.dirty)
        assertEquals(committed.entry.stamp, h.editor.state.value.stamp)
        assertEquals(1, h.writes.size)
    }

    @Test fun `fresh write and copy identity survives failed publication feedback and show diff`() = runTest {
        for (copy in listOf(false, true)) {
            val h = Harness(this)
            h.access = if (copy) AssistantAccessState.GROUP_VIEWER else AssistantAccessState.PRIVATE_PROMPT
            h.configure("Original")
            val first = h.ready(improve = copy)
            h.beforeCreate = { throw StoreError.IOFailure }
            assertIs<AssistantAcceptanceOutcome.Failed>(h.accept())
            h.beforeCreate = null
            h.assistant.retryWithFeedback("Try again")
            runCurrent()
            assertEquals(first.content.document.frontMatter.id, h.assistant.state.value.candidate?.content?.document?.frontMatter?.id)
            h.assistant.showDiff()
            runCurrent()
            assertEquals(first.content.document.frontMatter.id, h.assistant.state.value.candidate?.content?.document?.frontMatter?.id)
            val firstCommit = assertNotNull(h.accept().committed)
            h.assistant.showDiff()
            h.settle()
            val second = assertNotNull(h.assistant.state.value.candidate)
            assertNotEquals(firstCommit.entry.document.frontMatter.id, second.content.document.frontMatter.id)
            val secondCommit = assertNotNull(h.accept().committed)
            assertNotEquals(firstCommit.entry.relativePath, secondCommit.entry.relativePath)
            assertContentEquals(first.content.canonicalBytes, h.bytes(firstCommit.entry.relativePath))
            assertEquals(2, h.writes.size)
        }
    }

    @Test fun `exclusive raced names do not overwrite either occupant`() = runTest {
        val h = Harness(this)
        h.configure()
        val candidate = h.ready()
        h.disk("Occupied", "Candidate.md")
        h.beforeCreate = { path -> if (path == "Candidate 2.md") h.disk("Racer", path) }
        val entry = assertNotNull(h.accept().committed).entry
        assertEquals("Candidate 3.md", entry.relativePath)
        assertEquals("Occupied", h.text("Candidate.md"))
        assertEquals("Racer", h.text("Candidate 2.md"))
        assertContentEquals(candidate.content.canonicalBytes, h.bytes(entry.relativePath))
    }

    @Test fun `write Save Discard and Cancel guard completes once without publishing stale preview`() = runTest {
        for (choice in EditorDecision.entries) {
            val h = Harness(this)
            h.configure("Original")
            h.editor.edit("Unsaved")
            val candidate = h.ready()
            val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
            h.assistant.accept(h.editor, outcomes::add)
            assertNotNull(h.editor.state.value.pendingDecision)
            assertTrue(h.assistant.state.value.isAccepting)
            assertEquals(candidate, h.assistant.state.value.candidate)
            assertEquals(AssistantEditorAvailability.BUSY, h.editor.assistantSnapshot?.availability)
            assertTrue(outcomes.isEmpty())
            h.decide(choice)
            h.settle()
            assertEquals(1, outcomes.size)
            if (choice == EditorDecision.CANCEL) {
                assertEquals(AssistantAcceptanceFailure.Cancelled, assertIs<AssistantAcceptanceOutcome.Failed>(outcomes.single()).reason)
                assertEquals("Unsaved", h.editor.state.value.source)
            } else assertEquals(AssistantAcceptanceConflict.ChangedBuffer, assertIs<AssistantAcceptanceOutcome.Conflict>(outcomes.single()).reason)
            assertFalse(h.exists("Candidate.md"))
            assertEquals(if (choice == EditorDecision.SAVE) "Unsaved" else "Original", h.library.load("a.md").document.body)
            assertNull(h.editor.state.value.pendingDecision)
            assertFalse(h.assistant.state.value.isAccepting)
        }
    }

    @Test fun `cancelling queued acceptance preserves earlier guard and permits later decisions`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        h.editor.edit("Unsaved")
        h.ready()
        h.editor.reload()
        val earlier = assertNotNull(h.editor.state.value.pendingDecision)
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        assertEquals(earlier, h.editor.state.value.pendingDecision)
        assertEquals(1, h.editor.state.value.queuedActions.size)
        h.assistant.close()
        assertEquals(1, outcomes.size)
        assertEquals(AssistantAcceptanceFailure.Cancelled, assertIs<AssistantAcceptanceOutcome.Failed>(outcomes.single()).reason)
        assertEquals(earlier, h.editor.state.value.pendingDecision)
        assertTrue(h.editor.state.value.queuedActions.isEmpty())
        h.decide(EditorDecision.CANCEL)
        h.editor.close()
        assertNotNull(h.editor.state.value.pendingDecision)
        h.decide(EditorDecision.CANCEL)
        h.settle()
        assertEquals("Original", h.text())
        assertFalse(h.exists("Candidate.md"))
        assertEquals(1, outcomes.size)
    }

    @Test fun `improve waits behind earlier guard and runs before later navigation`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        h.editor.edit("Unsaved")
        val candidate = h.ready(improve = true)
        h.editor.reload()
        val earlier = assertNotNull(h.editor.state.value.pendingDecision)
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        h.editor.close()
        assertEquals(earlier, h.editor.state.value.pendingDecision)
        assertEquals(2, h.editor.state.value.queuedActions.size)
        h.decide(EditorDecision.CANCEL)
        assertTrue(h.editor.state.value.writing)
        assertTrue(outcomes.isEmpty())
        h.settle()
        assertNotNull(outcomes.single().committed)
        assertContentEquals(candidate.content.canonicalBytes, h.bytes())
        assertFalse(h.editor.state.value.isOpen)
    }

    @Test fun `source modified or deleted during Write opens existing conflict without losing draft`() = runTest {
        for (deleted in listOf(false, true)) {
            val h = Harness(this)
            h.configure("Original")
            h.ready()
            h.io.held = true
            val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
            h.assistant.accept(h.editor, outcomes::add)
            runCurrent()
            if (deleted) Files.delete(h.promptRoot.resolve("a.md")) else h.disk("External")
            h.settle()
            assertIs<AssistantAcceptanceOutcome.Conflict>(outcomes.single())
            assertEquals(deleted, h.editor.state.value.conflict?.deleted)
            assertEquals("Original", h.editor.state.value.source)
            assertFalse(h.exists("Candidate.md"))
            assertTrue(h.writes.isEmpty())
        }
    }

    @Test fun `edits away and back before publication require a new diff`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        h.ready(improve = true)
        h.io.held = true
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        runCurrent()
        h.editor.edit("Away")
        h.editor.edit("Original")
        assertTrue(h.assistant.state.value.isAccepting)
        assertNull(h.assistant.state.value.candidate)
        h.settle()
        assertEquals(AssistantAcceptanceConflict.ChangedBuffer, assertIs<AssistantAcceptanceOutcome.Conflict>(outcomes.single()).reason)
        assertIs<AssistantAcceptanceOutcome.Conflict>(h.assistant.state.value.acceptanceOutcome)
        assertEquals("Original", h.text())
        assertTrue(h.writes.isEmpty())
        h.assistant.showDiff()
        h.settle()
        assertTrue(h.assistant.canAccept)
    }

    @Test fun `newer dirty edits keep authoritative commit before queued reply for every destination`() = runTest {
        for (destination in AssistantSaveDestination.entries) for (warning in listOf(false, true)) {
            val h = Harness(this)
            if (destination == AssistantSaveDestination.PRIVATE_COPY) h.access = AssistantAccessState.GROUP_VIEWER
            h.configure("Original")
            val candidate = h.ready(improve = destination != AssistantSaveDestination.NEW_PROMPT)
            h.provenanceFailure = warning
            h.io.held = true
            val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
            h.assistant.accept(h.editor, outcomes::add)
            runCurrent()
            h.io.release()
            val path = if (destination == AssistantSaveDestination.IMPROVE) "a.md" else "Candidate.md"
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(path))
            assertTrue(outcomes.isEmpty())
            h.editor.edit("Newer buffer")
            assertTrue(h.assistant.state.value.isAccepting)
            assertNull(h.assistant.state.value.acceptanceOutcome)
            h.settle()
            val commit = assertNotNull(outcomes.single().committed)
            assertEquals("Newer buffer", h.editor.state.value.source)
            assertTrue(h.editor.state.value.dirty)
            assertNull(h.editor.state.value.conflict)
            assertEquals(commit.entry.stamp, h.assistant.state.value.acceptanceOutcome?.committed?.entry?.stamp)
            assertEquals(commit.entry.stamp, h.editor.state.value.assistantAcceptanceOutcome?.committed?.entry?.stamp)
            assertEquals(AssistantPhase.SAVED, h.assistant.state.value.phase)
            assertEquals(warning, h.editor.state.value.provenanceMaintenanceFailed)
            assertEquals(1, h.writes.size)
            if (destination != AssistantSaveDestination.IMPROVE) assertEquals(commit.entry.relativePath, h.editor.state.value.lastAssistantCopy?.relativePath)
        }
    }

    @Test fun `publication in progress reports actual commit after assistant or editor retirement`() = runTest {
        for (retireEditor in listOf(false, true)) {
            val h = Harness(this)
            h.configure("Original")
            val candidate = h.ready(improve = true)
            h.afterPublish = {
                h.afterPublish = null
                h.assistant.close()
                if (retireEditor) models.clear() else h.editor.edit("Newer buffer")
            }
            val outcome = h.accept()
            assertNotNull(outcome.committed)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes())
            assertEquals(AssistantPhase.IDLE, h.assistant.state.value.phase)
            assertNotNull(h.editor.state.value.assistantAcceptanceOutcome?.committed)
            if (!retireEditor) {
                assertEquals("Newer buffer", h.editor.state.value.source)
                assertTrue(h.editor.state.value.dirty)
                assertEquals(outcome.committed?.entry?.stamp, h.editor.state.value.stamp)
            }
        }
    }

    @Test fun `history and provenance warnings adopt the same file exactly once`() = runTest {
        for ((history, provenance) in listOf(true to false, false to true, true to true)) {
            val h = Harness(this)
            h.configure("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nOriginal")
            val candidate = h.ready(improve = true)
            val identity = checkNotNull(h.editor.state.value.selection).identity
            repeat(Limits.historyCapPerPrompt) { number ->
                val filename = "20261014T000000.000Z-${number.toString().padStart(6, '0')}.md"
                put(h.stateRoot.resolve("history/${identity.storageKey}/$filename"), "Older".encodeToByteArray())
            }
            h.historyFailure = history
            h.provenanceFailure = provenance
            val commit = assertNotNull(h.accept().committed)
            assertEquals(history, commit.historyMaintenanceFailed)
            assertEquals(history, h.editor.state.value.historyMaintenanceFailed)
            assertEquals(provenance, h.editor.state.value.provenanceMaintenanceFailed)
            assertEquals(1, h.writes.size)
            assertFalse(h.editor.state.value.dirty)
            assertContentEquals(candidate.content.canonicalBytes, h.bytes())
            assertFalse(h.assistant.canAccept)
        }
    }

    @Test fun `live group seam denies viewer overwrite and downgrade retires queued acceptance`() = runTest {
        for (role in listOf(AssistantAccessState.GROUP_VIEWER, AssistantAccessState.GROUP_EDITOR, AssistantAccessState.GROUP_OWNER)) {
            val h = Harness(this)
            h.access = role
            val original = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nOriginal"
            h.configure(original, "Groups/Team/a.md")
            val candidate = h.ready(improve = true)
            val entry = assertNotNull(h.accept().committed).entry
            assertContentEquals(candidate.content.canonicalBytes, h.bytes(entry.relativePath))
            if (role == AssistantAccessState.GROUP_VIEWER) {
                assertEquals("Candidate.md", entry.relativePath)
                assertNotEquals(ULID.parse("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"), entry.document.frontMatter.id)
                assertEquals(original, h.text("Groups/Team/a.md"))
            } else assertEquals("Groups/Team/a.md", entry.relativePath)
        }
        val h = Harness(this)
        h.access = AssistantAccessState.GROUP_EDITOR
        h.configure("Original", "Groups/Team/a.md")
        h.ready(improve = true)
        h.io.held = true
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        runCurrent()
        h.access = AssistantAccessState.GROUP_VIEWER
        h.assistant.contextChanged()
        h.access = AssistantAccessState.GROUP_EDITOR
        h.assistant.contextChanged()
        h.settle()
        assertIs<AssistantAcceptanceOutcome.Failed>(outcomes.single())
        assertEquals(AssistantPhase.IDLE, h.assistant.state.value.phase)
        assertEquals("Original", h.text("Groups/Team/a.md"))
        assertTrue(h.writes.isEmpty())
    }

    @Test fun `pending Write guard retires on cancel graph credentials or editor teardown`() = runTest {
        for (mode in 0..3) {
            val h = Harness(this)
            h.configure("Original")
            h.editor.edit("Unsaved")
            h.ready()
            val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
            h.assistant.accept(h.editor, outcomes::add)
            assertNotNull(h.editor.state.value.pendingDecision)
            when (mode) {
                0 -> h.assistant.cancel()
                1 -> { h.graph = UUID.randomUUID(); h.assistant.contextChanged() }
                2 -> { h.credentials++; h.assistant.contextChanged() }
                3 -> models.clear()
            }
            h.settle()
            assertEquals(1, outcomes.size)
            assertIs<AssistantAcceptanceOutcome.Failed>(outcomes.single())
            assertNull(h.editor.state.value.pendingDecision)
            assertFalse(h.exists("Candidate.md"))
            assertEquals("Original", h.text())
        }
    }

    @Test fun `created destination replacement retains original editor and reports failure`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        h.ready()
        val stamp = h.editor.state.value.stamp
        h.afterPublish = { path -> if (path == "Candidate.md") h.disk("External copy", path) }
        assertIs<AssistantAcceptanceOutcome.Failed>(h.accept())
        assertEquals("a.md", h.editor.state.value.relativePath)
        assertEquals("Original", h.editor.state.value.source)
        assertEquals(stamp, h.editor.state.value.stamp)
        assertNull(h.editor.state.value.conflict)
        assertEquals("External copy", h.text("Candidate.md"))
    }

    @Test fun `editor reads and saves refuse acceptance even when preview source still matches`() = runTest {
        for (save in listOf(false, true)) {
            val h = Harness(this)
            h.configure("Original")
            h.ready(improve = true)
            h.io.held = true
            if (save) h.editor.save() else h.editor.refresh()
            val outcome = h.accept()
            assertEquals(AssistantAcceptanceFailure.EditorBusy, assertIs<AssistantAcceptanceOutcome.Failed>(outcome).reason)
            assertFalse(h.exists("Candidate.md"))
            assertNull(h.library.provenance("a.md"))
            assertEquals("Original", h.library.load("a.md").document.body)
        }
    }

    @Test fun `inline observer cancellation completes its published guard once and keeps dirty text`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        h.editor.edit("Unsaved")
        h.ready()
        h.editor.addAssistantContextObserver {
            if (h.editor.state.value.pendingDecision != null) h.assistant.close()
        }
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        h.settle()
        assertEquals(1, outcomes.size)
        assertEquals(AssistantAcceptanceFailure.Cancelled, assertIs<AssistantAcceptanceOutcome.Failed>(outcomes.single()).reason)
        assertNull(h.editor.state.value.pendingDecision)
        assertEquals("Unsaved", h.editor.state.value.source)
        assertEquals("Original", h.text())
        assertTrue(h.writes.isEmpty())
    }

    @Test fun `external replacement or deletion after verified commit preserves newer dirty text and real outcome`() = runTest {
        for (deleted in listOf(false, true)) {
            val h = Harness(this)
            h.configure("Original")
            h.ready(improve = true)
            h.onStateWrite = { path -> if (path.endsWith("/head.json")) {
                h.onStateWrite = null
                h.editor.edit("Newer buffer")
                if (deleted) Files.delete(h.promptRoot.resolve("a.md")) else h.disk("Later external bytes")
            } }
            val outcome = h.accept()
            assertNotNull(outcome.committed)
            assertNotNull(h.assistant.state.value.acceptanceOutcome?.committed)
            assertEquals("Newer buffer", h.editor.state.value.source)
            assertTrue(h.editor.state.value.dirty)
            assertEquals(deleted, h.editor.state.value.conflict?.deleted)
            if (deleted) assertTrue(h.repository.state.value.snapshot.prompts.isEmpty())
            else {
                assertEquals("Later external bytes", h.editor.state.value.conflict?.source)
                assertEquals("Later external bytes", h.repository.state.value.snapshot.prompts.single().entry.document.body)
                assertNull(h.library.provenance("a.md"))
            }
        }
    }

    @Test fun `guard Save adopts its result before queued navigation changes the library selection`() = runTest {
        val h = Harness(this)
        h.configure("Original")
        h.disk("Other prompt", "b.md")
        h.editor.edit("Unsaved")
        h.ready()
        val selections = mutableListOf<LibrarySelection?>()
        h.editor.onSelectionChanged = selections::add
        val outcomes = mutableListOf<AssistantAcceptanceOutcome>()
        h.assistant.accept(h.editor, outcomes::add)
        h.editor.open(LibrarySelection(PromptIdentity.at("b.md"), "b.md"))
        h.decide(EditorDecision.SAVE)
        h.settle()
        assertEquals(AssistantAcceptanceConflict.ChangedBuffer, assertIs<AssistantAcceptanceOutcome.Conflict>(outcomes.single()).reason)
        assertEquals("b.md", h.editor.state.value.relativePath)
        assertEquals("Other prompt", h.editor.state.value.source)
        assertEquals("b.md", selections.last()?.relativePath)
        assertEquals("Unsaved", h.library.load("a.md").document.body)
        assertFalse(h.exists("Candidate.md"))
    }
}
