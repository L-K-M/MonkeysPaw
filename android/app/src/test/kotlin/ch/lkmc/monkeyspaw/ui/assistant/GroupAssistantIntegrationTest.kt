@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.ui.assistant

import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.Role
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AppModule
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import ch.lkmc.monkeyspaw.ui.editor.EditorDecision
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

/** Live committed group authority, the real assistant binding and checked rooted publication. */
internal class GroupAssistantIntegrationTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val applicationScope = CoroutineScope(SupervisorJob() + dispatcher)
    private var sequence = 0
    private val groupID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAY")!!
    private val promptID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!!
    private val userID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAX")!!
    private val path = "Groups/Team/shared.md"
    private val original = "---\nid: ${promptID.rawValue}\ntitle: Shared\n---\nOriginal {{topic}}\r\n"

    @BeforeTest fun mainDispatcher() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clear() { models.clear(); applicationScope.cancel(); Dispatchers.resetMain() }

    private class Worker(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        var held = false
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            if (held) tasks.addLast(block) else delegate.dispatch(context, block)
        }
        fun releaseAll() { held = false; while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    private inner class Rig(private val test: TestScope, initialRole: Role) {
        val root = temporary.resolve("group-assistant-${sequence++}")
        val promptRoot = root.resolve("library")
        val recordRoot = root.resolve("state")
        val prompts = AndroidPromptStore(promptRoot.toFile(), io = JvmCheckedSyncIO())
        val records = AndroidStateStore(recordRoot.toFile(), isMainThread = { false }, io = JvmCheckedSyncIO())
        val io = Worker(dispatcher)
        private val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
        private var draw = 0
        private val entropy = Entropy { count -> ByteArray(count) { (++draw).toByte() } }
        val authority: AssistantAccess = AppModule.assistantAccess(Lazy { library })
        val library: LibraryService = LibraryService(prompts, records, clock, entropy, authority)
        val editing = EditingService(library)
        val states = SyncStateStore(records, records.syncOperations)
        private val accounts = SyncAccountStore(records, records.syncOperations)
        val binding = SyncLibraryIdentity(SyncAccountIdentity("https://example.test", userID), SyncLibraryRoot(promptRoot.toString()))
        val identity = PromptIdentity.Assigned(promptID)
        val access: GroupAccessService
        val repository = LibraryRepository(library, editing, prompts, io)
        val editor = EditorViewModel(repository, dispatcher, clock, applicationScope).also { models.put("editor-$root", it) }
        var calls = 0
        lateinit var improve: ImproveViewModel
        lateinit var review: ReviewViewModel
        lateinit var write: WriteViewModel

        init {
            prompts.prepareRoot()
            states.update(binding) { it.copy(groups = mapOf(groupID to SyncGroupState("Team", "Team", initialRole)),
                prompts = mapOf(identity to SyncPromptState(SyncScopeKey.Group(groupID), "shared.md", 1,
                    SyncHash.of(CanonicalForm.group(original.encodeToByteArray(), "shared.md").bytes)))) }
            accounts.setAccount(SyncAccount(binding.account, "person", userID, "Android", UUID.randomUUID()))
            access = GroupAccessService(library, states, accounts, promptRoot.toString())
        }

        suspend fun configure(source: String = original) {
            put(promptRoot.resolve(path), source.encodeToByteArray())
            val settings = MutableStateFlow(AndroidSettings())
            val store = object : DataStore<AndroidSettings> {
                override val data = settings
                override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings) =
                    transform(settings.value).also { settings.value = it }
            }
            val providerFiles = AndroidStateStore(root.resolve("providers").toFile(),
                settings = AndroidSettingsStore(store), isMainThread = { false })
            val secrets = object : SecretStore {
                override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? = null
                override suspend fun write(value: SecretValue, account: SecretAccount) = SecretTier.KEYSTORE
                override suspend fun delete(account: SecretAccount) {}
            }
            val providers = ProviderSettingsService(ProviderSettingsStore(providerFiles), secrets, dispatcher)
            providers.save(ProviderDraft(kind = ProviderKind.OPENAI_COMPATIBLE, baseURL = "http://localhost:11434/v1", modelID = "fixture"))
            val client = object : AssistantClient {
                override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse {
                    calls++
                    return AssistantResponse(AssistantOutput.Artifact(LlmArtifact("Improved", "", emptyList(), emptyList(),
                        "Improved {{topic}}\r\n", "")), null)
                }
                override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long) = perform(request, connection)
                override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("Unexpected listing")
                override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage = error("Unexpected listing")
            }
            val monotonic = MonotonicClock { test.testScheduler.currentTime * 1_000_000 }
            val service = AssistantService(providers, client, client, io, clock, entropy, monotonic, dispatcher)
            val graph = Lazy { AssistantGraph(service, authority, monotonic) }
            val changes = AssistantProviderChanges()
            improve = ImproveViewModel(graph, io, changes).also { models.put("improve-$root", it); it.bind(editor) }
            review = ReviewViewModel(graph, io, changes).also { models.put("review-$root", it); it.bind(editor) }
            write = WriteViewModel(graph, io, changes).also { models.put("write-$root", it); it.bind(editor) }
            editor.open(LibrarySelection(identity, path))
            repository.refresh()
            test.runCurrent()
        }

        fun ready(): AssistantCandidate {
            improve.open(); test.runCurrent()
            improve.editInstruction("Clarify")
            improve.improve(); test.runCurrent()
            assertEquals(AssistantPhase.READY, improve.state.value.assistant?.phase)
            return assertNotNull(improve.state.value.assistant?.candidate)
        }
        fun role(role: Role) = states.update(binding) { it.copy(groups = mapOf(groupID to SyncGroupState("Team", "Team", role))) }
        fun removeGroup() = states.update(binding) { it.copy(groups = emptyMap(), prompts = emptyMap()) }
        fun bytes(file: String = path) = Files.readAllBytes(promptRoot.resolve(file))
    }

    @Test fun committedRolesReachTheProductionAssistantAuthority() = runTest {
        val r = Rig(this, Role.OWNER)
        r.configure()
        for ((role, expected) in listOf(Role.OWNER to AssistantAccessState.GROUP_OWNER,
            Role.EDITOR to AssistantAccessState.GROUP_EDITOR, Role.VIEWER to AssistantAccessState.GROUP_VIEWER)) {
            r.role(role)
            assertEquals(expected, r.authority.current(path))
        }
        r.removeGroup()
        assertEquals(AssistantAccessState.UNAVAILABLE, r.authority.current(path))
    }

    @Test fun viewerImprovePublishesTheExactPreviewAsAPrivateCopy() = runTest {
        val r = Rig(this, Role.VIEWER)
        r.configure()
        val candidate = r.ready()
        assertTrue(r.improve.state.value.isPrivateCopy)
        r.improve.accept(); runCurrent()
        val commit = assertNotNull(r.improve.state.value.acceptanceOutcome?.committed)
        assertFalse(commit.entry.relativePath.startsWith("Groups/"))
        assertEquals(candidate.content.document.frontMatter.id, commit.entry.document.frontMatter.id)
        assertNotEquals(promptID, commit.entry.document.frontMatter.id)
        assertContentEquals(candidate.content.canonicalBytes, r.bytes(commit.entry.relativePath))
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertTrue(r.library.history.revisions(r.identity).isEmpty())
    }

    @Test fun ownerAndEditorImproveRetainTheOriginalScopeAndIdentity() = runTest {
        for (role in listOf(Role.OWNER, Role.EDITOR)) {
            val r = Rig(this, role)
            r.configure()
            val candidate = r.ready()
            r.improve.accept(); runCurrent()
            val commit = assertNotNull(r.improve.state.value.acceptanceOutcome?.committed)
            assertEquals(path, commit.entry.relativePath)
            assertEquals(promptID, commit.entry.document.frontMatter.id)
            assertContentEquals(candidate.content.canonicalBytes, r.bytes())
        }
    }

    @Test fun aConflatedDowngradeAndUpgradeRetiresThePreparedCandidate() = runTest {
        val r = Rig(this, Role.EDITOR)
        r.configure()
        val draft = original + "Unsaved"
        r.editor.edit(draft); runCurrent()
        r.ready()
        r.role(Role.VIEWER); r.role(Role.EDITOR)
        r.repository.publishProjection(); runCurrent()
        assertFalse(r.improve.state.value.canAccept)
        assertNull(r.improve.state.value.assistant?.candidate)
        assertEquals(draft, r.editor.state.value.source)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
    }

    @Test fun anAcceptanceWaitingOnIOCannotUseRecoveredAccess() = runTest {
        val r = Rig(this, Role.EDITOR)
        r.configure()
        r.ready()
        r.io.held = true
        r.improve.accept(); runCurrent()
        r.role(Role.VIEWER); r.role(Role.EDITOR)
        r.io.releaseAll(); runCurrent()
        assertNull(r.improve.state.value.acceptanceOutcome?.committed)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
    }

    @Test fun viewerReviewRemainsReadOnlyAndPrivateImproveSendsNothing() = runTest {
        val viewer = Rig(this, Role.VIEWER)
        viewer.configure()
        viewer.review.open(); runCurrent(); viewer.review.review(); runCurrent()
        assertEquals(ReviewUnavailable.READ_ONLY, viewer.review.state.value.unavailable)
        assertEquals(0, viewer.calls)
        val private = Rig(this, Role.VIEWER)
        private.configure(original.replace("title: Shared", "title: Shared\nprivate: true"))
        private.improve.open(); runCurrent(); private.improve.improve(); runCurrent()
        assertFalse(private.improve.state.value.canImprove)
        assertEquals(0, private.calls)
    }

    @Test fun unavailableGroupsRefuseImproveAndKeepTheDraft() = runTest {
        val r = Rig(this, Role.EDITOR)
        r.configure()
        val draft = original + "Unsaved"
        r.editor.edit(draft); runCurrent()
        r.removeGroup(); r.repository.publishProjection(); runCurrent()
        r.improve.open(); runCurrent(); r.improve.improve(); runCurrent()
        assertFalse(r.improve.state.value.canImprove)
        assertEquals(0, r.calls)
        assertEquals(draft, r.editor.state.value.source)
    }

    @Test fun recordedIdentityStillControlsAccessAtAPersonalPath() = runTest {
        val r = Rig(this, Role.VIEWER)
        r.configure()
        assertEquals(AssistantAccessState.GROUP_VIEWER, r.authority.current("personal.md", r.identity))
        assertEquals(AssistantAccessState.PRIVATE_PROMPT, r.authority.current("personal.md", PromptIdentity.at("personal.md")))
        r.removeGroup()
        assertEquals(AssistantAccessState.UNAVAILABLE, r.authority.current("personal.md", r.identity))
    }

    @Test fun closingDuringPermitCaptureCannotPublishOrKeepTheEditorBusy() = runTest {
        val r = Rig(this, Role.EDITOR)
        r.configure()
        r.ready()
        r.io.held = true
        r.improve.accept(); runCurrent()
        r.improve.close(); runCurrent()
        r.io.releaseAll(); runCurrent()
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        r.ready()
        r.improve.accept(); runCurrent()
        assertNotNull(r.improve.state.value.acceptanceOutcome?.committed)
    }

    @Test fun aQueuedEditorDecisionRetainsThePermitCapturedBeforeItsWait() = runTest {
        val r = Rig(this, Role.EDITOR)
        r.configure()
        val draft = original + "Unsaved"
        r.editor.edit(draft); runCurrent()
        r.write.open(); runCurrent(); r.write.editBrief("Write another prompt"); r.write.write(); runCurrent()
        assertEquals(AssistantPhase.READY, r.write.state.value.assistant?.phase)
        r.io.held = true
        r.write.accept(); runCurrent()
        assertNull(r.editor.state.value.pendingDecision)
        r.io.releaseAll(); runCurrent()
        val decision = assertNotNull(r.editor.state.value.pendingDecision)
        r.role(Role.VIEWER); r.role(Role.EDITOR)
        r.editor.resolveDecision(decision.id, EditorDecision.DISCARD); runCurrent()
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertEquals(draft, r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertEquals(1, r.prompts.listFiles().size)
    }
}
