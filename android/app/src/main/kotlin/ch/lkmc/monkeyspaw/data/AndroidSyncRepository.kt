package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Authorized foreground and OS-worker entry share one lazy authenticated graph.
 * Reading a flow does no IO. Local launch never depends on this repository.
 */
internal class AndroidSyncRepository(
    private val startup: AndroidSyncStartup,
    private val library: LibraryService,
    private val repository: LibraryRepository,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val engineFactory: (SyncLocalGraph) -> SyncEngine,
    private val accountFactory: (SyncEngine, SyncLocalGraph) -> SyncAccountService,
    private val settings: AndroidSettingsStore,
    private val work: SyncWorkHooks = SyncWorkHooks.None,
) {
    internal class Graph(val local: SyncLocalGraph, val engine: SyncEngine, val account: SyncAccountService)
    private enum class GraphUse { READY, SIGN_OUT }
    private val graphMutex = Mutex()
    private val accountMutex = Mutex()
    private val lifecycleLock = Any()
    private var generation = 0L
    @Volatile private var retired = false
    private var accountWork: Job? = null
    @Volatile private var current: Graph? = null
    private var observers: Job? = null
    @Volatile private var mode = SyncExecutionMode.BACKGROUND
    private val mutableReports = MutableStateFlow<SyncReport?>(null)
    private val mutableScheduling = MutableStateFlow<SyncSchedulingState?>(null)
    private val mutableAccounts = MutableStateFlow<SyncAccountSnapshot?>(null)
    private val mutableAccess = MutableStateFlow<GroupAccessSnapshot?>(null)
    val reports = mutableReports.asStateFlow()
    val scheduling = mutableScheduling.asStateFlow()
    val accounts = mutableAccounts.asStateFlow()
    val access = mutableAccess.asStateFlow()

    internal fun workFacts(): SyncWorkFacts? = current?.engine?.let { SyncWorkFacts(it.scheduling.value, it.reports.value) }

    internal suspend fun restoreWorkEligibility(retries: Int, dueAt: Long) = withContext(io) {
        graph().engine.restoreWorkEligibility(retries, java.time.Instant.ofEpochMilli(dueAt))
    }

    internal suspend fun graph(): Graph = graph(GraphUse.READY)

    private suspend fun graph(use: GraphUse): Graph = withContext(io) {
        graphMutex.withLock {
            synchronized(lifecycleLock) { if (use == GraphUse.READY) checkActive() }
            current ?: (if (use == GraphUse.READY) startup.ready() else startup.metadata()).let { local ->
                synchronized(lifecycleLock) { if (use == GraphUse.READY) checkActive() }
                val engine = engineFactory(local)
                Graph(local, engine, accountFactory(engine, local)).also { graph ->
                    current = graph
                    if (!retired) observe(graph)
                }
            }
        }
    }

    private fun observe(graph: Graph) {
        observers = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            launch(start = CoroutineStart.UNDISPATCHED) {
                graph.engine.reports.collect { mutableReports.value = it; observeWork { work.changed() } }
            }
            launch(start = CoroutineStart.UNDISPATCHED) {
                graph.engine.scheduling.collect { mutableScheduling.value = it; observeWork { work.changed() } }
            }
            launch(start = CoroutineStart.UNDISPATCHED) { graph.account.snapshots.collect { mutableAccounts.value = it } }
            launch(start = CoroutineStart.UNDISPATCHED) {
                graph.local.access.snapshots.collect {
                    mutableAccess.value = it
                    repository.publishProjection()
                }
            }
            launch(start = CoroutineStart.UNDISPATCHED) {
                library.sourceChanges.drop(1).collect {
                    if (observeWork { work.saved() }) {
                        graph.engine.committedMutation(SyncChangeOrigin.USER, graph.engine.scheduling.value.epoch)
                    }
                }
            }
            launch(start = CoroutineStart.UNDISPATCHED) {
                graph.engine.libraryVersion.drop(1).collect { repository.refreshAfterCommit() }
            }
            launch(start = CoroutineStart.UNDISPATCHED) {
                startup.rootAvailable.collect { available ->
                    if (!available) {
                        invalidate()
                        graph.engine.rootHealthChanged(SyncRootHealth.UNAVAILABLE)
                        graph.engine.drain()
                    }
                }
            }
        }
    }

    /** Isolate each event; only a lost OS enqueue may admit an already durable USER mutation. */
    private suspend fun observeWork(action: suspend () -> Unit): Boolean {
        return try {
            action()
            true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val context = currentCoroutineContext()
            context[CoroutineExceptionHandler]?.handleException(context, IllegalStateException("Sync scheduling failed."))
            error is SyncWorkEnqueueFailure
        }
    }

    /** Only an authorized Library/Account entry or worker calls resume, never Application/IME. */
    suspend fun resume(): SyncAccountSnapshot = accountOperation { graph ->
        if (work.authenticationStopped()) graph.engine.requireSignIn()
        if (graph.engine.reports.value.needsSignIn) return@accountOperation stoppedAccount(graph)
        if (graph.account.snapshot.enabled && graph.engine.reports.value.enabled) graph.account.snapshot else graph.account.startup()
    }

    suspend fun login(server: String, username: String, password: SecretValue, deviceName: String): SyncAccountSnapshot {
        return accountOperation {
            settings.selectSyncServer(SyncServerURL(server))
            it.account.login(server, username, password, deviceName)
        }.also { snapshot -> snapshot.account?.let { work.authenticated(it.connectionID.toString()) } }
    }

    suspend fun selectServer(server: SyncServerURL?): SyncTlsSettings? = withContext(io) {
        synchronized(lifecycleLock) { checkActive() }
        settings.selectSyncServer(server).syncTls
    }

    suspend fun setTlsTrust(server: SyncServerURL, trust: SyncTLSTrust): SyncTlsSettings = withContext(io) {
        synchronized(lifecycleLock) { checkActive() }
        checkNotNull(settings.setSyncTlsTrust(server, trust).syncTls)
    }

    /** Rebuild the verified client after a trust edit; a 401 still requires reauthentication. */
    suspend fun reconnect(): SyncAccountSnapshot = accountOperation {
        if (work.authenticationStopped()) it.engine.requireSignIn()
        if (it.engine.reports.value.needsSignIn) stoppedAccount(it) else it.account.startup()
    }

    suspend fun refreshAccount(): SyncAccountSnapshot = accountOperation { it.account.refresh() }
    suspend fun devices() = accountOperation { it.account.devices() }
    suspend fun heldPrompts() = accountOperation { it.account.heldPrompts() }
    suspend fun includeHeld(identities: Set<PromptIdentity>): SyncAccountSnapshot =
        accountOperation { it.account.includeHeld(identities) }
    suspend fun revokeDevice(id: ULID): SyncAccountSnapshot = accountOperation { it.account.revokeDevice(id) }.also {
        if (it.account == null) work.signedOut()
    }

    private suspend fun <T> accountOperation(work: suspend (Graph) -> T): T = withContext(io) {
        val expected = synchronized(lifecycleLock) { checkActive(); generation }
        accountMutex.withLock {
            coroutineScope {
                val owner = currentCoroutineContext()[Job]
                synchronized(lifecycleLock) {
                    checkActive()
                    if (generation != expected) throw CancellationException("Sync session changed.")
                    accountWork = owner
                }
                try {
                    val graph = graph()
                    readyForSync(graph)
                    work(graph).also { graph.engine.setExecutionMode(mode) }
                } finally {
                    synchronized(lifecycleLock) { accountWork = null }
                }
            }
        }
    }

    suspend fun signOut(): SyncAccountCleanup = withContext(io + NonCancellable) {
        work.signedOut()
        invalidate()
        accountMutex.withLock {
            synchronized(lifecycleLock) { checkActive() }
            val graph = graph(GraphUse.SIGN_OUT)
            graph.account.signOut().also {
                mutableAccounts.value = graph.account.snapshot
                mutableReports.value = graph.engine.reports.value
                mutableScheduling.value = graph.engine.scheduling.value
                mutableAccess.value = graph.local.access.snapshot
                repository.publishProjection()
            }
        }
    }

    suspend fun setExecutionMode(value: SyncExecutionMode) = withContext(io) {
        mode = value
        val graph = graph()
        if (value == SyncExecutionMode.FOREGROUND) readyForSync(graph)
        graph.engine.setExecutionMode(value)
    }

    suspend fun syncNow() = withContext(io) { val graph = graph(); readyForSync(graph); graph.engine.syncNow() }

    /** Resume is explicit so Z20 can restore its durable authentication stop before dispatch. */
    suspend fun runBackground(expectedEpoch: Long? = null, version: Long? = null): SyncReport = withContext(io) {
        val graph = graph()
        startup.ready()
        graph.engine.runBackground(expectedEpoch, version)
    }

    suspend fun requireSignIn() = withContext(io) {
        val graph = graph()
        graph.engine.requireSignIn()
        stoppedAccount(graph)
        Unit
    }

    private fun stoppedAccount(graph: Graph): SyncAccountSnapshot = graph.local.accountMetadata().also { mutableAccounts.value = it }

    private suspend fun readyForSync(graph: Graph) {
        startup.ready()
        // A local Application/IME read may restore the root fact, but only an explicit sync entry resumes work.
        graph.engine.rootHealthChanged(SyncRootHealth.AVAILABLE)
    }

    suspend fun recoverLocal(): LibraryState = withContext(io) {
        invalidate()
        accountMutex.withLock {
            val graph = graphMutex.withLock { current }
            graph?.engine?.stop()
            graph?.engine?.drain()
            graph?.let { mutableAccounts.value = it.account.snapshot.copy(enabled = false) }
            startup.ready().recover()
            graph?.engine?.rootHealthChanged(SyncRootHealth.AVAILABLE)
            repository.refresh()
        }
    }

    suspend fun retire(): SyncStopResult = withContext(io + NonCancellable) {
        work.signedOut()
        synchronized(lifecycleLock) { retired = true }
        invalidate()
        accountMutex.withLock {
            graphMutex.withLock graphLock@{
                val graph = current ?: return@graphLock SyncStopResult.STOPPED
                graph.engine.stop()
                graph.engine.drain()
                try {
                    startup.ready().recover()
                    graph.engine.retire()
                } catch (_: Exception) {
                    SyncStopResult.RECOVERY_REQUIRED
                }.also {
                    observers?.cancelAndJoin()
                    mutableReports.value = graph.engine.reports.value
                    mutableScheduling.value = graph.engine.scheduling.value
                    mutableAccounts.value = graph.account.snapshot.copy(enabled = false, me = null, tier = null)
                }
            }
        }
    }

    private fun invalidate() = synchronized(lifecycleLock) {
        generation++
        accountWork?.cancel(CancellationException("Sync session changed."))
    }

    private fun checkActive() {
        if (retired) throw CancellationException("Sync graph retired.")
    }
}
