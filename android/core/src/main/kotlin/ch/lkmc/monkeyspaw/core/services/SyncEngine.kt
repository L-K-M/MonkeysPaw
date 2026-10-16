package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The same graph is shared by foreground sessions, workers and account transitions. */
internal class SyncEngineGraph(
    val files: StateStore, val states: SyncStateStore, val accounts: SyncAccountStore,
    val mutations: SyncLibraryMutations, val journal: SyncApplyJournal, val pending: SyncPendingOperationStore,
)

/** Graph-scoped orchestration. Blocking IO and timers use the injected coroutine execution. */
class SyncEngine internal constructor(
    internal val graph: SyncEngineGraph,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val wallClock: Clock,
    private val freshID: () -> ULID,
    private val monotonicClock: MonotonicClock,
) {
    /** Construct on IO, after checking the established root; construction performs local journal gating only. */
    constructor(
        library: LibraryService, libraryOperations: SyncFileOperations,
        dataFiles: StateStore, dataOperations: SyncFileOperations,
        states: SyncStateStore, accounts: SyncAccountStore,
        scope: CoroutineScope, io: CoroutineDispatcher, clock: Clock, entropy: Entropy,
        monotonicClock: MonotonicClock = MonotonicClock(System::nanoTime),
    ) : this(makeGraph(library, libraryOperations, dataFiles, dataOperations, states, accounts),
        scope, io, clock, { ULID.generate(clock.now(), entropy.bytes(Limits.ulidEntropyBytes)) }, monotonicClock)

    private class Session(val binding: SyncLibraryIdentity, val client: SyncHTTPClient, val device: String)
    private enum class RunKind { PASS, RECOVERY }
    private class Active(val epoch: Long, val version: Long, val parent: CompletableJob, val coordinator: SyncCoordinator) {
        lateinit var task: Deferred<SyncReport>
    }
    private val lock = ReentrantLock()
    private val mutableReport = MutableStateFlow(SyncReport())
    private val mutableScheduling = MutableStateFlow(SyncSchedulingState())
    private val mutableLibraryVersion = MutableStateFlow(0L)
    val reports: StateFlow<SyncReport> = mutableReport.asStateFlow()
    val scheduling: StateFlow<SyncSchedulingState> = mutableScheduling.asStateFlow()
    /** Always refresh index/editor after a committed event, including sync-origin events. */
    val libraryVersion: StateFlow<Long> = mutableLibraryVersion.asStateFlow()
    private var session: Session? = null
    private var graphRoot: SyncLibraryRoot? = null
    private var active: Active? = null
    private var mode = SyncExecutionMode.BACKGROUND
    private var health = SyncRootHealth.AVAILABLE
    private var retired = false
    private var epoch = 0L
    private var triggerVersion = 0L
    private var consumedVersion = 0L
    private var dirty = false
    private var immediateReruns = 0
    private var retryCount = 0
    private var retryAtNanos: Long? = null
    private var poll: Job? = null
    private var debounce: Job? = null
    private var retry: Job? = null

    /** Called only after account activation. Background activation itself performs no HTTP or starts timers. */
    internal suspend fun start(binding: SyncLibraryIdentity, client: SyncHTTPClient, device: String,
                               executionMode: SyncExecutionMode = SyncExecutionMode.BACKGROUND) = withContext(io) {
        val context = currentCoroutineContext()
        lock.withLock {
            requireStoppedGraph(binding.root)
            if (client.server.baseURL != binding.account.serverURL) throw SyncError.BindingMismatch
            sweepPullStaging()
            context.ensureActive()
            scope.coroutineContext.ensureActive()
            invalidateTimers()
            epoch++
            graphRoot = binding.root
            session = Session(binding, client, device)
            mode = executionMode
            retryCount = 0
            retryAtNanos = null
            immediateReruns = 0
            mutableReport.value = SyncReport(enabled = true)
            markDirty()
            publishScheduling()
            if (mode == SyncExecutionMode.FOREGROUND) { armPoll(); launch() }
        }
    }

    fun setExecutionMode(executionMode: SyncExecutionMode): Unit = lock.withLock {
        if (retired || mode == executionMode) return@withLock
        val pendingSave = debounce?.isActive == true
        mode = executionMode
        invalidateTimers()
        if (pendingSave && eligible) { markDirty(); publishScheduling() }
        if (mode == SyncExecutionMode.FOREGROUND && eligible) {
            markDirty()
            armPoll()
            armRetry()
            launch()
        }
    }

    fun syncNow(): Unit = lock.withLock {
        if (!eligible) return@withLock
        retry?.cancel()
        retry = null
        retryAtNanos = null
        debounce?.cancel()
        debounce = null
        immediateReruns = 0
        markDirty()
        publishScheduling()
        launch()
    }

    fun localSave(): Unit = committedMutation(SyncChangeOrigin.USER)

    fun committedMutation(origin: SyncChangeOrigin, expectedEpoch: Long = scheduling.value.epoch): Unit = lock.withLock {
        if (retired || expectedEpoch != epoch) return@withLock
        mutableLibraryVersion.value++
        if (origin == SyncChangeOrigin.SYNC || !eligible) return@withLock
        if (mode == SyncExecutionMode.BACKGROUND) { markDirty(); publishScheduling(); return@withLock }
        debounce?.cancel()
        val generation = epoch
        debounce = scope.launch {
            delay(Limits.syncDebounceMillis)
            val context = currentCoroutineContext()
            lock.withLock {
                if (!context.isActive || epoch != generation || !eligible || mode != SyncExecutionMode.FOREGROUND) return@withLock
                if (active == null) immediateReruns = 0
                markDirty()
                publishScheduling()
                launch()
            }
        }
    }

    /** A worker awaits at most one pass. Already-consumed or retired dispatches perform no HTTP. */
    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun runBackground(expectedEpoch: Long? = null, version: Long? = null): SyncReport = suspendCancellableCoroutine { continuation ->
        var owned: Active? = null
        var completion: DisposableHandle? = null
        continuation.invokeOnCancellation {
            completion?.dispose()
            lock.withLock {
                if (owned != null && active === owned) {
                    stopWork()
                    // Native dispatch must still see interrupted work, including a durable sent intent.
                    if (eligible) { markDirty(); publishScheduling() }
                }
            }
        }
        val run = lock.withLock {
            if (!continuation.isActive || expectedEpoch != null && expectedEpoch != epoch || !eligible) return@withLock null
            if (version != null && (version > triggerVersion || version <= consumedVersion)) return@withLock null
            active?.let { return@withLock it }
            if (version == null) markDirty()
            launch()?.also { owned = it }
        }
        if (run == null) continuation.resume(reports.value)
        else completion = run.task.invokeOnCompletion { error ->
            if (error == null) continuation.resume(run.task.getCompleted())
            else continuation.resumeWithException(error)
        }
    }

    fun stop(): SyncStopResult = lock.withLock {
        mutableReport.value = mutableReport.value.copy(enabled = false)
        stopWork()
    }

    /** Sign-out drops authentication even if the local journal still needs recovery. */
    internal fun stopAccountSession(): Unit = lock.withLock {
        mutableReport.value = reports.value.copy(enabled = false)
        stopWork()
        session = null
    }

    /** Startup can reinstate a persisted authentication stop without looking up a secret or dispatching HTTP. */
    internal fun requireSignIn(): Unit = lock.withLock {
        mutableReport.value = reports.value.copy(enabled = false, needsSignIn = true)
        stopWork()
    }

    fun retire(): SyncStopResult = lock.withLock {
        mutableReport.value = mutableReport.value.copy(enabled = false)
        stopWork().also { if (it == SyncStopResult.STOPPED) { retired = true; session = null } }
    }

    /** This suspends off UI; it never holds the library mutation lock. */
    suspend fun drain() {
        val task = lock.withLock { active?.task }
        withContext(NonCancellable) { task?.join() }
    }

    fun rootHealthChanged(rootHealth: SyncRootHealth): SyncStopResult = lock.withLock {
        if (health == rootHealth) return@withLock if (active != null) SyncStopResult.BUSY else recoveryState()
        health = rootHealth
        if (health == SyncRootHealth.UNAVAILABLE) {
            mutableReport.value = mutableReport.value.copy(blockingIssue = SyncBlockingIssue.ROOT_UNAVAILABLE)
            return@withLock stopWork()
        }
        if (retired) return@withLock recoveryState()
        mutableReport.value = mutableReport.value.copy(blockingIssue = null)
        if (mutableReport.value.enabled) {
            markDirty()
            if (mode == SyncExecutionMode.FOREGROUND) { armPoll(); launch() }
        }
        if (active != null) SyncStopResult.BUSY else recoveryState()
    }

    /** Recover exact old-graph intents only. This never collects or scans unrelated files. */
    suspend fun recoverJournal(): Unit = suspendCancellableCoroutine { continuation ->
        var owned: Active? = null
        var completion: DisposableHandle? = null
        continuation.invokeOnCancellation {
            completion?.dispose()
            lock.withLock { if (owned != null && active === owned) stopWork() }
        }
        val run = lock.withLock {
            if (!continuation.isActive) return@withLock null
            val session = session ?: throw SyncError.InvalidAccount
            requireStoppedGraph(session.binding.root)
            if (reports.value.needsSignIn) throw SyncPushError.Busy
            invalidateTimers()
            epoch++
            mutableReport.value = reports.value.copy(enabled = false)
            newActive(RunKind.RECOVERY).also { owned = it }
        } ?: return@suspendCancellableCoroutine
        completion = run.task.invokeOnCompletion { error ->
            if (error == null) continuation.resume(Unit)
            else continuation.resumeWithException(error)
        }
    }

    /** Account services use these same capabilities only after stop/drain. */
    internal fun requireStoppedGraph(root: SyncLibraryRoot) = lock.withLock {
        if (active != null || retired) throw SyncPushError.Busy
        if (health != SyncRootHealth.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        if (graphRoot != null && graphRoot != root) throw SyncError.BindingMismatch
        if (graph.journal.pending?.nextState?.binding?.root?.let { it != root } == true) throw SyncError.BindingMismatch
    }

    private val eligible: Boolean get() = reports.value.enabled && !retired && health == SyncRootHealth.AVAILABLE &&
        !reports.value.needsSignIn && reports.value.blockingIssue == null && scope.coroutineContext[Job]?.isActive != false

    private fun launch(): Active? {
        if (!eligible || active != null || !dirty || session == null) return null
        if (retryAtNanos?.let { it - monotonicClock.nowNanos() > 0 } == true) return null
        return newActive(RunKind.PASS)
    }

    private fun newActive(kind: RunKind): Active {
        val session = session ?: throw SyncError.InvalidAccount
        // A reported recovery failure must leave the graph alive for another explicit attempt.
        val parent = SupervisorJob(scope.coroutineContext[Job])
        val permit = SyncWorkPermit(session.binding, epoch, parent)
        val generation = epoch
        val coordinator = SyncCoordinator(permit, session.client, graph.files, graph.states, graph.accounts,
            graph.mutations, graph.journal, graph.pending, session.device, freshID, wallClock::now, monotonicClock) {
            lock.withLock { if (epoch == generation) mutableLibraryVersion.value++ }
        }
        val run = Active(epoch, triggerVersion, parent, coordinator)
        active = run
        dirty = false
        mutableReport.value = reports.value.copy(phase = SyncPhase.RECOVERING,
            counts = reports.value.counts.copy(pulled = 0, pushed = 0))
        run.task = scope.async(io + parent, start = CoroutineStart.LAZY) {
            val result = runCatching {
                if (kind == RunKind.RECOVERY) { coordinator.recoverJournal(); SyncPassResult() }
                else coordinator.run(progress = { pass ->
                    lock.withLock {
                        if (epoch == generation && eligible) mutableReport.value = reports.value.copy(counts = pass.counts, details = pass.details)
                    }
                }, phase = { phase ->
                    lock.withLock { if (epoch == generation && eligible) mutableReport.value = reports.value.copy(phase = phase) }
                })
            }
            val report = finish(run, result, kind)
            if (kind == RunKind.RECOVERY) result.getOrThrow()
            report
        }
        run.task.invokeOnCompletion {
            parent.complete()
            lock.withLock {
                if (active === run) {
                    active = null
                    if (epoch == generation) mutableReport.value = reports.value.copy(phase = SyncPhase.IDLE)
                    else if (eligible && mode == SyncExecutionMode.FOREGROUND) { armPoll(); if (dirty) launch() }
                }
            }
        }
        run.task.start()
        return run
    }

    private fun finish(run: Active, result: Result<SyncPassResult>, kind: RunKind): SyncReport = lock.withLock {
        if (active !== run) return@withLock reports.value
        active = null
        if (epoch != run.epoch) {
            if (eligible && mode == SyncExecutionMode.FOREGROUND) { armPoll(); if (dirty) launch() }
            return@withLock reports.value
        }
        consumedVersion = maxOf(consumedVersion, run.version)
        mutableReport.value = reports.value.copy(phase = SyncPhase.IDLE)
        if (kind == RunKind.RECOVERY) {
            result.fold({ mutableReport.value = reports.value.copy(blockingIssue = null) }, ::handle)
            publishScheduling()
            return@withLock reports.value
        }
        if (!eligible) return@withLock reports.value
        var completed: SyncReport? = null
        result.fold({ pass ->
            val success = !pass.rerun && pass.counts.fileErrors == 0 && pass.counts.pending == 0
            mutableReport.value = reports.value.copy(counts = pass.counts, details = pass.details, offline = false,
                retrying = false, lastSuccess = if (success) wallClock.now() else reports.value.lastSuccess)
            retry?.cancel()
            retry = null
            retryAtNanos = null
            if (success) retryCount = 0
            if (pass.rerun && !dirty) markDirty()
            if (dirty && mode == SyncExecutionMode.FOREGROUND) {
                if (immediateReruns >= Limits.syncImmediateRerunLimit) {
                    mutableReport.value = reports.value.copy(retrying = true)
                    scheduleRetry()
                } else { immediateReruns++; completed = reports.value; launch() }
            } else if (!dirty) immediateReruns = 0
        }, ::handle)
        publishScheduling()
        completed ?: reports.value
    }

    private fun handle(error: Throwable) {
        if (error is CancellationException || error is SyncHTTPClientError.Transport && error.error == HttpTransportError.Cancelled) return
        when (error) {
            SyncHTTPClientError.Unauthorized -> {
                mutableReport.value = reports.value.copy(needsSignIn = true)
                invalidateTimers()
                dirty = false
                retryAtNanos = null
            }
            is SyncHTTPClientError.RateLimited, is SyncHTTPClientError.ServerFailure -> {
                mutableReport.value = reports.value.copy(offline = true)
                scheduleRetry((error as? SyncHTTPClientError.RateLimited)?.retryAfter?.seconds?.times(1_000))
            }
            is SyncHTTPClientError.Transport -> {
                if (error.error == HttpTransportError.NetworkFailure || error.error == HttpTransportError.DeadlineExceeded) {
                    mutableReport.value = reports.value.copy(offline = true)
                    scheduleRetry()
                } else block(SyncBlockingIssue.INVALID_PROTOCOL)
            }
            is SyncPullCollectorError.NoProgress, SyncCoordinatorError.NoProgress -> {
                mutableReport.value = reports.value.copy(retrying = true)
                scheduleRetry()
            }
            is SyncCoordinatorError.FileErrors -> mutableReport.value = reports.value.copy(details = error.details,
                counts = reports.value.counts.copy(fileErrors = maxOf(1, error.details.size)))
            SyncCoordinatorError.RecoveryRequired, is SyncPushError, is LibraryError, is SyncFileOperationError -> block(SyncBlockingIssue.RECOVERY_REQUIRED)
            SyncReconciliationError.UnavailableLibrary, StoreError.InvalidRoot -> block(SyncBlockingIssue.ROOT_UNAVAILABLE)
            is SyncHTTPClientError, is SyncReconciliationError, is SyncConflictPolicyError -> block(SyncBlockingIssue.INVALID_PROTOCOL)
            is SyncPullCollectorError.StagingFailed -> block(SyncBlockingIssue.RECOVERY_REQUIRED)
            is SyncPullCollectorError -> block(SyncBlockingIssue.INVALID_PROTOCOL)
            else -> block(SyncBlockingIssue.INVALID_STATE)
        }
    }

    private fun block(issue: SyncBlockingIssue) {
        mutableReport.value = reports.value.copy(blockingIssue = issue)
        invalidateTimers()
    }
    private fun markDirty() { dirty = true; triggerVersion++ }
    private fun scheduleRetry(retryAfterMillis: Long? = null) {
        retryCount = (retryCount + 1).coerceAtMost(8)
        val delay = maxOf(SyncRetryPolicy.delayMillis(retryCount), retryAfterMillis ?: 0)
        retryAtNanos = monotonicClock.nowNanos() + delay * 1_000_000
        if (!dirty) markDirty()
        if (mode == SyncExecutionMode.FOREGROUND) armRetry()
    }
    private fun armRetry() {
        retry?.cancel()
        val at = retryAtNanos ?: return
        val generation = epoch
        retry = scope.launch {
            delay(((at - monotonicClock.nowNanos()).coerceAtLeast(0) + 999_999) / 1_000_000)
            val context = currentCoroutineContext()
            lock.withLock {
                if (!context.isActive || epoch != generation || !eligible || mode != SyncExecutionMode.FOREGROUND) return@withLock
                retryAtNanos = null
                immediateReruns = 0
                launch()
                publishScheduling()
            }
        }
    }
    private fun armPoll() {
        poll?.cancel()
        if (!eligible || mode != SyncExecutionMode.FOREGROUND) return
        val generation = epoch
        poll = scope.launch {
            while (true) {
                delay(Limits.syncIntervalMillis)
                val context = currentCoroutineContext()
                lock.withLock {
                    if (!context.isActive || epoch != generation || !eligible || mode != SyncExecutionMode.FOREGROUND) return@launch
                    markDirty()
                    if (active == null) immediateReruns = 0
                    launch()
                    publishScheduling()
                }
            }
        }
    }
    private fun invalidateTimers() { poll?.cancel(); debounce?.cancel(); retry?.cancel(); poll = null; debounce = null; retry = null }
    private fun stopWork(): SyncStopResult {
        invalidateTimers()
        epoch++
        val drained = active?.coordinator?.permit?.revoke() ?: true
        active?.parent?.cancel()
        active?.task?.cancel()
        dirty = false
        retryAtNanos = null
        mutableReport.value = reports.value.copy(phase = SyncPhase.IDLE)
        publishScheduling()
        return if (active != null || !drained) SyncStopResult.BUSY else recoveryState()
    }
    private fun recoveryState(): SyncStopResult = if (graph.journal.pending != null || graph.mutations.pendingPermit != null ||
        graph.mutations.hasUnreadableJournal || graph.pending.snapshot.let { it.error != null || it.value != null }) SyncStopResult.RECOVERY_REQUIRED
        else SyncStopResult.STOPPED
    private fun publishScheduling() {
        val due = retryAtNanos?.let { wallClock.now().plusNanos((it - monotonicClock.nowNanos()).coerceAtLeast(0)) }
        mutableScheduling.value = SyncSchedulingState(epoch, triggerVersion, consumedVersion, retryCount, due, reports.value.needsSignIn)
    }
    private fun sweepPullStaging() {
        var failure = false
        for (file in graph.files.listFiles().filter { it.relativePath.startsWith("sync/pull-") }) {
            try { graph.files.delete(file.relativePath) }
            catch (error: StoreError) { if (error != StoreError.NotFound) failure = true }
            catch (_: Throwable) { failure = true }
        }
        if (failure) throw SyncPullCollectorError.StagingFailed(StoreError.IOFailure)
    }

    private companion object {
        fun makeGraph(library: LibraryService, operations: SyncFileOperations, files: StateStore, dataOperations: SyncFileOperations,
                      states: SyncStateStore, accounts: SyncAccountStore): SyncEngineGraph {
            val mutations = SyncLibraryMutations(library, operations)
            return SyncEngineGraph(files, states, accounts, mutations, SyncApplyJournal(files, dataOperations, mutations, states, accounts),
                SyncPendingOperationStore(files, dataOperations))
        }
    }
}

internal object SyncRetryPolicy {
    fun delayMillis(failureCount: Int): Long = minOf(Limits.syncBackoffMinMillis * (1L shl (failureCount - 1).coerceIn(0, 7)),
        Limits.syncBackoffMaxMillis)
}
