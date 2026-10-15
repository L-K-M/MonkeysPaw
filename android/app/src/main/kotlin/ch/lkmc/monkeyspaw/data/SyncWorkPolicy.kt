package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.services.SyncAccountIssue
import ch.lkmc.monkeyspaw.core.services.SyncAccountServiceError
import ch.lkmc.monkeyspaw.core.sync.SyncHTTPClientError
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

internal enum class SyncWorkReason { NONE, SYNC, SAVE, RETRY }
internal enum class SyncForegroundOwner { LIBRARY, ACCOUNT }

/** Only local references, counters and wall times. No server, path or credential belongs here. */
internal data class SyncWorkState(
    val generation: String = UUID.randomUUID().toString(),
    val connection: String? = null,
    val trigger: Long = 0,
    val consumed: Long = 0,
    val reason: SyncWorkReason = SyncWorkReason.NONE,
    val dueAt: Long = 0,
    val retries: Int = 0,
    val needsSignIn: Boolean = false,
) {
    val pending get() = trigger > consumed
}

internal interface SyncWorkStore {
    fun read(): SyncWorkState
    fun write(value: SyncWorkState)
}

internal data class SyncWorkRequest(val generation: String, val version: Long? = null,
    val delayMillis: Long = 0, val expedited: Boolean = false)

internal interface SyncWorkQueue {
    suspend fun periodic(generation: String, intervalMillis: Long)
    suspend fun once(request: SyncWorkRequest)
    suspend fun cancel(generation: String)
}

internal data class SyncWorkFacts(val scheduling: SyncSchedulingState, val report: SyncReport)

internal interface SyncWorkSession {
    suspend fun connection(): String?
    suspend fun resume()
    suspend fun requireSignIn()
    suspend fun mode(value: SyncExecutionMode)
    suspend fun restoreEligibility(retries: Int, dueAt: Long) {}
    fun facts(): SyncWorkFacts?
    suspend fun run(epoch: Long, version: Long?)
}

/** WorkManager dispatches background work; the existing engine alone owns foreground timers.
 * One durable trigger is shared with the live engine's epoch/version, then remapped on resume.
 */
internal class SyncWorkPolicy(
    private val store: SyncWorkStore,
    private val queue: SyncWorkQueue,
    private val session: SyncWorkSession,
    private val now: () -> Long,
    private val apiLevel: Int,
) {
    private val mutex = Mutex()
    private val foreground = mutableMapOf<SyncForegroundOwner, Long>()
    private var admissionVersion = 0L
    private var running: String? = null
    private var queued = false
    private var periodicGeneration: String? = null
    private var observed: Pair<Long, Long>? = null
    private var mappedVersion = 0L

    suspend fun authenticated(connection: String) = mutex.withLock {
        val old = store.read()
        val state = SyncWorkState(connection = connection, trigger = 1, reason = SyncWorkReason.SYNC, dueAt = now())
        store.write(state)
        queued = false
        periodicGeneration = null
        observed = null
        mappedVersion = 0
        queue.cancel(old.generation)
        reconcile(state)
    }

    /** Publish invalidation before canceling jobs or beginning credential cleanup. */
    suspend fun signedOut() = mutex.withLock { disable(store.read()) }

    suspend fun authenticationStopped(): Boolean = mutex.withLock {
        val state = store.read()
        val connection = session.connection()
        state.needsSignIn && (connection == null || state.connection == connection)
    }

    suspend fun enter(owner: SyncForegroundOwner) {
        val (entry, admission) = mutex.withLock {
            val connection = session.connection()
            var state = store.read()
            if (connection == null) {
                if (state.needsSignIn) session.requireSignIn() else disable(state)
                return
            }
            if (state.connection != connection) {
                val old = state
                state = SyncWorkState(connection = connection, trigger = 1, reason = SyncWorkReason.SYNC, dueAt = now())
                store.write(state)
                queued = false
                observed = null
                mappedVersion = 0
                queue.cancel(old.generation)
            }
            val admission = ++admissionVersion
            foreground[owner] = admission
            state to admission
        }
        try {
            mutex.withLock {
                if (foreground[owner] != admission) return
                reconcile(store.read())
            }
            if (entry.needsSignIn) { session.requireSignIn(); return }
            session.resume()
            mutex.withLock {
                // A leaving screen or newer entry owns the mode after a suspended credential resume.
                if (foreground[owner] != admission || store.read().generation != entry.generation) return
                if (entry.pending) session.restoreEligibility(entry.retries, entry.dueAt)
                session.mode(SyncExecutionMode.FOREGROUND)
            }
            changed()
        } catch (error: Throwable) {
            withContext(NonCancellable) {
                mutex.withLock {
                    if (foreground[owner] == admission) {
                        foreground.remove(owner)
                        if (foreground.isEmpty()) {
                            runCatching { session.mode(SyncExecutionMode.BACKGROUND) }
                            runCatching { reconcile(store.read()) }
                        }
                    }
                }
            }
            throw error
        }
    }

    suspend fun leave(owner: SyncForegroundOwner): Unit = mutex.withLock {
        if (foreground.remove(owner) == null || foreground.isNotEmpty()) return
        session.mode(SyncExecutionMode.BACKGROUND)
        reconcile(store.read())
    }

    /** Called before forwarding a committed USER event to the engine. */
    suspend fun saved(): Unit = mutex.withLock {
        val state = store.read()
        if (state.connection == null || state.needsSignIn) return
        val next = state.copy(trigger = state.trigger + 1, reason = SyncWorkReason.SAVE,
            dueAt = maxOf(now() + Limits.syncDebounceMillis, if (state.retries > 0) state.dueAt else 0))
        store.write(next)
        // The engine's debounce publishes the ready trigger in foreground. Background has no timer.
        if (foreground.isEmpty()) reconcile(next)
    }

    suspend fun changed(): Unit = mutex.withLock {
        val before = store.read()
        val facts = session.facts() ?: return
        if (before.connection == null || before.connection != session.connection()) return
        if (facts.report.needsSignIn || facts.scheduling.needsSignIn) { stopAuthentication(before); return }
        if (before.needsSignIn || running != null || !facts.report.enabled || facts.report.blockingIssue != null) return
        val state = observeEngine(before, facts)
        if (state != before) store.write(state)
        // Expediting is legal only AFTER the existing foreground debounce, with no initial delay.
        reconcile(state, readySave = foreground.isNotEmpty() && state.reason == SyncWorkReason.SAVE && state.dueAt <= now())
    }

    private fun observeEngine(before: SyncWorkState, facts: SyncWorkFacts): SyncWorkState {
        var state = before
        val scheduling = facts.scheduling
        val key = scheduling.epoch to scheduling.triggerVersion
        if (observed != key) {
            observed = key
            if (scheduling.triggerVersion > scheduling.consumedVersion) {
                if (!state.pending) state = state.copy(trigger = state.trigger + 1, reason = SyncWorkReason.SYNC, dueAt = now())
                mappedVersion = state.trigger
                scheduling.nextEligibleAt?.let { due ->
                    val retries = maxOf(state.retries, scheduling.retryCount)
                    state = state.copy(reason = if (retries > 0) SyncWorkReason.RETRY else state.reason,
                        retries = retries, dueAt = maxOf(state.dueAt,
                            if (retries > 0) retryDue(retries, due.toEpochMilli()) else due.toEpochMilli()))
                }
            } else if (state.pending && (state.reason != SyncWorkReason.SAVE || state.dueAt <= now())) {
                // StateFlow may conflate the ready trigger and its fast completion.
                mappedVersion = state.trigger
            }
        }
        if (scheduling.consumedVersion >= scheduling.triggerVersion && mappedVersion > state.consumed) {
            state = state.copy(consumed = mappedVersion)
            if (!state.pending) state = state.copy(reason = SyncWorkReason.NONE, retries = 0, dueAt = now() + Limits.syncIntervalMillis)
        }
        return state
    }

    /** A worker completes dispatch, never claims that an offline/partial pass succeeded. */
    suspend fun dispatch(request: SyncWorkRequest) {
        val claim = mutex.withLock {
            var state = store.read()
            if (request.generation != state.generation || state.connection == null) return
            queued = false
            if (state.needsSignIn) { session.requireSignIn(); return }
            if (state.connection != session.connection()) { disable(state); return }
            if (running != null || foreground.isNotEmpty()) return
            session.facts()?.let { facts ->
                if (facts.report.enabled && !facts.report.needsSignIn && facts.report.blockingIssue == null) {
                    val updated = observeEngine(state, facts)
                    if (updated != state) { store.write(updated); state = updated }
                }
            }
            if (request.version != null && request.version <= state.consumed) { reconcile(state); return }
            if (state.dueAt > now()) { reconcile(state); return }
            if (!state.pending) {
                state = state.copy(trigger = state.trigger + 1, reason = SyncWorkReason.SYNC)
                store.write(state)
            }
            running = state.generation
            state
        }
        var completed = false
        var resumeFailure = false
        var retryAfter = 0L
        try {
            session.resume()
            val admitted = mutex.withLock {
                val state = store.read()
                state.generation == claim.generation && !state.needsSignIn && state.connection == session.connection()
            }
            if (!admitted) return
            val facts = session.facts()
            if (facts != null && facts.report.enabled && facts.report.blockingIssue == null && !facts.report.needsSignIn) {
                val scheduling = facts.scheduling
                // Due periodic scans and missed source events need a fresh explicit engine trigger.
                session.run(scheduling.epoch, scheduling.triggerVersion.takeIf { it > scheduling.consumedVersion })
            }
            completed = true
        } catch (error: SyncAccountServiceError) {
            val http = (error.issue as? SyncAccountIssue.Http)?.error
            if (http is SyncHTTPClientError.RateLimited || http is SyncHTTPClientError.ServerFailure ||
                (http is SyncHTTPClientError.Transport && http.error in setOf(HttpTransportError.NetworkFailure, HttpTransportError.DeadlineExceeded))) {
                resumeFailure = true
                retryAfter = (http as? SyncHTTPClientError.RateLimited)?.retryAfter?.seconds?.times(1_000) ?: 0
            } else throw error
        } finally {
            withContext(NonCancellable) {
                mutex.withLock {
                    running = null
                    var state = store.read()
                    if (state.generation != claim.generation || state.connection == null) { reconcile(state); return@withLock }
                    val facts = session.facts()
                    if (state.needsSignIn || facts?.report?.needsSignIn == true) { stopAuthentication(state); return@withLock }
                    if (resumeFailure) {
                        val retries = (claim.retries + 1).coerceAtMost(MAX_RETRIES)
                        state = state.copy(reason = SyncWorkReason.RETRY, retries = retries,
                            dueAt = retryDue(retries, now() + retryAfter))
                    } else if (completed && facts?.report?.enabled == true && facts.report.blockingIssue == null) {
                        state = state.copy(consumed = maxOf(state.consumed, claim.trigger))
                        if (facts.report.offline || facts.report.retrying) {
                            val retries = (claim.retries + 1).coerceAtMost(MAX_RETRIES)
                            state = state.copy(trigger = maxOf(state.trigger, state.consumed + 1), reason = SyncWorkReason.RETRY,
                                retries = retries, dueAt = retryDue(retries, facts.scheduling.nextEligibleAt?.toEpochMilli() ?: 0))
                        } else if (!state.pending && facts.scheduling.triggerVersion > facts.scheduling.consumedVersion) {
                            val retries = (claim.retries + 1).coerceAtMost(MAX_RETRIES)
                            state = state.copy(trigger = state.trigger + 1, reason = SyncWorkReason.RETRY,
                                retries = retries, dueAt = retryDue(retries, 0))
                        } else if (!state.pending) state = state.copy(reason = SyncWorkReason.NONE, retries = 0,
                            dueAt = now() + Limits.syncIntervalMillis)
                        observed = facts.scheduling.epoch to facts.scheduling.triggerVersion
                        mappedVersion = if (facts.scheduling.triggerVersion > facts.scheduling.consumedVersion) state.trigger else claim.trigger
                    } else state = state.copy(dueAt = maxOf(state.dueAt, now() + MIN_RETRY_MILLIS))
                    store.write(state)
                    // APPEND_OR_REPLACE queues a successor, never replaces this running pass.
                    if (facts?.report?.blockingIssue == null) reconcile(state)
                }
            }
        }
    }

    private suspend fun stopAuthentication(state: SyncWorkState) {
        store.write(state.copy(needsSignIn = true))
        queued = false
        periodicGeneration = null
        queue.cancel(state.generation)
    }

    private suspend fun disable(state: SyncWorkState) {
        if (state.connection == null) return
        store.write(SyncWorkState())
        queued = false
        periodicGeneration = null
        observed = null
        mappedVersion = 0
        queue.cancel(state.generation)
    }

    private suspend fun reconcile(state: SyncWorkState, readySave: Boolean = false) {
        if (state.connection == null || state.needsSignIn) return
        if (periodicGeneration != state.generation) {
            queue.periodic(state.generation, PERIOD_MILLIS)
            periodicGeneration = state.generation
        }
        if (!state.pending || queued || running != null || foreground.isNotEmpty() && !readySave) return
        val delay = (state.dueAt - now()).coerceAtLeast(0)
        queue.once(SyncWorkRequest(state.generation, state.trigger, delay, readySave && delay == 0L && apiLevel >= 31))
        queued = true
    }

    private fun retryDue(retries: Int, engineDue: Long): Long {
        val delay = minOf(Limits.syncBackoffMinMillis * (1L shl (retries - 1).coerceIn(0, MAX_RETRIES - 1)), Limits.syncBackoffMaxMillis)
        val floor = if (foreground.isEmpty()) maxOf(MIN_RETRY_MILLIS, delay) else delay
        return maxOf(now() + floor, engineDue)
    }

    companion object {
        const val PERIOD_MILLIS = 15 * 60 * 1_000L
        const val MIN_RETRY_MILLIS = 10_000L
        const val MAX_RETRIES = 8
    }
}
