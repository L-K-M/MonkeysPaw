@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.ui.conflicts

import androidx.datastore.core.DataStoreFactory
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AppModule
import ch.lkmc.monkeyspaw.ui.editor.*
import ch.lkmc.monkeyspaw.ui.library.*
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.*

internal class ResolveViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val rigs = mutableListOf<Rig>()
    private val clock = Clock { Instant.parse(time) }

    @BeforeTest fun main() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun close() {
        models.clear()
        rigs.forEach { it.scope.cancel() }
        dispatcher.scheduler.runCurrent()
        Dispatchers.resetMain()
    }

    private inner class Rig(val group: Boolean = false, val rescued: Boolean = false) {
        val number = rigs.size
        val root = temporary.resolve("rig-$number")
        val libraryRoot = root.resolve("library")
        val dataRoot = root.resolve("state")
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val io = JvmCheckedSyncIO()
        val prompts = AndroidPromptStore(libraryRoot.toFile(), io = io)
        val files = AndroidStateStore(dataRoot.toFile(), isMainThread = { false }, io = io)
        val library = library(files, prompts)
        val startup = AndroidSyncStartup(library, prompts, files, libraryRoot.toString(), dispatcher)
        val local = LibraryRepository(library, EditingService(library), prompts, dispatcher) { startup.ready() }
        val settings = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
            produceFile = { root.resolve("settings.json").toFile() }))
        val requests = mutableListOf<HttpRequest>()
        val remote = linkedMapOf<String, Prompt>()
        var role = Role.EDITOR
        var handler: (suspend (HttpRequest) -> HttpResponse?)? = null
        private val transport = HttpTransport { request ->
            requests.add(request)
            handler?.invoke(request) ?: when {
                request.url.endsWith("/me") -> HttpResponse(200, body = MeResponse.codec.encode(MeResponse(
                    User(userID, "person", null, AccountKind.MEMBER, time, null),
                    if (group) listOf(GroupMembership(groupID, "Team", role)) else emptyList(), emptyList())))
                request.url.endsWith("/sync/pull") -> {
                    fun scope(identity: ScopeIdentity, wire: PromptScope) = SyncScope(identity, Mode.SNAPSHOT, 10, "after", false,
                        remote.values.filter { it.scope == wire }.sortedBy { it.id }
                            .map { FeedItem.Upsert(10, FeedPrompt(it.id, it.rev, it.path, it.content)) })
                    HttpResponse(200, body = PullResponse.codec.encode(PullResponse(databaseID,
                        listOf(scope(ScopeIdentity.User(userID), PromptScope.User)) +
                            if (group) listOf(scope(ScopeIdentity.Group(groupID, "Team", role), PromptScope.Group(groupID))) else emptyList(),
                        emptyList())))
                }
                request.method == HttpMethod.GET -> remote[request.url.substringAfterLast('/')]?.let {
                    HttpResponse(200, body = Prompt.codec.encode(it))
                } ?: errorResponse(404, FailureCode.NOT_FOUND)
                request.method == HttpMethod.PUT -> {
                    val id = request.url.substringAfterLast('/')
                    val put = PutPromptRequest.codec.decode(request.body!!)
                    val old = remote[id]
                    if (old != null && old.rev != put.baseRev) HttpResponse(409, body = ErrorResponse.codec.encode(ErrorResponse.Conflict(
                        ConflictHead(old.rev, old.scope, old.path, old.content)))) else {
                        val rev = (old?.rev ?: 0) + 1
                        remote[id] = Prompt(id, rev, put.scope, put.path, put.content)
                        HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(rev, 10)))
                    }
                }
                request.method == HttpMethod.DELETE -> {
                    val old = remote.remove(request.url.substringAfterLast('/').substringBefore('?'))
                    HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse((old?.rev ?: 0) + 1, 10)))
                }
                else -> error("Unexpected synthetic request")
            }
        }
        private val secrets = object : SecretStore {
            override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? = null
            override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier = SecretTier.KEYSTORE
            override suspend fun delete(account: SecretAccount) {}
        }
        private var draw = 0
        val mono = MonotonicClock { dispatcher.scheduler.currentTime * 1_000_000 }
        val sync = AppModule.syncRepository(startup, library, local, scope, dispatcher, clock,
            Entropy { count -> ByteArray(count) { (draw++).toByte() } }, mono, Lazy { secrets }, Lazy { transport }, settings)
        val model = ResolveViewModel(sync).also { models.put("resolver-$number", it) }
        val editor = EditorViewModel(local, dispatcher, clock, scope).also { models.put("editor-$number", it) }
        val browser = LibraryViewModel(local, dispatcher).also { models.put("browser-$number", it) }
        val binding = SyncLibraryIdentity(SyncAccountIdentity(server, id(userID)), SyncLibraryRoot(libraryRoot.toString()))
        val copyPath = "Elsewhere/renamed.md"
        val originalPath = if (group) "Groups/Team/original.md" else "original.md"
        private val originalScope = if (group) SyncScopeKey.Group(id(groupID)) else SyncScopeKey.User(id(userID))
        val serverBytes = source("Server Café\n{{old}}\n", originalID).let {
            if (group) CanonicalForm.group(it, "original.md").bytes else it
        }
        val copyBytes = source("Mine Cafe\u0301 🐒\r\n{{new}}", copyID,
            "favorite: true\r\nprivate: true\r\n" + if (rescued) "x-monkeyspaw-rescued: true\r\n"
            else "x-monkeyspaw-conflict-of: '$originalID'\r\n")
        val selection = LibrarySelection(PromptIdentity.Assigned(id(copyID)), copyPath)
        lateinit var graph: AndroidSyncRepository.Graph

        suspend fun start() {
            graph = sync.graph()
            put(libraryRoot.resolve(originalPath), serverBytes)
            put(libraryRoot.resolve(copyPath), copyBytes)
            graph.local.accounts.setAccount(SyncAccount(binding.account, "person", id(userID), "Android", UUID.randomUUID()))
            graph.local.accounts.updateBinding(binding.root) { SyncLibraryBinding(binding.root, binding.account,
                if (group) mapOf(id(groupID) to SyncManagedFolder(binding.account, "Team")) else emptyMap()) }
            graph.local.states.update(binding) { SyncState(binding, UUID.fromString(databaseID),
                mapOf(SyncScopeKey.User(id(userID)) to "before"),
                if (group) mapOf(id(groupID) to SyncGroupState("Team", "Team", role)) else emptyMap(),
                mapOf(PromptIdentity.Assigned(id(originalID)) to SyncPromptState(originalScope, "original.md", 1, SyncHash.of(serverBytes)),
                    selection.identity to SyncPromptState(SyncScopeKey.User(id(userID)), copyPath, 1, SyncHash.of(copyBytes),
                        if (rescued) SyncPromptOrigin.Rescued else SyncPromptOrigin.ConflictOf(id(originalID))))) }
            remote[originalID] = Prompt(originalID, 1, if (group) PromptScope.Group(groupID) else PromptScope.User, "original.md", serverBytes.decodeToString())
            remote[copyID] = Prompt(copyID, 1, PromptScope.User, copyPath, copyBytes.decodeToString())
            val url = SyncServerURL(server)
            graph.engine.start(binding, SyncHTTPClient(url, transport, SyncCredential(url, SecretValue("A".repeat(43))), mono), "Android")
        }

        fun open() = model.open(selection)
        fun choose(action: SyncResolutionAction, preview: UUID = checkNotNull(model.state.value.previewID)) = model.choose(action, preview)
        fun bytes(path: String = copyPath) = Files.readAllBytes(libraryRoot.resolve(path))
        val originalPuts get() = requests.filter { it.method == HttpMethod.PUT && it.url.endsWith("/$originalID") }
        fun head(body: String = "New server", rev: Long = 2) {
            val old = remote.getValue(originalID)
            remote[originalID] = Prompt(originalID, rev, old.scope, old.path, source(body, originalID).decodeToString())
        }
    }

    private fun rig(group: Boolean = false, rescued: Boolean = false) = Rig(group, rescued).also { rigs.add(it) }

    @Test fun `model construction and opening comparison never resolve automatically`() = runTest(dispatcher) {
        val r = rig()
        runCurrent()
        assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
        assertNull(r.sync.reports.value)
        assertTrue(r.requests.isEmpty())
        r.start(); r.open(); runCurrent()
        assertEquals(ResolveStatus.READY, r.model.state.value.status)
        assertContentEquals(r.copyBytes, r.bytes())
        assertContentEquals(r.serverBytes, r.bytes(r.originalPath))
        assertTrue(r.requests.all { it.method == HttpMethod.GET })
    }

    @Test fun `Keep server retires only checked copy and propagates its personal deletion`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val preview = r.model.state.value.previewID!!
        r.choose(SyncResolutionAction.KEEP_SERVER); r.choose(SyncResolutionAction.KEEP_SERVER, preview); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_SERVER, r.model.state.value.resolvedAction)
        assertNull(r.model.state.value.diff)
        assertFalse(Files.exists(r.libraryRoot.resolve(r.copyPath)))
        assertContentEquals(r.serverBytes, r.bytes(r.originalPath))
        assertNull(r.sync.runBackground().blockingIssue); runCurrent()
        assertFalse(copyID in r.remote)
        assertTrue(originalID in r.remote)
        assertTrue(r.originalPuts.isEmpty())
    }

    @Test fun `Keep mine publishes the exact compared bytes with original ID and history`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val diff = assertNotNull(r.model.state.value.diff)
        assertContentEquals(r.serverBytes, projection(diff.frontMatter + diff.body, LineDiffLine.Kind.ADDED))
        val candidate = projection(diff.frontMatter + diff.body, LineDiffLine.Kind.REMOVED)
        assertTrue(diff.frontMatter.isNotEmpty()); assertTrue(diff.body.isNotEmpty())
        assertTrue(diff.frontMatter.any { it.text.endsWith("\r\n") })
        assertTrue(diff.body.any { it.text.contains("Cafe\u0301 🐒\r\n") })
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_MINE, r.model.state.value.resolvedAction)
        assertFalse(Files.exists(r.libraryRoot.resolve(r.copyPath)))
        assertContentEquals(candidate, r.bytes(r.originalPath))
        assertContentEquals(candidate, PutPromptRequest.codec.decode(r.originalPuts.single().body!!).content.encodeToByteArray())
        assertEquals(originalID, PromptCodec.parseFile(candidate, "original.md").frontMatter.id?.rawValue)
        assertEquals("Mine Cafe\u0301 🐒\r\n{{new}}", PromptCodec.parseFile(candidate, "original.md").body)
        val history = r.library.history.revisions(PromptIdentity.Assigned(id(originalID)))
        assertEquals(1, history.size)
        assertContentEquals(r.serverBytes, r.library.history.read(history.single()))
    }

    @Test fun `Keep both preserves private identity body and metadata and propagates marker removal`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        r.choose(SyncResolutionAction.KEEP_BOTH); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_BOTH, r.model.state.value.resolvedAction)
        val document = PromptCodec.parseFile(r.bytes(), "renamed.md")
        assertEquals(copyID, document.frontMatter.id?.rawValue)
        assertEquals("Mine Cafe\u0301 🐒\r\n{{new}}", document.body)
        assertTrue(document.frontMatter.favorite); assertTrue(document.frontMatter.isPrivate)
        assertNull(SyncConflictMetadata.origin(r.bytes(), "renamed.md"))
        assertContentEquals(r.serverBytes, r.bytes(r.originalPath))
        assertNull(r.sync.runBackground().blockingIssue); runCurrent()
        assertNull(SyncConflictMetadata.origin(r.remote.getValue(copyID).content.encodeToByteArray(), "renamed.md"))
        assertTrue(r.originalPuts.isEmpty())
        assertEquals(ResolveStatus.RESOLVED, r.model.state.value.status)
    }

    @Test fun `shared Keep mine sends the exact group candidate without personal metadata`() = runTest(dispatcher) {
        val r = rig(group = true); r.start(); r.open(); runCurrent()
        assertTrue(r.model.state.value.canKeepMine)
        val diff = assertNotNull(r.model.state.value.diff)
        val candidate = projection(diff.frontMatter + diff.body, LineDiffLine.Kind.REMOVED)
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_MINE, r.model.state.value.resolvedAction)
        assertContentEquals(candidate, r.bytes(r.originalPath))
        assertContentEquals(candidate, PutPromptRequest.codec.decode(r.originalPuts.single().body!!).content.encodeToByteArray())
        val document = PromptCodec.parseFile(candidate, "original.md")
        assertFalse(document.frontMatter.favorite); assertFalse(document.frontMatter.isPrivate)
        assertFalse(candidate.decodeToString().contains("favorite:")); assertFalse(candidate.decodeToString().contains("private:"))
        assertEquals(originalID, document.frontMatter.id?.rawValue)
        assertNull(SyncConflictMetadata.origin(candidate, "original.md"))
    }

    @Test fun `changed head returns Refreshed and old rendered taps cannot accept its replacement`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val old = r.model.state.value.previewID!!
        r.head()
        r.choose(SyncResolutionAction.KEEP_MINE, old); runCurrent()
        assertEquals(ResolveNotice.REFRESHED, r.model.state.value.notice)
        val next = r.model.state.value.previewID!!
        assertNotEquals(old, next)
        assertTrue(r.originalPuts.isEmpty())
        assertContentEquals(r.copyBytes, r.bytes())
        r.choose(SyncResolutionAction.KEEP_MINE, old); r.choose(SyncResolutionAction.KEEP_BOTH, old); runCurrent()
        assertEquals(next, r.model.state.value.previewID)
        assertTrue(r.originalPuts.isEmpty())
        r.choose(SyncResolutionAction.KEEP_MINE, next); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_MINE, r.model.state.value.resolvedAction)
        assertEquals(2L, PutPromptRequest.codec.decode(r.originalPuts.single().body!!).baseRev)
    }

    @Test fun `absent and inaccessible remote original retain copy and allow explicit Keep both`() = runTest(dispatcher) {
        for ((status, code, refusal) in listOf(Triple(404, FailureCode.NOT_FOUND, ResolveFailure.ORIGINAL_UNAVAILABLE),
            Triple(410, FailureCode.NOT_FOUND, ResolveFailure.ORIGINAL_UNAVAILABLE), Triple(403, FailureCode.FORBIDDEN, ResolveFailure.ACCESS_DENIED))) {
            val r = rig(); r.start()
            r.handler = { if (it.method == HttpMethod.GET && it.url.endsWith("/$originalID")) errorResponse(status, code) else null }
            r.open(); runCurrent()
            assertEquals(refusal, r.model.state.value.mineRefusal)
            assertFalse(r.model.state.value.canKeepMine); assertFalse(r.model.state.value.canKeepServer)
            assertTrue(r.model.state.value.canKeepBoth)
            r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
            assertContentEquals(r.copyBytes, r.bytes())
            r.choose(SyncResolutionAction.KEEP_BOTH); runCurrent()
            assertEquals(SyncResolutionAction.KEEP_BOTH, r.model.state.value.resolvedAction)
            assertTrue(r.originalPuts.isEmpty())
        }
    }

    @Test fun `viewer original refuses Keep mine while private Keep both remains usable`() = runTest(dispatcher) {
        val r = rig(group = true); r.start()
        r.role = Role.VIEWER
        r.graph.local.states.update(r.binding) { it.copy(groups = mapOf(id(groupID) to SyncGroupState("Team", "Team", Role.VIEWER))) }
        r.open(); runCurrent()
        assertEquals(ResolveFailure.ACCESS_DENIED, r.model.state.value.mineRefusal)
        assertFalse(r.model.state.value.canKeepMine)
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertTrue(r.originalPuts.isEmpty()); assertContentEquals(r.copyBytes, r.bytes())
        r.choose(SyncResolutionAction.KEEP_BOTH); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_BOTH, r.model.state.value.resolvedAction)
        assertContentEquals(r.serverBytes, r.bytes(r.originalPath))
    }

    @Test fun `missing local original is installed only after explicit Keep mine`() = runTest(dispatcher) {
        val r = rig(); r.start()
        Files.delete(r.libraryRoot.resolve(r.originalPath))
        r.open(); runCurrent()
        assertTrue(r.model.state.value.canKeepMine)
        assertFalse(Files.exists(r.libraryRoot.resolve(r.originalPath)))
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_MINE, r.model.state.value.resolvedAction)
        assertEquals("Mine Cafe\u0301 🐒\r\n{{new}}", PromptCodec.parseFile(r.bytes(r.originalPath), "original.md").body)
    }

    @Test fun `rescue preview and Keep both need no original or HTTP`() = runTest(dispatcher) {
        val r = rig(rescued = true); r.start(); r.open(); runCurrent()
        assertEquals(ResolveFailure.ORIGINAL_UNAVAILABLE, r.model.state.value.mineRefusal)
        assertNull(r.model.state.value.diff)
        assertTrue(r.requests.isEmpty())
        r.choose(SyncResolutionAction.KEEP_BOTH); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_BOTH, r.model.state.value.resolvedAction)
        assertTrue(r.requests.isEmpty())
        assertNull(SyncConflictMetadata.origin(r.bytes(), "renamed.md"))
    }

    @Test fun `busy actions ignore duplicate taps and navigation can stay without canceling work`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val release = CompletableDeferred<Unit>()
        r.handler = { if (it.method == HttpMethod.GET) release.await(); null }
        val token = r.model.state.value.previewID!!
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertTrue(r.model.state.value.busy)
        r.choose(SyncResolutionAction.KEEP_SERVER, token); r.model.refresh()
        var left = false
        r.model.requestClose { left = true }
        assertTrue(r.model.state.value.closePending); assertFalse(left)
        r.model.dismissClose()
        assertFalse(r.model.state.value.closePending)
        release.complete(Unit); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_MINE, r.model.state.value.resolvedAction)
        assertEquals(1, r.originalPuts.size)
        assertFalse(left)
        r.model.requestClose { left = true }
        assertTrue(left); assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
    }

    @Test fun `confirmed departure cancels session before a late HTTP reply can retire copy`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val release = CompletableDeferred<Unit>()
        r.handler = { if (it.method == HttpMethod.GET) withContext(NonCancellable) { release.await() }; null }
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        var left = false
        r.model.requestClose { left = true }; r.model.confirmClose()
        assertTrue(left); assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
        release.complete(Unit); runCurrent()
        assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
        assertContentEquals(r.copyBytes, r.bytes())
        assertContentEquals(r.serverBytes, r.bytes(r.originalPath))
        assertTrue(r.originalPuts.isEmpty())
    }

    @Test fun `canceling load clears comparison and late result requires explicit refresh`() = runTest(dispatcher) {
        val r = rig(); r.start()
        val release = CompletableDeferred<Unit>()
        r.handler = { if (it.method == HttpMethod.GET) withContext(NonCancellable) { release.await() }; null }
        r.open(); runCurrent(); r.model.cancel()
        assertEquals(ResolveNotice.CANCELLED, r.model.state.value.notice)
        assertNull(r.model.state.value.previewID); assertNull(r.model.state.value.diff)
        release.complete(Unit); runCurrent()
        assertEquals(ResolveNotice.CANCELLED, r.model.state.value.notice)
        assertContentEquals(r.copyBytes, r.bytes())
        r.handler = null; r.model.refresh(); runCurrent()
        assertEquals(ResolveStatus.READY, r.model.state.value.status)
        assertNull(r.model.state.value.notice)
        assertTrue(r.originalPuts.isEmpty())
    }

    @Test fun `canceled sent Keep mine completes only after a fresh explicit choice without another PUT`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val release = CompletableDeferred<Unit>()
        r.handler = { request ->
            if (request.method == HttpMethod.PUT && request.url.endsWith("/$originalID")) {
                val put = PutPromptRequest.codec.decode(request.body!!)
                r.remote[originalID] = Prompt(originalID, 2, put.scope, put.path, put.content)
                withContext(NonCancellable) { release.await() }
                HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(2, 10)))
            } else null
        }
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertEquals(1, r.originalPuts.size)
        r.model.cancel(); release.complete(Unit); runCurrent()
        assertEquals(ResolveNotice.CANCELLED, r.model.state.value.notice)
        assertContentEquals(r.copyBytes, r.bytes())
        assertContentEquals(r.serverBytes, r.bytes(r.originalPath))
        r.handler = null
        r.model.refresh(); runCurrent()
        assertEquals(ResolveStatus.READY, r.model.state.value.status)
        assertEquals(1, r.originalPuts.size)
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertEquals(SyncResolutionAction.KEEP_MINE, r.model.state.value.resolvedAction)
        assertEquals(1, r.originalPuts.size)
        assertFalse(Files.exists(r.libraryRoot.resolve(r.copyPath)))
    }

    @Test fun `changed copy refuses old choice with typed failure and keeps fresh bytes`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val edited = r.copyBytes + "\nExternal".encodeToByteArray()
        put(r.libraryRoot.resolve(r.copyPath), edited)
        r.choose(SyncResolutionAction.KEEP_SERVER); runCurrent()
        assertEquals(ResolveFailure.STALE_COPY, r.model.state.value.failure)
        assertFalse(r.model.state.value.canChoose); assertNull(r.model.state.value.diff)
        assertContentEquals(edited, r.bytes()); assertTrue(r.originalPuts.isEmpty())
        r.model.refresh(); runCurrent()
        assertEquals(ResolveStatus.READY, r.model.state.value.status)
    }

    @Test fun `dirty original is refused without silently sending the editor or disk draft`() = runTest(dispatcher) {
        val r = rig(); r.start()
        val changed = source("Unsaved externally", originalID)
        put(r.libraryRoot.resolve(r.originalPath), changed)
        r.open(); runCurrent()
        assertEquals(ResolveFailure.STALE_COPY, r.model.state.value.mineRefusal)
        r.choose(SyncResolutionAction.KEEP_MINE); runCurrent()
        assertContentEquals(changed, r.bytes(r.originalPath)); assertTrue(r.originalPuts.isEmpty())
    }

    @Test fun `typed sign-in offline and recovery failures carry no raw diagnostics`() = runTest(dispatcher) {
        for (failure in listOf(ResolveFailure.NEEDS_SIGN_IN, ResolveFailure.OFFLINE, ResolveFailure.RECOVERY_REQUIRED)) {
            val r = rig(); r.start()
            if (failure != ResolveFailure.RECOVERY_REQUIRED) r.handler = {
                if (it.method == HttpMethod.GET) {
                    if (failure == ResolveFailure.NEEDS_SIGN_IN) errorResponse(401, FailureCode.UNAUTHORIZED)
                    else throw HttpTransportError.NetworkFailure
                } else null
            }
            r.open(); runCurrent()
            if (failure == ResolveFailure.RECOVERY_REQUIRED) {
                r.io.onFlush = { if (it.fileName.toString() == "apply.json") throw java.io.IOException("Sensitive sentinel") }
                r.choose(SyncResolutionAction.KEEP_BOTH); runCurrent()
            }
            assertEquals(failure, r.model.state.value.failure)
            assertNull(r.model.state.value.diff); assertNull(r.model.state.value.previewID)
            assertFalse(r.model.state.value.canChoose)
            assertContentEquals(r.copyBytes, r.bytes())
            assertEquals("<conflict resolution state>", r.model.state.value.toString())
            assertTrue(r.originalPuts.isEmpty())
            r.io.onFlush = {}
        }
    }

    @Test fun `cleared model revokes preview and rejects old callbacks`() = runTest(dispatcher) {
        val r = rig(); r.start(); r.open(); runCurrent()
        val token = r.model.state.value.previewID!!
        models.clear()
        r.model.choose(SyncResolutionAction.KEEP_BOTH, token); r.open(); runCurrent()
        assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
        assertContentEquals(r.copyBytes, r.bytes())
    }

    @Test fun `Library conflict filter uses Z24 origin projection after a rename and clears after resolution`() = runTest(dispatcher) {
        val r = rig(); r.start()
        put(r.libraryRoot.resolve("Conflicts/name (conflict device).md"), "Ordinary".encodeToByteArray())
        r.local.refresh(); runCurrent()
        r.browser.setFilter(LibraryFilter.Conflicts); runCurrent()
        assertEquals(listOf(r.copyPath), r.browser.state.value.rows.map { it.selection.relativePath })
        r.open(); runCurrent(); r.choose(SyncResolutionAction.KEEP_BOTH); runCurrent()
        r.local.refresh(); runCurrent()
        assertTrue(r.browser.state.value.rows.isEmpty())
        assertEquals(0, r.browser.state.value.sections.single { it.filter == LibraryFilter.Conflicts }.count)
    }

    @Test fun `resolve navigation waits for editor Save Discard or Cancel`() = runTest(dispatcher) {
        for (decision in EditorDecision.entries) {
            val r = rig(); r.start()
            r.editor.open(r.selection); runCurrent()
            r.editor.edit(r.editor.state.value.source + "\nDraft"); runCurrent()
            r.editor.closeThen { r.open() }; runCurrent()
            assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
            assertTrue(r.requests.isEmpty())
            val pending = assertNotNull(r.editor.state.value.pendingDecision)
            r.editor.resolveDecision(pending.id, decision); runCurrent()
            if (decision == EditorDecision.CANCEL) {
                assertTrue(r.editor.state.value.dirty)
                assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
                assertContentEquals(r.copyBytes, r.bytes())
            } else {
                assertFalse(r.editor.state.value.isOpen)
                assertEquals(ResolveStatus.READY, r.model.state.value.status)
                assertEquals(decision == EditorDecision.SAVE, r.bytes().decodeToString().endsWith("\nDraft"))
                assertTrue(r.originalPuts.isEmpty())
            }
        }
    }

    @Test fun `activity departure withdraws pending editor navigation without discarding the draft`() = runTest(dispatcher) {
        val r = rig(); r.start()
        r.editor.open(r.selection); runCurrent()
        r.editor.edit(r.editor.state.value.source + "\nDraft"); runCurrent()
        r.editor.closeThen { r.open() }
        val request = assertNotNull(r.editor.state.value.pendingDecision)
        r.editor.cancelCloseThen()
        r.editor.resolveDecision(request.id, EditorDecision.DISCARD); runCurrent()
        assertNull(r.editor.state.value.pendingDecision)
        assertTrue(r.editor.state.value.dirty)
        assertTrue(r.editor.state.value.isOpen)
        assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
        assertTrue(r.requests.isEmpty())
    }

    @Test fun `editor navigation waits behind a write and cancellation leaves the authorized save intact`() = runTest(dispatcher) {
        val r = rig(); r.start()
        r.editor.open(r.selection); runCurrent()
        r.editor.edit(r.editor.state.value.source + "\nSaved"); runCurrent()
        r.editor.save()
        assertTrue(r.editor.state.value.writing)
        r.editor.closeThen { r.open() }
        r.editor.cancelCloseThen(); runCurrent()
        assertTrue(r.editor.state.value.isOpen)
        assertFalse(r.editor.state.value.dirty)
        assertTrue(r.bytes().decodeToString().endsWith("\nSaved"))
        assertEquals(ResolveStatus.CLOSED, r.model.state.value.status)
        assertTrue(r.requests.isEmpty())
    }

    private fun projection(lines: List<LineDiffLine>, excluding: LineDiffLine.Kind) =
        lines.filter { it.kind != excluding }.flatMap { it.bytes.asIterable() }.toByteArray()

    private fun source(body: String, id: String, extra: String = "") =
        "---\r\nid: '$id'\r\ntitle: Prompt\r\n# exact header\r\n${extra}---\r\n$body".encodeToByteArray()

    private fun errorResponse(status: Int, code: FailureCode) =
        HttpResponse(status, body = ErrorResponse.codec.encode(if (status == 410) ErrorResponse.Deleted else ErrorResponse.Failure(code)))

    private fun id(raw: String) = checkNotNull(ULID.parse(raw))

    private companion object {
        const val server = "https://example.test/paw"
        const val time = "2026-10-14T00:00:00.000Z"
        const val userID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        const val originalID = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
        const val copyID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        const val groupID = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        const val databaseID = "11111111-1111-4111-8111-111111111111"
    }
}
