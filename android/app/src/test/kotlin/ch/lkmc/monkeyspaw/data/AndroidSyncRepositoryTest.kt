@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.di.AppModule
import androidx.datastore.core.DataStoreFactory
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.util.concurrent.Executors
import kotlin.test.*

internal class AndroidSyncRepositoryTest : TemporaryFiles() {
    private class Secrets : SecretStore {
        val values = mutableMapOf<SecretAccount, StoredSecret>()
        var reads = 0
        override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? {
            reads++
            return values[account]
        }
        override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
            values[account] = StoredSecret(value, SecretTier.KEYSTORE)
            return SecretTier.KEYSTORE
        }
        override suspend fun delete(account: SecretAccount) { values.remove(account) }
    }

    private inner class Rig(val dispatcher: CoroutineDispatcher, val secrets: Secrets = Secrets(),
                            mono: MonotonicClock = MonotonicClock(System::nanoTime), val scheduled: Boolean = false) {
        val backgroundErrors = mutableListOf<Throwable>()
        val scope = CoroutineScope(SupervisorJob() + dispatcher + CoroutineExceptionHandler { _, error -> backgroundErrors.add(error) })
        val checked = JvmCheckedSyncIO()
        val prompts = AndroidPromptStore(libraryDir.toFile(), io = checked)
        val files = AndroidStateStore(stateDir.toFile(), isMainThread = { false }, io = checked)
        var beforeList: () -> Unit = {}
        val library = library(files, object : PromptStore by prompts {
            override fun listFiles(): List<StoredFile> { beforeList(); return prompts.listFiles() }
        })
        val startup = AndroidSyncStartup(library, prompts, files, libraryDir.toFile().absolutePath, dispatcher)
        val repository = LibraryRepository(library, EditingService(library), prompts, dispatcher) { startup.ready() }
        val settings = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
            produceFile = { filesDir.resolve("datastore/settings.json").toFile() }))
        val requests = mutableListOf<HttpRequest>()
        var respond: (suspend (HttpRequest) -> HttpResponse?)? = null
        val remote = linkedMapOf<String, Prompt>()
        var groupRole: Role? = null
        var sequence = 1L
        var secretConstructions = 0
        var transportConstructions = 0
        var schedulerConstructions = 0
        var workTime = Instant.parse(timestamp).toEpochMilli()
        val requestsForWork = mutableListOf<SyncWorkRequest>()
        val periodicWork = linkedMapOf<String, Long>()
        val canceledWork = mutableListOf<String>()
        var beforeWorkEnqueue: suspend () -> Unit = {}
        val workStore = SyncWorkStateStore(files, files.syncOperations)
        val scheduler: SyncWorkScheduler by lazy {
            schedulerConstructions++
            SyncWorkScheduler(SyncWorkPolicy(workStore, object : SyncWorkQueue {
                override suspend fun periodic(generation: String, intervalMillis: Long) { periodicWork[generation] = intervalMillis }
                override suspend fun once(request: SyncWorkRequest) { beforeWorkEnqueue(); requestsForWork.add(request) }
                override suspend fun cancel(generation: String) { canceledWork.add(generation); periodicWork.remove(generation) }
            }, AndroidSyncWorkSession(startup, Lazy { sync }), { workTime }, 31), dispatcher)
        }
        val hooks = object : SyncWorkHooks {
            override suspend fun authenticationStopped() = scheduled && scheduler.authenticationStopped()
            override suspend fun authenticated(connection: String) { if (scheduled) scheduler.authenticated(connection) }
            override suspend fun signedOut() { if (scheduled) scheduler.signedOut() }
            override suspend fun saved() { if (scheduled) scheduler.saved() }
            override suspend fun changed() { if (scheduled) scheduler.changed() }
        }
        val transport = HttpTransport { request ->
            requests.add(request)
            respond?.invoke(request) ?: when {
                request.url.endsWith("/auth/login") -> HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse("A".repeat(43), user())))
                request.url.endsWith("/me") -> HttpResponse(200, body = MeResponse.codec.encode(MeResponse(user(), emptyList(),
                    listOf(Device(deviceID, "Android", timestamp, null, null, true)))))
                request.url.endsWith("/auth/logout") -> HttpResponse(200, body = EmptyResponse.codec.encode(EmptyResponse))
                request.url.endsWith("/sync/pull") -> pull()
                request.method == HttpMethod.PUT -> {
                    val put = PutPromptRequest.codec.decode(request.body!!)
                    val id = request.url.substringAfterLast('/')
                    val rev = (remote[id]?.rev ?: 0) + 1
                    remote[id] = Prompt(id, rev, put.scope, put.path, put.content)
                    HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(rev, ++sequence)))
                }
                else -> error("Unexpected test request")
            }
        }
        val sync = AppModule.syncRepository(startup, library, repository, scope, dispatcher,
            Clock { Instant.ofEpochMilli(workTime) }, Entropy { ByteArray(it) { index -> index.toByte() } }, mono,
            Lazy { secretConstructions++; secrets }, Lazy { transportConstructions++; transport }, settings, hooks)

        private fun user() = User(userID, "person", null, AccountKind.MEMBER, timestamp, null)
        private fun pull(): HttpResponse {
            fun items(scope: PromptScope) = remote.values.filter { it.scope == scope }.sortedBy { it.id }.map { p ->
                FeedItem.Upsert(sequence, FeedPrompt(p.id, p.rev, p.path, p.content))
            }
            val scopes = listOf(SyncScope(ScopeIdentity.User(userID), Mode.SNAPSHOT, sequence, "u-$sequence", false, items(PromptScope.User))) +
                groupRole?.let { listOf(SyncScope(ScopeIdentity.Group(groupID, "Team", it), Mode.SNAPSHOT,
                    sequence, "g-$sequence", false, items(PromptScope.Group(groupID)))) }.orEmpty()
            return HttpResponse(200, body = PullResponse.codec.encode(PullResponse(databaseID, scopes, emptyList())))
        }
        suspend fun login() = sync.login("https://example.test/paw", "person", SecretValue("Synthetic-password-123"), "Android")
        fun remote(path: String = "remote.md", rev: Long = 1, group: Boolean = false) {
            val content = "---\nid: '$promptID'\ntitle: Remote\n---\nbody".encodeToByteArray()
            remote[promptID] = Prompt(promptID, rev, if (group) PromptScope.Group(groupID) else PromptScope.User,
                path, (if (group) ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm.group(content, path.substringAfterLast('/')).bytes
                    else content).decodeToString())
            sequence = maxOf(sequence, rev)
        }
        suspend fun close() { scope.cancel(); scope.coroutineContext[Job]!!.join() }
    }

    @Test fun `local startup delivery reads and flow observation never construct authenticated dependencies`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            assertNull(r.sync.reports.value)
            assertNull(r.sync.accounts.value)
            r.repository.refresh()
            r.repository.withLibrary { library, _ -> assertTrue(library.entries().isEmpty()) }
            runCurrent()
            assertEquals(0, r.secretConstructions)
            assertEquals(0, r.transportConstructions)
            assertEquals(0, r.secrets.reads)
            assertTrue(r.requests.isEmpty())
        } finally { r.close() }
    }

    @Test fun `concurrent UI and worker obtain one graph with the local stores and IO providers`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val caller = Thread.currentThread()
            val r = Rig(worker)
            try {
                r.beforeList = { assertNotEquals(caller, Thread.currentThread()) }
                r.respond = { assertNotEquals(caller, Thread.currentThread()); null }
                val graphs = coroutineScope { (1..12).map { async { r.sync.graph() } }.awaitAll() }
                graphs.forEach { assertSame(graphs.first(), it) }
                val graph = graphs.first()
                assertSame(r.startup.ready(), graph.local)
                assertSame(graph.local.states, graph.engine.graph.states)
                assertSame(graph.local.accounts, graph.engine.graph.accounts)
                assertSame(r.files, graph.engine.graph.files)
                assertSame(r.files, AppModule.stateStore(r.files))
                assertSame(r.library, r.repository.withLibrary { library, _ -> library })
                r.login()
                assertEquals(1, r.secretConstructions)
                assertEquals(1, r.transportConstructions)
                assertEquals(2, r.requests.size)
            } finally { r.close() }
        }
    }

    @Test fun `established missing root is not recreated by reconstructed local launch`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher)
        r.login()
        r.close()
        Files.move(libraryDir, filesDir.resolve("lost-library"))
        val reopened = Rig(dispatcher)
        try {
            assertSame(LibraryError.RecoveryRequired, reopened.repository.refresh().error)
            assertFalse(Files.exists(libraryDir))
            assertFalse(reopened.startup.rootAvailable.value)
            assertEquals(0, reopened.secretConstructions)
            assertTrue(reopened.requests.isEmpty())
        } finally { reopened.close() }
    }

    @Test fun `cold missing-root sign out cleans credentials and reports any blocked journal recovery`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher)
        r.login()
        r.close()
        Files.move(libraryDir, filesDir.resolve("lost-library"))
        val reopened = Rig(dispatcher, r.secrets)
        try {
            val cleanup = reopened.sync.signOut()
            assertFalse(cleanup.recoveryRequired, "An absent journal requires no library mutation during sign-out")
            assertTrue(cleanup.isComplete)
            assertTrue(r.secrets.values.isEmpty())
            assertNull(reopened.sync.accounts.value!!.account)
            assertFalse(Files.exists(libraryDir))
            assertFalse(reopened.requests.any { it.url.endsWith("/sync/pull") || it.method == HttpMethod.PUT })
        } finally { reopened.close() }
    }

    @Test fun `signed-out reconstruction resumes locally without secret lookup or HTTP`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher)
        r.login()
        r.sync.signOut()
        r.close()
        val reopened = Rig(dispatcher)
        try {
            assertNull(reopened.repository.refresh().error)
            assertFalse(reopened.sync.resume().enabled)
            assertEquals(0, reopened.secrets.reads)
            assertTrue(reopened.requests.isEmpty())
        } finally { reopened.close() }
    }

    @Test fun `cold root loss during a pending apply still clears credentials and preserves recovery intent`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher)
        r.login()
        r.remote()
        r.checked.onFlush = { if (it == libraryDir.resolve("remote.md")) throw java.io.IOException("Synthetic failure") }
        assertNotNull(r.sync.runBackground().blockingIssue)
        val journal = Files.readAllBytes(stateDir.resolve("sync/apply.json"))
        r.close()
        Files.move(libraryDir, filesDir.resolve("lost-library"))
        val reopened = Rig(dispatcher, r.secrets)
        try {
            val cleanup = reopened.sync.signOut()
            assertTrue(cleanup.recoveryRequired)
            assertFalse(cleanup.isComplete)
            assertTrue(r.secrets.values.isEmpty())
            assertContentEquals(journal, Files.readAllBytes(stateDir.resolve("sync/apply.json")))
            assertFalse(Files.exists(libraryDir))
            assertNull(reopened.sync.accounts.value!!.account)
            assertFalse(reopened.requests.any { it.url.endsWith("/sync/pull") || it.method == HttpMethod.PUT })
        } finally { reopened.close() }
    }

    @Test fun `explicit local recovery can resume the retained enabled account on the same graph`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            r.login()
            r.remote()
            r.checked.onFlush = { if (it == libraryDir.resolve("remote.md")) throw java.io.IOException("Synthetic failure") }
            assertNotNull(r.sync.runBackground().blockingIssue)
            r.checked.onFlush = { }
            assertNull(r.sync.recoverLocal().error)
            assertFalse(r.sync.reports.value!!.enabled)
            assertTrue(r.sync.resume().enabled)
            val completed = r.sync.runBackground()
            assertTrue(completed.enabled)
            assertEquals(SyncStatus.IDLE, completed.status)
            assertNotNull(completed.lastSuccess)
        } finally { r.close() }
    }

    @Test fun `selected TLS trust reaches only the bound client and changes rebuild without bypassing 401`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            val server = SyncServerURL("https://example.test/paw")
            r.sync.selectServer(server)
            r.sync.setTlsTrust(server, SyncTLSTrust.SYSTEM_AND_USER)
            assertEquals(0, r.secretConstructions)
            r.login()
            assertTrue(r.requests.all { (it.urlPolicy as HttpUrlPolicy.Sync).trust == SyncTLSTrust.SYSTEM_AND_USER })
            r.requests.clear()
            r.sync.setTlsTrust(server, SyncTLSTrust.SYSTEM)
            r.sync.reconnect()
            assertTrue(r.requests.isNotEmpty())
            assertTrue(r.requests.all { (it.urlPolicy as HttpUrlPolicy.Sync).trust == SyncTLSTrust.SYSTEM })
            r.requests.clear()
            r.sync.requireSignIn()
            r.sync.resume()
            r.sync.reconnect()
            r.sync.syncNow()
            r.sync.runBackground()
            assertTrue(r.requests.isEmpty())
            val another = SyncServerURL("https://other.test/paw")
            assertEquals(SyncTLSTrust.SYSTEM, r.sync.selectServer(another)!!.trust)
            assertFailsWith<SyncTlsSettingsError.ServerChanged> { r.sync.setTlsTrust(server, SyncTLSTrust.SYSTEM_AND_USER) }
        } finally { r.close() }
    }

    @Test fun `cold authentication stop shows bound metadata without credentials or HTTP`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher)
        val account = r.login().account
        r.close()
        val reopened = Rig(dispatcher)
        try {
            reopened.sync.requireSignIn()
            assertEquals(account, reopened.sync.resume().account)
            assertEquals(account, reopened.sync.accounts.value!!.account)
            assertFalse(reopened.sync.accounts.value!!.enabled)
            assertEquals(0, reopened.secrets.reads)
            assertTrue(reopened.requests.isEmpty())
        } finally { reopened.close() }
    }

    @Test fun `restored original root resumes only from explicit sync entry and never from a local read`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            r.login()
            r.remote()
            r.sync.setExecutionMode(SyncExecutionMode.FOREGROUND)
            runCurrent()
            Files.move(libraryDir, filesDir.resolve("lost-library"))
            assertNotNull(r.repository.refresh().error)
            runCurrent()
            assertEquals(SyncBlockingIssue.ROOT_UNAVAILABLE, r.sync.reports.value!!.blockingIssue)
            val requests = r.requests.size
            Files.move(filesDir.resolve("lost-library"), libraryDir)
            assertNull(r.repository.refresh().error)
            runCurrent()
            assertEquals(requests, r.requests.size, "A local Application/IME read cannot dispatch foreground sync")
            assertTrue(r.startup.rootAvailable.value)
            assertEquals(SyncBlockingIssue.ROOT_UNAVAILABLE, r.sync.reports.value!!.blockingIssue)
            r.sync.resume()
            runCurrent()
            assertEquals(SyncStatus.IDLE, r.sync.reports.value!!.status)
            assertNull(r.sync.reports.value!!.blockingIssue)
            assertTrue(r.requests.size > requests)
        } finally { r.close() }
    }

    @Test fun `corrupt metadata or journal blocks the first local read without making a root`() = runTest {
        for (path in listOf("sync/state.json", "sync/account.json", "sync/binding.json", "sync/apply.json")) {
            put(stateDir.resolve(path), "{\"version\":999}".encodeToByteArray())
            val r = Rig(StandardTestDispatcher(testScheduler))
            try {
                var read = false
                r.beforeList = { read = true }
                assertNotNull(r.repository.refresh().error)
                assertFalse(read)
                assertFalse(Files.exists(libraryDir))
                assertTrue(r.requests.isEmpty())
            } finally { r.close(); Files.delete(stateDir.resolve(path)) }
        }
    }

    @Test fun `local recovery finishes the exact apply before reconstructed startup scans with no auth`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher)
        r.login()
        r.remote()
        r.checked.onFlush = { if (it == libraryDir.resolve("remote.md")) throw java.io.IOException("Synthetic failure") }
        val failed = r.sync.runBackground()
        assertNotNull(failed.blockingIssue)
        assertTrue(Files.exists(stateDir.resolve("sync/apply.json")))
        val expected = r.remote[promptID]!!.content
        r.close()
        val reopened = Rig(dispatcher)
        try {
            reopened.beforeList = { assertFalse(Files.exists(stateDir.resolve("sync/apply.json"))) }
            val ready = reopened.repository.refresh()
            assertNull(ready.error)
            assertEquals(expected, ready.snapshot.prompts.single().entry.document.source)
            assertFalse(Files.exists(stateDir.resolve("sync/apply.json")))
            assertEquals(0, reopened.secretConstructions)
            assertEquals(0, reopened.transportConstructions)
            assertTrue(reopened.requests.isEmpty())
            assertEquals(ready.snapshot.prompts.map { it.entry.relativePath to it.entry.stamp },
                reopened.repository.refresh().snapshot.prompts.map { it.entry.relativePath to it.entry.stamp })
        } finally { reopened.close() }
    }

    @Test fun `remote move publishes latest snapshot without a save trigger while user save triggers once`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            r.login()
            r.remote("old.md")
            val moved = r.sync.runBackground()
            assertNull(moved.blockingIssue, "${moved.status} ${moved.details.map { it.code }}")
            runCurrent()
            assertEquals(listOf("old.md"), r.repository.state.value.snapshot.prompts.map { it.entry.relativePath })
            r.remote("nested/new.md", 2)
            val movedAgain = r.sync.runBackground()
            assertNull(movedAgain.blockingIssue, "${movedAgain.status} ${movedAgain.details.map { it.code }}")
            assertEquals(SyncStatus.IDLE, movedAgain.status)
            assertTrue(movedAgain.enabled)
            assertEquals(2, r.requests.count { it.url.endsWith("/sync/pull") }, "Both passes collected")
            val bound = r.sync.accounts.value!!.account!!
            val persisted = r.sync.graph().local.states.load(SyncLibraryIdentity(bound.identity, SyncLibraryRoot(r.startup.libraryRoot)))!!
            assertEquals("nested/new.md", persisted.prompts.values.single().path, "Committed path after move")
            assertEquals(listOf("nested/new.md"), r.prompts.listFiles().map { it.relativePath }, "Disk after move")
            runCurrent()
            assertEquals(listOf("nested/new.md"), r.repository.state.value.snapshot.prompts.map { it.entry.relativePath })
            assertEquals(0L, r.library.sourceChanges.value)
            assertFalse(Files.exists(libraryDir.resolve("old.md")))
            val graph = r.sync.graph()
            val trigger = graph.engine.scheduling.value.triggerVersion
            r.repository.withLibrary { library, _ ->
                val current = library.load("nested/new.md")
                val draft = ch.lkmc.monkeyspaw.core.domain.format.PromptCodec.parse(current.document.source + " edit", "new.md")
                library.save(draft, current.relativePath, current.stamp)
            }
            runCurrent()
            assertEquals(trigger + 1, graph.engine.scheduling.value.triggerVersion)
            assertEquals(1L, r.library.sourceChanges.value)
            r.repository.refresh()
            r.repository.withLibrary { library, _ -> library.index.recordUse(library.load("nested/new.md").identity) }
            runCurrent()
            assertEquals(trigger + 1, graph.engine.scheduling.value.triggerVersion)
            assertFalse(r.requests.any { it.method == HttpMethod.PUT }, "Background events only retain work")
        } finally { r.close() }
    }

    @Test fun `viewer favourite and access changes publish projections without a source save`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            r.login()
            r.groupRole = Role.VIEWER
            r.remote(group = true)
            val pulled = r.sync.runBackground()
            assertNull(pulled.blockingIssue, "${pulled.status} ${pulled.details.map { it.code }}")
            runCurrent()
            val before = r.sync.graph().engine.scheduling.value.triggerVersion
            val entry = r.repository.state.value.snapshot.prompts.single().entry
            r.repository.withLibrary { library, _ -> library.toggleFavorite(entry) }
            runCurrent()
            assertTrue(r.repository.state.value.snapshot.prompts.single().entry.favorite)
            assertEquals(0L, r.library.sourceChanges.value)
            assertEquals(before, r.sync.graph().engine.scheduling.value.triggerVersion)
            assertEquals(Role.VIEWER, r.sync.access.value!!.groups.values.single().role)
            r.groupRole = Role.EDITOR
            r.sync.runBackground()
            runCurrent()
            assertEquals(Role.EDITOR, r.repository.state.value.snapshot.prompts.single().entry.access.let {
                (it as PromptAccessState.Group).group.role
            })
        } finally { r.close() }
    }

    @Test fun `sign out cancels an admitted pull drains it and preserves local bytes`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            r.login()
            r.repository.withLibrary { _, editing -> editing.create("local", "keep.md") }
            val entered = CompletableDeferred<Unit>()
            r.respond = { if (it.url.endsWith("/sync/pull")) { entered.complete(Unit); awaitCancellation() } else null }
            val work = async { r.sync.runBackground() }
            entered.await()
            assertTrue(r.sync.signOut().isComplete)
            work.join()
            runCurrent()
            assertTrue(work.isCancelled)
            assertTrue(Files.exists(libraryDir.resolve("keep.md")))
            assertTrue(r.secrets.values.isEmpty())
            assertFalse(r.sync.reports.value!!.enabled)
            assertNull(r.sync.accounts.value!!.account)
            assertFalse(r.requests.any { it.method == HttpMethod.PUT })
        } finally { r.close() }
    }

    @Test fun `retirement cancels account activation waits for compensation and rejects late entries`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            val entered = CompletableDeferred<Unit>()
            r.respond = { if (it.url.endsWith("/me")) { entered.complete(Unit); awaitCancellation() } else null }
            val login = async { r.login() }
            entered.await()
            assertEquals(SyncStopResult.STOPPED, r.sync.retire())
            login.join()
            assertTrue(login.isCancelled)
            assertTrue(r.secrets.values.isEmpty())
            assertFalse(r.sync.reports.value!!.enabled)
            assertFailsWith<CancellationException> { r.sync.runBackground() }
            assertFailsWith<CancellationException> { r.login() }
            assertFailsWith<CancellationException> { r.sync.signOut() }
            assertFailsWith<CancellationException> { r.sync.selectServer(SyncServerURL("https://other.test")) }
            assertFailsWith<CancellationException> {
                r.sync.setTlsTrust(SyncServerURL("https://example.test/paw"), SyncTLSTrust.SYSTEM_AND_USER)
            }
        } finally { r.close() }
    }

    @Test fun `root loss cancels work and cannot publish deletion inference or recreate the root`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler))
        try {
            r.login()
            r.remote()
            r.sync.runBackground()
            val entered = CompletableDeferred<Unit>()
            r.respond = { if (it.url.endsWith("/sync/pull")) { entered.complete(Unit); awaitCancellation() } else null }
            val work = async { r.sync.runBackground() }
            entered.await()
            Files.move(libraryDir, filesDir.resolve("lost-library"))
            assertNotNull(r.repository.refresh().error)
            runCurrent()
            work.join()
            assertTrue(work.isCancelled)
            assertFalse(Files.exists(libraryDir))
            assertEquals(SyncBlockingIssue.ROOT_UNAVAILABLE, r.sync.reports.value!!.blockingIssue)
            assertFalse(r.requests.any { it.method == HttpMethod.DELETE || it.method == HttpMethod.PUT })
        } finally { r.close() }
    }

    @Test fun `local launch with native scheduling hooks still constructs no scheduler or authenticated graph`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.repository.refresh()
            runCurrent()
            assertEquals(0, r.schedulerConstructions)
            assertEquals(0, r.secretConstructions)
            assertEquals(0, r.transportConstructions)
            assertTrue(r.requestsForWork.isEmpty())
            assertFalse(Files.exists(stateDir.resolve("sync/work.json")))
        } finally { r.close() }
    }

    @Test fun `native worker dispatch shares the account graph consumes once and arms no foreground timers`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            runCurrent()
            val request = r.requestsForWork.single()
            assertEquals(listOf(900_000L), r.periodicWork.values.toList())
            assertEquals(0, r.requests.count { it.url.endsWith("/sync/pull") })
            r.scheduler.dispatch(request)
            runCurrent()
            assertNotNull(r.sync.reports.value!!.lastSuccess)
            assertFalse(r.workStore.read().pending)
            r.scheduler.dispatch(request)
            advanceTimeBy(3_600_000)
            runCurrent()
            assertEquals(1, r.requests.count { it.url.endsWith("/sync/pull") })
            assertEquals(1, r.secretConstructions)
            assertEquals(1, r.transportConstructions)
        } finally { r.close() }
    }

    @Test fun `native 401 is durable and reconstructed worker resume and foreground entry read no credentials`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val r = Rig(dispatcher, scheduled = true)
        r.login()
        r.respond = { if (it.url.endsWith("/sync/pull")) HttpResponse(401,
            body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.UNAUTHORIZED))) else null }
        val request = r.requestsForWork.single()
        r.scheduler.dispatch(request)
        runCurrent()
        assertTrue(r.workStore.read().needsSignIn)
        val readsBeforeRestart = r.secrets.reads
        r.close()
        val reopened = Rig(dispatcher, r.secrets, scheduled = true)
        try {
            reopened.scheduler.dispatch(request)
            reopened.sync.resume()
            reopened.sync.reconnect()
            reopened.scheduler.enter(SyncForegroundOwner.ACCOUNT)
            reopened.sync.syncNow()
            runCurrent()
            assertEquals(readsBeforeRestart, reopened.secrets.reads)
            assertTrue(reopened.requests.isEmpty())
            assertTrue(reopened.sync.reports.value!!.needsSignIn)
            assertNotNull(reopened.sync.accounts.value!!.account)
            reopened.scheduler.leave(SyncForegroundOwner.ACCOUNT)
            reopened.login()
            assertFalse(reopened.workStore.read().needsSignIn)
            assertNotEquals(request.generation, reopened.workStore.read().generation)
            reopened.scheduler.dispatch(reopened.requestsForWork.last())
            assertEquals(1, reopened.requests.count { it.url.endsWith("/sync/pull") })
        } finally { reopened.close() }
    }

    @Test fun `changed checked flush failure leaves every repository observer running`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.scheduler.dispatch(r.requestsForWork.single())
            runCurrent()
            failNextWorkFlush(r)
            r.sync.graph().engine.committedMutation(SyncChangeOrigin.USER)
            runCurrent()
            assertEquals(1, r.backgroundErrors.size)
            assertObservationContinues(r)
        } finally { r.close() }
    }

    @Test fun `saved checked flush failure denies that mutation and preserves later observation`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.scheduler.dispatch(r.requestsForWork.single())
            runCurrent()
            val trigger = r.sync.graph().engine.scheduling.value.triggerVersion
            failNextWorkFlush(r)
            r.repository.withLibrary { _, editing -> editing.create("first", "first.md") }
            runCurrent()
            assertEquals(1, r.backgroundErrors.size)
            assertEquals(trigger, r.sync.graph().engine.scheduling.value.triggerVersion)
            assertObservationContinues(r)
        } finally { r.close() }
    }

    @Test fun `unreadable work state fails closed per save without killing repository observers`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.scheduler.dispatch(r.requestsForWork.single())
            runCurrent()
            val path = stateDir.resolve("sync/work.json")
            val good = Files.readAllBytes(path)
            val trigger = r.sync.graph().engine.scheduling.value.triggerVersion
            val pulls = r.requests.count { it.url.endsWith("/sync/pull") }
            Files.writeString(path, "unreadable-state")
            repeat(2) { index ->
                r.repository.withLibrary { _, editing -> editing.create("held$index", "held$index.md") }
                runCurrent()
            }
            assertEquals(2, r.backgroundErrors.size)
            assertEquals(trigger, r.sync.graph().engine.scheduling.value.triggerVersion)
            assertEquals(pulls, r.requests.count { it.url.endsWith("/sync/pull") })
            assertEquals("unreadable-state", Files.readString(path))
            Files.write(path, good)
            assertObservationContinues(r)
        } finally { r.close() }
    }

    @Test fun `saved enqueue failure retains durable intent forwards eligible mutations and later recovers`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.scheduler.dispatch(r.requestsForWork.single())
            runCurrent()
            val trigger = r.sync.graph().engine.scheduling.value.triggerVersion
            var attempts = 0
            r.beforeWorkEnqueue = {
                attempts++
                val durable = SyncWorkStateStore(r.files, r.files.syncOperations).read()
                assertTrue(durable.pending)
                assertEquals(SyncWorkReason.SAVE, durable.reason)
                error("Synthetic enqueue failure with private diagnostics")
            }
            r.repository.withLibrary { _, editing -> editing.create("first", "first.md") }
            runCurrent()
            assertTrue(r.workStore.read().pending)
            assertEquals(trigger + 1, r.sync.graph().engine.scheduling.value.triggerVersion)
            assertTrue(attempts in 1..2, "No immediate retry loop")
            val settled = attempts
            runCurrent()
            assertEquals(settled, attempts)
            assertTrue(r.backgroundErrors.isNotEmpty())
            assertTrue(r.backgroundErrors.all { it.message == "Sync scheduling failed." && it.cause == null })
            r.beforeWorkEnqueue = {}
            val queued = r.requestsForWork.size
            r.repository.withLibrary { _, editing -> editing.create("recovered", "recovered.md") }
            runCurrent()
            assertEquals(trigger + 2, r.sync.graph().engine.scheduling.value.triggerVersion)
            assertEquals(queued + 1, r.requestsForWork.size)
            r.workTime += 3_000
            r.scheduler.dispatch(r.requestsForWork.last())
            runCurrent()
            assertFalse(r.workStore.read().pending)
            assertEquals(2, r.requests.count { it.url.endsWith("/sync/pull") })
            assertObservationContinues(r)
        } finally { r.close() }
    }

    @Test fun `saved enqueue cancellation propagates without forwarding or reporting a recoverable failure`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.scheduler.dispatch(r.requestsForWork.single())
            runCurrent()
            val trigger = r.sync.graph().engine.scheduling.value.triggerVersion
            r.beforeWorkEnqueue = { throw CancellationException("Synthetic cancellation") }
            r.repository.withLibrary { _, editing -> editing.create("first", "first.md") }
            runCurrent()
            assertTrue(r.workStore.read().pending)
            assertEquals(trigger, r.sync.graph().engine.scheduling.value.triggerVersion)
            assertTrue(r.backgroundErrors.isEmpty())
        } finally { r.close() }
    }

    private fun failNextWorkFlush(r: Rig) {
        r.checked.onFlush = { path ->
            if (path == stateDir.resolve("sync/work.json")) {
                r.checked.onFlush = {}
                throw java.io.IOException("Synthetic checked flush failure")
            }
        }
    }

    private suspend fun TestScope.assertObservationContinues(r: Rig) {
        val graph = r.sync.graph()
        val trigger = graph.engine.scheduling.value.triggerVersion
        r.repository.withLibrary { _, editing -> editing.create("later", "later.md") }
        runCurrent()
        assertEquals(trigger + 1, graph.engine.scheduling.value.triggerVersion, "Later USER mutation reaches shared engine")
        r.groupRole = Role.VIEWER
        r.remote(group = true)
        r.sync.runBackground()
        r.respond = { request -> if (request.url.endsWith("/me")) HttpResponse(200, body = MeResponse.codec.encode(
            MeResponse(User(userID, "updated", null, AccountKind.MEMBER, timestamp, null), emptyList(),
                listOf(Device(deviceID, "Android", timestamp, null, null, true))))) else null }
        r.sync.refreshAccount()
        runCurrent()
        assertEquals("updated", r.sync.accounts.value!!.me!!.user.username)
        assertEquals(Role.VIEWER, r.sync.access.value!!.groups.values.single().role)
        assertNotNull(r.sync.reports.value!!.lastSuccess)
        assertEquals(graph.engine.scheduling.value, r.sync.scheduling.value)
        assertTrue(r.repository.state.value.snapshot.prompts.any { it.entry.relativePath.endsWith("remote.md") })
        Files.move(libraryDir, filesDir.resolve("lost-library"))
        assertNotNull(r.repository.refresh().error)
        runCurrent()
        assertEquals(SyncBlockingIssue.ROOT_UNAVAILABLE, graph.engine.reports.value.blockingIssue, "Root collector remains active")
        assertEquals(SyncBlockingIssue.ROOT_UNAVAILABLE, r.sync.reports.value!!.blockingIssue)
    }

    @Test fun `canceling native worker cancels its HTTP pass but keeps restartable pending work`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            val entered = CompletableDeferred<Unit>()
            r.respond = { if (it.url.endsWith("/sync/pull")) { entered.complete(Unit); awaitCancellation() } else null }
            val work = launch { r.scheduler.dispatch(r.requestsForWork.single()) }
            entered.await()
            work.cancelAndJoin()
            runCurrent()
            assertTrue(r.workStore.read().pending)
            assertEquals(10_000, r.requestsForWork.last().delayMillis)
            r.respond = null
            r.workTime += 10_000
            r.scheduler.dispatch(r.requestsForWork.last())
            runCurrent()
            assertFalse(r.workStore.read().pending)
            assertNotNull(r.sync.reports.value!!.lastSuccess)
        } finally { r.close() }
    }

    @Test fun `native save during worker completion preserves one queued successor`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            r.respond = { if (it.url.endsWith("/sync/pull")) { entered.complete(Unit); release.await(); null } else null }
            val work = launch { r.scheduler.dispatch(r.requestsForWork.single()) }
            entered.await()
            r.repository.withLibrary { _, editing -> editing.create("saved", "saved.md") }
            runCurrent()
            assertEquals(1, r.requestsForWork.size)
            release.complete(Unit)
            work.join()
            runCurrent()
            assertTrue(r.workStore.read().pending)
            assertEquals(2, r.requestsForWork.size)
            assertEquals(3_000, r.requestsForWork.last().delayMillis)
            r.workTime += 3_000
            r.scheduler.dispatch(r.requestsForWork.last())
            runCurrent()
            assertFalse(r.workStore.read().pending)
            assertEquals(2, r.requests.count { it.url.endsWith("/sync/pull") })
        } finally { r.close() }
    }

    @Test fun `native foreground and old worker deliveries consume the same live trigger`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            val request = r.requestsForWork.single()
            r.scheduler.enter(SyncForegroundOwner.LIBRARY)
            runCurrent()
            assertFalse(r.workStore.read().pending)
            assertEquals(1, r.requests.count { it.url.endsWith("/sync/pull") })
            r.scheduler.dispatch(request)
            r.scheduler.leave(SyncForegroundOwner.LIBRARY)
            r.scheduler.dispatch(request)
            runCurrent()
            assertEquals(1, r.requests.count { it.url.endsWith("/sync/pull") })
        } finally { r.close() }
    }

    @Test fun `reconstructed foreground engine honors durable background retry due without another timer`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val mono = MonotonicClock { testScheduler.currentTime * 1_000_000 }
        val r = Rig(dispatcher, mono = mono, scheduled = true)
        r.login()
        r.respond = { if (it.url.endsWith("/sync/pull")) HttpResponse(503, body = byteArrayOf()) else null }
        r.scheduler.dispatch(r.requestsForWork.single())
        runCurrent()
        assertEquals(10_000, r.workStore.read().dueAt - r.workTime)
        r.close()
        val reopened = Rig(dispatcher, r.secrets, mono, scheduled = true)
        try {
            reopened.scheduler.enter(SyncForegroundOwner.LIBRARY)
            runCurrent()
            assertEquals(0, reopened.requests.count { it.url.endsWith("/sync/pull") })
            reopened.workTime += 9_999
            advanceTimeBy(9_999)
            runCurrent()
            assertEquals(0, reopened.requests.count { it.url.endsWith("/sync/pull") })
            reopened.workTime++
            advanceTimeBy(1)
            runCurrent()
            assertEquals(1, reopened.requests.count { it.url.endsWith("/sync/pull") })
            reopened.scheduler.leave(SyncForegroundOwner.LIBRARY)
        } finally { reopened.close() }
    }

    @Test fun `failed reauthentication never clears a durable 401 stop`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.sync.requireSignIn()
            runCurrent()
            assertTrue(r.workStore.read().needsSignIn)
            val generation = r.workStore.read().generation
            r.respond = { if (it.url.endsWith("/auth/login")) HttpResponse(401,
                body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.UNAUTHORIZED))) else null }
            assertFailsWith<SyncAccountServiceError> { r.login() }
            runCurrent()
            assertTrue(SyncWorkStateStore(r.files, r.files.syncOperations).read().needsSignIn)
            assertEquals(generation, r.workStore.read().generation)
        } finally { r.close() }
    }

    @Test fun `native periodic work scans for missed events after all live engine triggers were consumed`() = runTest {
        val r = Rig(StandardTestDispatcher(testScheduler), scheduled = true)
        try {
            r.login()
            r.scheduler.dispatch(r.requestsForWork.single())
            runCurrent()
            assertEquals(1, r.requests.count { it.url.endsWith("/sync/pull") })
            r.remote("later.md")
            r.workTime += 900_000
            r.scheduler.dispatch(SyncWorkRequest(r.workStore.read().generation))
            runCurrent()
            assertEquals(2, r.requests.count { it.url.endsWith("/sync/pull") })
            assertTrue(Files.exists(libraryDir.resolve("later.md")))
        } finally { r.close() }
    }

    private companion object {
        const val userID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        const val deviceID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        const val promptID = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
        const val groupID = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        const val databaseID = "11111111-1111-4111-8111-111111111111"
        const val timestamp = "2026-10-14T00:00:00.000Z"
    }
}
