package ch.lkmc.monkeyspaw.ui.settings

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.RootedFileStore
import ch.lkmc.monkeyspaw.data.TemporaryFiles
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class AssistantSettingsViewModelTest : TemporaryFiles() {
    private val scheduler = TestCoroutineScheduler()
    private val main = StandardTestDispatcher(scheduler, "settings-main")
    private var onWorker = false
    private val worker = object : CoroutineDispatcher() {
        private val delegate = StandardTestDispatcher(scheduler, "settings-io")
        override fun dispatch(context: CoroutineContext, block: Runnable) = delegate.dispatch(context, Runnable {
            val previous = onWorker
            onWorker = true
            try { block.run() } finally { onWorker = previous }
        })
    }
    private val applicationScope = CoroutineScope(SupervisorJob() + worker)
    private val models = ViewModelStore()
    private val changes = AssistantProviderChanges()
    private val secrets = TestSecrets { assertTrue(onWorker, "Secret IO must run on the worker") }
    private var writes = 0
    private var writeFailure: Exception? = null
    private val files by lazy {
        val base = RootedFileStore(stateDir.toFile(), RootedFileStore.Scan.STATE)
        object : StateStore by base {
            override fun read(path: String): ByteArray { assertTrue(onWorker); return base.read(path) }
            override fun write(bytes: ByteArray, path: String) {
                assertTrue(onWorker)
                writeFailure?.let { throw it }
                writes++
                base.write(bytes, path)
            }
        }
    }
    private val settings = lazy { assertTrue(onWorker); ProviderSettingsService(ProviderSettingsStore(files), secrets, worker) }
    private val client = TestClient { assertTrue(onWorker) }
    private var completion: CoroutineDispatcher = main
    private val testing = lazy {
        assertTrue(onWorker)
        AssistantConnectionService(settings.value, client, client, worker, completion,
            MonotonicClock { scheduler.currentTime * 1_000_000L }, main)
    }

    @BeforeTest fun setMain() { Dispatchers.setMain(main); Files.createDirectories(stateDir) }
    @AfterTest fun retire() { models.clear(); applicationScope.cancel(); scheduler.runCurrent(); Dispatchers.resetMain() }

    @Test fun `empty and all draft edits remain local until explicit Save or Test`() = runTest(scheduler) {
        val model = model()
        assertNull(model.state.value.draft)
        model.save(); model.testConnection(); model.keepKey(); model.clearKey(); model.renameProfile("ignored")
        assertEquals(0, writes)
        model.addProfile(ProviderKind.OPENAI_COMPATIBLE)
        val id = model.state.value.draft!!.id
        assertEquals("", model.state.value.draft!!.modelID)
        model.renameProfile("Local")
        model.setKind(ProviderKind.ANTHROPIC)
        model.setBaseURL("https://example.com/v1/messages/")
        model.setModelID("manual")
        model.setKeyInput(" input ")
        assertEquals(AssistantKeyEdit.REPLACE, model.state.value.keyEdit)
        model.keepKey(); model.clearKey(); model.setKeyInput(" \n\t")
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertEquals(id, model.state.value.draft!!.id)
        assertEquals(0, writes)
        assertEquals(0, client.calls)
        assertEquals(0, secrets.reads)
        assertEquals(0, changes.generation.value)
        model.save(); runCurrent()
        assertEquals(listOf("Local"), model.state.value.profiles.map { it.displayName })
        assertEquals("https://example.com", model.state.value.draft!!.baseURL)
        assertEquals(id, model.state.value.selectedProfileID)
        assertEquals(2, changes.generation.value)
    }

    @Test fun `adding and saving retains active profile and selection or none persists`() = runTest(scheduler) {
        val first = seed()
        val model = model()
        model.addProfile()
        val newID = model.state.value.draft!!.id
        model.save(); runCurrent()
        assertEquals(first.id, model.state.value.selectedProfileID)
        assertEquals(newID, model.state.value.draft!!.id)
        model.selectProfile(newID); runCurrent()
        assertEquals(newID, model.state.value.selectedProfileID)
        model.selectProfile(null); runCurrent()
        assertNull(model.state.value.selectedProfileID)
        assertNull(model.state.value.draft)
        assertEquals(AssistantKeyStorage.None, model.state.value.keyStorage)
        withContext(worker) {
            assertNull(ProviderSettingsService(ProviderSettingsStore(files), secrets, worker).snapshot.settings.selectedProfileID)
        }
        model.testConnection()
        assertEquals(0, client.calls)
    }

    @Test fun `selection discards staged keys and rename only commits on Save`() = runTest(scheduler) {
        val first = seed(key = true)
        val second = seed(name = "Second")
        val model = model()
        model.renameProfile("Staged"); model.setKeyInput(UUID.randomUUID().toString())
        val reset = model.state.value.keyInputReset
        assertEquals(listOf("First", "Second"), model.state.value.profiles.map { it.displayName })
        model.selectProfile(second.id); runCurrent()
        assertEquals(second.id, model.state.value.draft!!.id)
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertNotEquals(reset, model.state.value.keyInputReset)
        model.selectProfile(first.id); runCurrent()
        assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
        model.renameProfile("Renamed"); model.save(); runCurrent()
        assertEquals("Renamed", model.state.value.profiles.first().displayName)
        assertEquals(0, client.calls)
    }

    @Test fun `blank keeps and Clear is staged with failure preserving key and reset token`() = runTest(scheduler) {
        seed(key = true)
        val model = model()
        model.setKeyInput("\n \t"); model.save(); runCurrent()
        assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
        model.setKeyInput("replacement"); model.clearKey()
        val reset = model.state.value.keyInputReset
        val before = writes
        assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
        model.testConnection(); runCurrent()
        assertNull(client.lastKey)
        assertEquals(before, writes)
        writeFailure = IllegalStateException(UUID.randomUUID().toString())
        model.save(); runCurrent()
        assertEquals(ProviderSettingsError.WriteFailed, model.state.value.error)
        assertEquals(AssistantKeyEdit.CLEAR, model.state.value.keyEdit)
        assertEquals(reset, model.state.value.keyInputReset)
        assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
        writeFailure = null
        model.save(); runCurrent()
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertEquals(AssistantKeyStorage.None, model.state.value.keyStorage)
        assertNotEquals(reset, model.state.value.keyInputReset)
    }

    @Test fun `deleting new inactive and active profiles leaves coherent draft`() = runTest(scheduler) {
        val first = seed(key = true)
        val second = seed(name = "Other")
        val model = model()
        val before = changes.generation.value
        model.addProfile(); model.setKeyInput("discarded")
        model.deleteProfile(model.state.value.draft!!.id); runCurrent()
        assertEquals(before, changes.generation.value)
        assertEquals(first.id, model.state.value.draft!!.id)
        model.setKeyInput("staged")
        model.deleteProfile(second.id); runCurrent()
        assertEquals(AssistantKeyEdit.REPLACE, model.state.value.keyEdit)
        assertEquals(first.id, model.state.value.draft!!.id)
        model.deleteProfile(first.id); runCurrent()
        assertTrue(model.state.value.profiles.isEmpty())
        assertNull(model.state.value.draft)
        assertNull(model.state.value.selectedProfileID)
    }

    @Test fun `selection and deletion failures preserve staged metadata and key`() = runTest(scheduler) {
        val saved = seed(key = true)
        val model = model()
        model.renameProfile("Staged"); model.setKeyInput("replacement")
        val draft = model.state.value.draft
        val reset = model.state.value.keyInputReset
        model.selectProfile(ProviderProfileID()); runCurrent()
        assertEquals(ProviderSettingsError.ProfileNotFound, model.state.value.error)
        assertEquals(draft, model.state.value.draft)
        secrets.deleteError = SecretStoreError.DeleteFailed
        model.deleteProfile(saved.id); runCurrent()
        assertEquals(ProviderSettingsError.Secret(SecretStoreError.DeleteFailed), model.state.value.error)
        assertEquals(draft, model.state.value.draft)
        assertEquals(reset, model.state.value.keyInputReset)
        assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
    }

    @Test fun `read-only metadata never resets or publishes a false success`() = runTest(scheduler) {
        for ((raw, expected) in listOf("invalid" to ProviderSettingsError.CorruptFile,
            "{\"version\":999}" to ProviderSettingsError.FutureVersion(999))) {
            val root = Files.createDirectories(temporary.resolve(expected.toString()))
            val isolated = RootedFileStore(root.toFile(), RootedFileStore.Scan.STATE)
            withContext(worker) { isolated.writePrivate(raw.encodeToByteArray(), "provider-settings.json") }
            val service = withContext(worker) { ProviderSettingsService(ProviderSettingsStore(isolated), secrets, worker) }
            val model = model(service)
            assertEquals(expected, model.state.value.readOnlyError)
            assertEquals(expected, model.state.value.error)
            assertFalse(model.state.value.canChangeProfiles)
            model.addProfile(); model.save(); model.selectProfile(null); model.testConnection(); runCurrent()
            assertNull(model.state.value.draft)
            assertEquals(raw, withContext(worker) { isolated.read("provider-settings.json").decodeToString() })
        }
        assertEquals(0, client.calls)
    }

    @Test fun `failed compensation for new profile reports unknown storage and preserves draft`() = runTest(scheduler) {
        val model = model()
        model.addProfile(); model.setKeyInput(UUID.randomUUID().toString())
        val draft = model.state.value.draft
        val reset = model.state.value.keyInputReset
        writeFailure = StoreError.IOFailure
        secrets.deleteError = SecretStoreError.DeleteFailed
        model.save(); runCurrent()
        assertEquals(ProviderSettingsError.SecretRollbackFailed, model.state.value.error)
        assertTrue(model.state.value.isReadOnly)
        assertTrue(model.state.value.isNewProfile)
        assertEquals(draft, model.state.value.draft)
        assertEquals(reset, model.state.value.keyInputReset)
        assertEquals(AssistantKeyStorage.Failed(ProviderSettingsError.SecretRollbackFailed), model.state.value.keyStorage)
    }

    @Test fun `newer metadata and key input survive Save and persistence cannot overlap`() = runTest(scheduler) {
        val model = model()
        model.addProfile(); model.setKeyInput("first")
        secrets.writeGate = CompletableDeferred()
        model.save(); runCurrent()
        assertEquals(AssistantSettingsOperation.SAVING, model.state.value.operation)
        assertTrue(model.state.value.canEditDraft)
        model.save(); model.selectProfile(null); model.deleteProfile(model.state.value.draft!!.id)
        model.addProfile(); model.refresh(); model.testConnection()
        model.renameProfile("Newer name"); model.setModelID("newer model"); model.setKeyInput("newer key")
        val reset = model.state.value.keyInputReset
        assertEquals(1, changes.generation.value)
        secrets.writeGate!!.complete(Unit); runCurrent()
        assertEquals(1, secrets.writes)
        assertEquals(0, client.calls)
        assertEquals("Anthropic", model.state.value.profiles.first().displayName)
        assertEquals("Newer name", model.state.value.draft!!.displayName)
        assertEquals("newer model", model.state.value.draft!!.modelID)
        assertEquals(AssistantKeyEdit.REPLACE, model.state.value.keyEdit)
        assertEquals(reset, model.state.value.keyInputReset)
        model.save(); runCurrent()
        assertEquals("Newer name", model.state.value.profiles.first().displayName)
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertEquals("newer key", withContext(worker) { settings.value.connection(model.state.value.draft!!.id).key!!.withValue { it } })
    }

    @Test fun `committed key resets despite newer metadata and destination still requires re-entry`() = runTest(scheduler) {
        val model = model()
        model.addProfile(); model.setKeyInput(UUID.randomUUID().toString())
        val reset = model.state.value.keyInputReset
        secrets.writeGate = CompletableDeferred()
        model.save(); runCurrent()
        model.setBaseURL("https://another.example"); model.renameProfile("Newer")
        secrets.writeGate!!.complete(Unit); runCurrent()
        assertEquals("https://another.example", model.state.value.draft!!.baseURL)
        assertEquals("Newer", model.state.value.draft!!.displayName)
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertNotEquals(reset, model.state.value.keyInputReset)
        model.save(); runCurrent()
        assertEquals(ProviderSettingsError.KeyRequiredForChangedDestination, model.state.value.error)
        assertTrue(model.state.value.requiresKeyReentry)
        model.testConnection(); runCurrent()
        assertEquals(ConnectionTestResult.Settings(ProviderSettingsError.KeyRequiredForChangedDestination), model.state.value.testResult)
        assertEquals(0, client.calls)
        model.clearKey(); model.save(); runCurrent()
        assertNull(model.state.value.error)
        assertEquals(AssistantKeyStorage.None, model.state.value.keyStorage)
    }

    @Test fun `every draft edit invalidates Test and exact byte spelling distinguishes edits`() = runTest(scheduler) {
        val edits: List<(AssistantSettingsViewModel, String) -> Unit> = listOf(
            { m, s -> m.renameProfile(s) }, { m, s -> m.setBaseURL("https://example.com/$s") },
            { m, s -> m.setModelID(s) }, { m, s -> m.setKeyInput(s) })
        for (edit in edits) {
            val model = model(); model.addProfile()
            edit(model, "é")
            client.gate = CompletableDeferred()
            model.testConnection(); runCurrent()
            edit(model, "é")
            assertTrue(model.state.value.isTesting)
            edit(model, "e\u0301")
            assertFalse(model.state.value.isTesting)
            client.gate!!.complete(listOf(ModelDescriptor("stale"))); runCurrent()
            assertNull(model.state.value.testResult)
            assertTrue(model.state.value.availableModels.isEmpty())
        }
    }

    @Test fun `kind Keep and Clear invalidate pending Test`() = runTest(scheduler) {
        for (edit in listOf<(AssistantSettingsViewModel) -> Unit>(
            { it.setKind(ProviderKind.OPENAI_COMPATIBLE) }, { it.keepKey() }, { it.clearKey() })) {
            val model = model(); model.addProfile(); model.setKeyInput("initial")
            client.gate = CompletableDeferred()
            model.testConnection(); runCurrent()
            edit(model)
            client.gate!!.complete(listOf(ModelDescriptor("stale"))); runCurrent()
            assertFalse(model.state.value.isTesting)
            assertNull(model.state.value.testResult)
            assertTrue(model.state.value.availableModels.isEmpty())
        }
    }

    @Test fun `queued reply cannot revive a switch away and back or a superseded Test`() = runTest(scheduler) {
        val first = seed(); val second = seed(name = "Other")
        val queued = QueuedDispatcher()
        completion = queued
        val model = model()
        client.models = listOf(ModelDescriptor("old"))
        model.testConnection(); runCurrent()
        model.selectProfile(second.id); runCurrent()
        model.selectProfile(first.id); runCurrent()
        client.gate = CompletableDeferred()
        model.testConnection(); runCurrent()
        queued.drain()
        assertTrue(model.state.value.isTesting)
        assertNull(model.state.value.testResult)
        client.gate!!.complete(listOf(ModelDescriptor("current"))); runCurrent(); queued.drain()
        assertEquals(listOf("current"), model.state.value.availableModels.map { it.id })
    }

    @Test fun `Cancel and failure retain unchanged suggestions and empty success permits manual model`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.setModelID("manual")
        model.testConnection(); runCurrent()
        assertEquals(listOf("listed"), model.state.value.availableModels.map { it.id })
        client.gate = CompletableDeferred()
        model.testConnection(); runCurrent(); model.cancelTest()
        client.gate!!.complete(emptyList()); runCurrent()
        assertEquals(ConnectionTestResult.Cancelled, model.state.value.testResult)
        assertEquals(listOf("listed"), model.state.value.availableModels.map { it.id })
        client.gate = null
        for ((error, expected) in listOf(
            AssistantError.Authentication to ConnectionTestResult.Authentication,
            AssistantError.ModelNotFound to ConnectionTestResult.NotFound,
            AssistantError.RateLimited(2.0) to ConnectionTestResult.RateLimited(2.0),
            AssistantError.ProviderFailure(405) to ConnectionTestResult.UnsupportedListing,
            AssistantError.InvalidOutput to ConnectionTestResult.InvalidResponse,
            HttpTransportError.NetworkFailure to ConnectionTestResult.Network,
            HttpTransportError.DeadlineExceeded to ConnectionTestResult.Timeout,
            AssistantError.ProviderFailure(503) to ConnectionTestResult.ProviderFailure(503))) {
            client.failure = if (error is HttpTransportError) AssistantError.Transport(error) else error
            model.testConnection(); runCurrent()
            assertEquals(expected, model.state.value.testResult)
            assertEquals("manual", model.state.value.draft!!.modelID)
            assertEquals(listOf("listed"), model.state.value.availableModels.map { it.id })
        }
        client.failure = null; client.models = emptyList()
        model.testConnection(); runCurrent()
        assertEquals(ConnectionTestResult.Ok(emptyList()), model.state.value.testResult)
        assertEquals("manual", model.state.value.draft!!.modelID)
        assertTrue(model.state.value.availableModels.isEmpty())
    }

    @Test fun `Save delete refresh and add all invalidate a pending Test`() = runTest(scheduler) {
        val saved = seed()
        for (intent in listOf<(AssistantSettingsViewModel) -> Unit>(
            { it.save() }, { it.refresh() }, { it.addProfile() }, { it.deleteProfile(saved.id) })) {
            val model = model()
            client.gate = CompletableDeferred()
            model.testConnection(); runCurrent()
            intent(model); runCurrent()
            client.gate!!.complete(listOf(ModelDescriptor("stale"))); runCurrent()
            assertFalse(model.state.value.isTesting)
            assertTrue(model.state.value.availableModels.isEmpty())
        }
    }

    @Test fun `credential-only Save notifies before and after while metadata stays identical`() = runTest(scheduler) {
        seed(key = true)
        val model = model()
        val profiles = model.state.value.profiles
        model.setKeyInput(UUID.randomUUID().toString())
        secrets.writeGate = CompletableDeferred()
        model.save()
        assertEquals(1, changes.generation.value)
        runCurrent()
        assertEquals(profiles, model.state.value.profiles)
        secrets.writeGate!!.complete(Unit); runCurrent()
        assertEquals(2, changes.generation.value)
        assertEquals(profiles, model.state.value.profiles)
        model.refresh(); runCurrent(); model.addProfile()
        assertEquals(2, changes.generation.value)
    }

    @Test fun `navigation clears staged keys and late Test replies with no saved-state input`() = runTest(scheduler) {
        val saved = seed(key = true)
        val model = model()
        val sentinel = UUID.randomUUID().toString()
        model.setKeyInput(sentinel)
        client.gate = CompletableDeferred()
        model.testConnection(); runCurrent()
        val reset = model.state.value.keyInputReset
        model.close()
        assertFalse(model.state.value.isOpen)
        assertNull(model.state.value.draft)
        assertNotEquals(reset, model.state.value.keyInputReset)
        client.gate!!.complete(listOf(ModelDescriptor("stale"))); runCurrent()
        assertTrue(model.state.value.availableModels.isEmpty())
        client.gate = null
        model.open(); runCurrent()
        assertEquals(saved.id, model.state.value.draft!!.id)
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        model.testConnection(); runCurrent()
        assertNotEquals(sentinel, client.lastKey?.withValue { it })
        assertTrue(model.javaClass.declaredFields.none { it.type.simpleName == "SavedStateHandle" })
    }

    @Test fun `field disposal discards replacement but preserves staged Clear and metadata`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.renameProfile("Staged"); model.setKeyInput("input")
        model.discardTypedKey()
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertEquals("Staged", model.state.value.draft!!.displayName)
        model.clearKey(); model.discardTypedKey()
        assertEquals(AssistantKeyEdit.CLEAR, model.state.value.keyEdit)
        assertEquals(0, client.calls)
    }

    @Test fun `accepted Save survives departure and destruction and still notifies composition`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.setKeyInput(UUID.randomUUID().toString())
        val id = model.state.value.draft!!.id
        secrets.writeGate = CompletableDeferred()
        model.save(); runCurrent()
        model.close(); models.clear()
        assertNull(model.state.value.draft)
        secrets.writeGate!!.complete(Unit); runCurrent()
        assertEquals(id, withContext(worker) { settings.value.snapshot.settings.selectedProfileID })
        assertEquals(2, changes.generation.value)
        assertNull(model.state.value.draft)
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
    }

    @Test fun `late tier read cannot populate another draft and blocked IO keeps UI responsive`() = runTest(scheduler) {
        seed(key = true)
        secrets.readGate = CompletableDeferred()
        val model = model()
        assertEquals(AssistantKeyStorage.Loading, model.state.value.keyStorage)
        model.addProfile()
        assertEquals(AssistantKeyStorage.None, model.state.value.keyStorage)
        model.renameProfile("UI heartbeat")
        assertEquals("UI heartbeat", model.state.value.draft!!.displayName)
        secrets.readGate!!.complete(Unit); runCurrent()
        assertEquals(AssistantKeyStorage.None, model.state.value.keyStorage)
        assertEquals(0, client.calls)
    }

    @Test fun `every published state and its public fields exclude raw keys and diagnostic bodies`() = runTest(scheduler) {
        seed(key = true)
        val model = model()
        val sentinel = UUID.randomUUID().toString()
        val states = mutableListOf(model.state.value)
        backgroundScope.launch(UnconfinedTestDispatcher(scheduler)) { model.state.collect { states.add(it) } }
        model.setKeyInput(" \n$sentinel\n ")
        model.testConnection(); runCurrent()
        assertEquals(SecretValue(sentinel), client.lastKey)
        client.failure = IllegalStateException(sentinel)
        model.testConnection(); runCurrent()
        assertEquals(ConnectionTestResult.Network, model.state.value.testResult)
        model.renameProfile("Staged metadata")
        writeFailure = IllegalStateException(sentinel)
        model.save(); runCurrent()
        assertEquals(ProviderSettingsError.WriteFailed, model.state.value.error)
        writeFailure = null
        model.save(); runCurrent()
        assertNull(model.state.value.error)
        secrets.readError = IllegalStateException(sentinel)
        model.refresh(); runCurrent()
        assertEquals(AssistantKeyStorage.Failed(ProviderSettingsError.Secret(SecretStoreError.Locked)), model.state.value.keyStorage)
        for (state in states) {
            val texts = listOf(state.toString(), state.draft.toString(), state.keyStorage.toString(),
                state.error.toString(), state.testResult.toString()) +
                listOfNotNull(state.draft?.displayName, state.draft?.baseURL, state.draft?.modelID) +
                state.profiles.flatMap { listOf(it.displayName, it.baseURL, it.modelID) } +
                state.availableModels.flatMap { listOfNotNull(it.id, it.displayName) }
            assertTrue(texts.none { sentinel in it })
            assertTrue(state.javaClass.declaredFields.none { it.type in listOf(ProviderDraft::class.java, SecretValue::class.java, ProviderKeyEdit::class.java) })
        }
        assertFalse(model.toString().contains(sentinel))
        assertFalse(Files.readString(stateDir.resolve("provider-settings.json")).contains(sentinel))
    }

    @Test fun `invalid staged URL diagnostic is redacted`() = runTest(scheduler) {
        val model = model(); model.addProfile()
        val sentinel = UUID.randomUUID().toString()
        model.setBaseURL("https://$sentinel@example.com/?key=$sentinel")
        assertFalse(model.state.value.draft.toString().contains(sentinel))
        assertFalse(model.state.value.toString().contains(sentinel))
        model.save(); runCurrent()
        assertEquals(ProviderSettingsError.CredentialsInURL, model.state.value.error)
    }

    @Test fun `committed reset publishes coherent metadata and Keep mode in every observation`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.setKeyInput("committed")
        val id = model.state.value.draft!!.id
        val reset = model.state.value.keyInputReset
        val observed = mutableListOf<AssistantSettingsUiState>()
        backgroundScope.launch(UnconfinedTestDispatcher(scheduler)) { model.state.collect { observed.add(it) } }
        model.save(); runCurrent()
        val resets = observed.filter { it.keyInputReset != reset }
        assertTrue(resets.isNotEmpty())
        for (state in resets) {
            assertEquals(AssistantKeyEdit.KEEP, state.keyEdit)
            assertEquals(id, state.selectedProfileID)
            assertTrue(state.profiles.any { it.id == id })
        }
    }

    @Test fun `navigation reentered from mutation notification adopts the committed selection`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.setKeyInput("committed")
        val id = model.state.value.draft!!.id
        backgroundScope.launch(UnconfinedTestDispatcher(scheduler)) {
            changes.generation.collect { if (it == 1L) { model.close(); model.open() } }
        }
        model.save(); runCurrent()
        assertTrue(model.state.value.isOpen)
        assertEquals(id, model.state.value.selectedProfileID)
        assertEquals(id, model.state.value.draft?.id)
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
    }

    @Test fun `reentrant Cancel at Test publication prevents obsolete work`() = runTest(scheduler) {
        val model = model(); model.addProfile()
        backgroundScope.launch(UnconfinedTestDispatcher(scheduler)) {
            model.state.collect { if (it.isTesting) model.cancelTest() }
        }
        model.testConnection(); runCurrent()
        assertEquals(0, client.calls)
        assertEquals(ConnectionTestResult.Cancelled, model.state.value.testResult)
    }

    @Test fun `mutation notification cannot reenter and overlap a second Save`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.setKeyInput("committed")
        backgroundScope.launch(UnconfinedTestDispatcher(scheduler)) {
            changes.generation.collect { if (it == 1L) model.save() }
        }
        model.save(); runCurrent()
        assertEquals(1, secrets.writes)
        assertEquals(2, changes.generation.value)
    }

    @Test fun `operational graph load failure is typed read-only and Refresh can recover`() = runTest(scheduler) {
        var failed = false
        val model = AssistantSettingsViewModel(Lazy {
            assertTrue(onWorker)
            if (!failed) { failed = true; throw IllegalStateException("Unavailable storage graph") }
            settings.value
        }, Lazy { testing.value }, worker, applicationScope, changes)
        models.put(UUID.randomUUID().toString(), model)
        model.open(); runCurrent()
        assertNull(model.state.value.operation)
        assertEquals(ProviderSettingsError.ReadFailed, model.state.value.error)
        assertEquals(ProviderSettingsError.ReadFailed, model.state.value.readOnlyError)
        assertNull(model.state.value.error!!.cause)
        assertFalse(model.state.value.canChangeProfiles)
        model.refresh(); runCurrent()
        assertNull(model.state.value.error)
        assertFalse(model.state.value.isReadOnly)
        model.addProfile()
        assertNotNull(model.state.value.draft)
        assertEquals(0, client.calls)
        assertEquals(0, changes.generation.value)
    }

    @Test fun `field disposal clears an invalid replacement error without changing metadata`() = runTest(scheduler) {
        val model = model(); model.addProfile(); model.renameProfile("Staged")
        model.setKeyInput("invalid\u0000input"); model.save(); runCurrent()
        assertEquals(ProviderSettingsError.InvalidKey, model.state.value.error)
        model.discardTypedKey()
        assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
        assertNull(model.state.value.error)
        assertEquals("Staged", model.state.value.draft!!.displayName)
        assertTrue(model.state.value.profiles.isEmpty())
    }

    @Test fun `failed mutation graph resolution releases operation and completes notifications`() = runTest(scheduler) {
        var unavailable = false
        val model = AssistantSettingsViewModel(Lazy {
            assertTrue(onWorker)
            if (unavailable) throw IllegalStateException("Unavailable storage graph")
            settings.value
        }, Lazy { testing.value }, worker, applicationScope, changes)
        models.put(UUID.randomUUID().toString(), model)
        model.open(); runCurrent(); model.addProfile(); model.setKeyInput("staged")
        unavailable = true
        model.save(); runCurrent()
        assertNull(model.state.value.operation)
        assertEquals(ProviderSettingsError.WriteFailed, model.state.value.error)
        assertEquals(AssistantKeyEdit.REPLACE, model.state.value.keyEdit)
        assertEquals(2, changes.generation.value)
        model.close()
        unavailable = false
        model.open(); runCurrent()
        assertFalse(model.state.value.isReadOnly)
        model.addProfile()
        assertNotNull(model.state.value.draft)
    }

    private fun model(service: ProviderSettingsService? = null): AssistantSettingsViewModel {
        val model = AssistantSettingsViewModel(Lazy { service ?: settings.value }, Lazy { testing.value }, worker, applicationScope, changes)
        models.put(UUID.randomUUID().toString(), model)
        model.open()
        scheduler.runCurrent()
        return model
    }

    private suspend fun seed(name: String = "First", key: Boolean = false): ProviderDraft {
        val draft = ProviderDraft(displayName = name, key = if (key) ProviderKeyEdit.Replace(SecretValue(UUID.randomUUID().toString())) else ProviderKeyEdit.Keep)
        withContext(worker) { settings.value.save(draft) }
        return draft
    }

    private class TestSecrets(private val checkWorker: () -> Unit) : SecretStore {
        val values = mutableMapOf<SecretAccount, SecretValue>()
        var reads = 0
        var writes = 0
        var readGate: CompletableDeferred<Unit>? = null
        var writeGate: CompletableDeferred<Unit>? = null
        var readError: Exception? = null
        var deleteError: Exception? = null
        override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? {
            checkWorker(); reads++
            withContext(NonCancellable) { readGate?.await() }
            readError?.let { throw it }
            return values[account]?.let { StoredSecret(it, SecretTier.KEYSTORE) }
        }
        override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
            checkWorker(); writes++
            writeGate?.await()
            values[account] = value
            return SecretTier.KEYSTORE
        }
        override suspend fun delete(account: SecretAccount) { checkWorker(); deleteError?.let { throw it }; values.remove(account) }
    }

    private class TestClient(private val checkWorker: () -> Unit) : AssistantClient {
        var calls = 0
        var models = listOf(ModelDescriptor("listed"))
        var gate: CompletableDeferred<List<ModelDescriptor>>? = null
        var failure: Exception? = null
        var lastKey: SecretValue? = null
        override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("Deadline required")
        override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage {
            checkWorker(); calls++; lastKey = connection.key
            val reply = withContext(NonCancellable) { gate?.await() } ?: models
            failure?.let { throw it }
            return AssistantModelPage(reply)
        }
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse = error("No assistant action in settings")
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse = error("No assistant action in settings")
    }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val queue = ConcurrentLinkedQueue<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { queue.add(block) }
        fun drain() { while (true) (queue.poll() ?: return).run() }
    }
}
