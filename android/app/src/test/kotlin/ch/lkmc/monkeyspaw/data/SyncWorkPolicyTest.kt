@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.SyncAccountServiceError
import ch.lkmc.monkeyspaw.core.services.SyncAccountIssue
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.sync.SyncHTTPClientError
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.time.Instant
import java.util.UUID
import kotlin.test.*

internal class SyncWorkPolicyTest {
    private class Store : SyncWorkStore {
        var value = SyncWorkState()
        val writes = mutableListOf<SyncWorkState>()
        override fun read() = value
        override fun write(value: SyncWorkState) { this.value = value; writes.add(value) }
    }
    private class Queue : SyncWorkQueue {
        val periodic = linkedMapOf<String, Long>()
        val requests = mutableListOf<SyncWorkRequest>()
        val cancellations = mutableListOf<String>()
        var onOnce: suspend (SyncWorkRequest) -> Unit = {}
        var onPeriodic: suspend () -> Unit = {}
        override suspend fun periodic(generation: String, intervalMillis: Long) { onPeriodic(); periodic.putIfAbsent(generation, intervalMillis) }
        override suspend fun once(request: SyncWorkRequest) { onOnce(request); requests.add(request) }
        override suspend fun cancel(generation: String) { cancellations.add(generation); periodic.remove(generation) }
    }
    private class Session : SyncWorkSession {
        var connection = UUID.randomUUID().toString()
        var connected = true
        var connectionReads = 0
        var resumes = 0
        var runs = 0
        var stops = 0
        var epoch = 1L
        var trigger = 1L
        var consumed = 0L
        var retries = 0
        var due: Long? = null
        var enabled = true
        var needsSignIn = false
        var offline = false
        var blocking: SyncBlockingIssue? = null
        val modes = mutableListOf<SyncExecutionMode>()
        var onRun: suspend () -> Unit = {}
        var onResume: suspend () -> Unit = {}
        var onStop: suspend () -> Unit = {}
        override suspend fun connection(): String? { connectionReads++; return connection.takeIf { connected } }
        override suspend fun resume() { resumes++; onResume() }
        override suspend fun requireSignIn() { stops++; enabled = false; needsSignIn = true; onStop() }
        override suspend fun mode(value: SyncExecutionMode) { modes.add(value) }
        override fun facts() = SyncWorkFacts(SyncSchedulingState(epoch, trigger, consumed, retries,
            due?.let(Instant::ofEpochMilli), needsSignIn), SyncReport(enabled = enabled, needsSignIn = needsSignIn,
            offline = offline, blockingIssue = blocking))
        override suspend fun run(epoch: Long, version: Long?) {
            assertEquals(this.epoch, epoch)
            val admitted = version ?: ++trigger
            assertEquals(trigger, admitted)
            runs++
            onRun()
            consumed = admitted
            if (offline) trigger++
        }
    }
    private class Rig(val store: Store = Store(), val api: Int = 31) {
        val queue = Queue()
        val session = Session()
        var time = 1_000_000L
        val policy = SyncWorkPolicy(store, queue, session, { time }, api)
        suspend fun authenticate() { policy.authenticated(session.connection) }
        suspend fun initial() { authenticate(); policy.dispatch(queue.requests.last()) }
        fun reconstruct(): Rig = Rig(store, api).also { it.time = time; it.session.connection = session.connection }
    }

    @Test fun `construction is inert and old work performs no metadata secret or network admission`() = runTest {
        val r = Rig()
        assertTrue(r.queue.requests.isEmpty())
        assertTrue(r.store.writes.isEmpty())
        r.policy.dispatch(SyncWorkRequest(UUID.randomUUID().toString(), 1))
        assertEquals(0, r.session.connectionReads)
        assertEquals(0, r.session.resumes)
        assertEquals(0, r.session.runs)
    }

    @Test fun `signed-in work registers exactly one unique fifteen minute periodic job`() = runTest {
        val r = Rig()
        r.authenticate()
        repeat(5) { r.policy.changed() }
        assertEquals(mapOf(r.store.value.generation to 900_000L), r.queue.periodic)
        assertEquals(1, r.queue.requests.size)
        assertFalse(r.queue.requests.single().expedited)
    }

    @Test fun `background saves coalesce and an early request respects the latest durable debounce`() = runTest {
        val r = Rig()
        r.initial()
        r.session.trigger++
        r.policy.saved()
        val work = r.queue.requests.last()
        assertEquals(3_000, work.delayMillis)
        assertFalse(work.expedited)
        r.time += 1_000
        r.policy.saved()
        assertEquals(2, r.queue.requests.size)
        r.time += 2_000
        r.policy.dispatch(work)
        assertEquals(1, r.session.runs)
        assertEquals(1_000, r.queue.requests.last().delayMillis)
        r.time += 1_000
        r.policy.dispatch(r.queue.requests.last())
        assertEquals(2, r.session.runs)
        assertFalse(r.store.value.pending)
    }

    @Test fun `foreground debounce uses engine notification then API31 expedite with no delay`() = runTest {
        for (api in listOf(26, 30, 31, 37)) {
            val r = Rig(api = api)
            r.initial()
            r.policy.enter(SyncForegroundOwner.LIBRARY)
            r.policy.saved()
            r.policy.saved()
            assertEquals(1, r.queue.requests.size)
            r.time += 3_000
            r.session.trigger++
            r.policy.changed()
            assertEquals(2, r.queue.requests.size)
            assertEquals(0, r.queue.requests.last().delayMillis)
            assertEquals(api >= 31, r.queue.requests.last().expedited)
        }
    }

    @Test fun `leaving foreground during debounce enqueues ordinary remaining delay`() = runTest {
        val r = Rig()
        r.initial()
        r.policy.enter(SyncForegroundOwner.LIBRARY)
        r.policy.saved()
        r.time += 1_000
        r.policy.leave(SyncForegroundOwner.LIBRARY)
        assertEquals(2_000, r.queue.requests.last().delayMillis)
        assertFalse(r.queue.requests.last().expedited)
        assertEquals(SyncExecutionMode.BACKGROUND, r.session.modes.last())
    }

    @Test fun `worker and foreground consume the same trigger with no second pass`() = runTest {
        val r = Rig()
        r.authenticate()
        val request = r.queue.requests.last()
        r.policy.enter(SyncForegroundOwner.LIBRARY)
        r.policy.dispatch(request)
        assertEquals(0, r.session.runs)
        r.session.consumed = r.session.trigger
        r.policy.changed()
        r.policy.leave(SyncForegroundOwner.LIBRARY)
        r.policy.dispatch(request)
        assertEquals(0, r.session.runs)
        assertFalse(r.store.value.pending)
    }

    @Test fun `overlapping foreground owners do not turn off the engine until the last leaves`() = runTest {
        val r = Rig()
        r.initial()
        r.policy.enter(SyncForegroundOwner.LIBRARY)
        r.policy.enter(SyncForegroundOwner.ACCOUNT)
        r.policy.leave(SyncForegroundOwner.LIBRARY)
        assertFalse(r.session.modes.contains(SyncExecutionMode.BACKGROUND))
        r.policy.leave(SyncForegroundOwner.ACCOUNT)
        assertEquals(1, r.session.modes.count { it == SyncExecutionMode.BACKGROUND })
    }

    @Test fun `background policy creates no foreground timer or mode even after time advances`() = runTest {
        val r = Rig()
        r.initial()
        r.time += 60_000
        advanceTimeBy(3_600_000)
        assertEquals(1, r.session.runs)
        assertTrue(r.session.modes.isEmpty())
    }

    @Test fun `periodic admission scans again after the previous engine trigger was consumed`() = runTest {
        val r = Rig()
        r.initial()
        r.time += 900_000
        r.policy.dispatch(SyncWorkRequest(r.store.value.generation))
        assertEquals(2, r.session.runs)
        assertFalse(r.store.value.pending)
    }

    @Test fun `retry count and wall due survive every reconstruction with ten to six hundred second cap`() = runTest {
        var r = Rig()
        r.authenticate()
        for (expected in listOf(10_000L, 10_000, 20_000, 40_000, 80_000, 160_000, 320_000, 600_000, 600_000)) {
            r.session.onRun = {
                r.session.offline = true
                r.session.retries = 1 // A reconstructed engine starts its own retry counter over.
                r.session.due = r.time + 5_000
            }
            val generation = r.store.value.generation
            r.policy.dispatch(SyncWorkRequest(generation))
            assertEquals(expected, r.store.value.dueAt - r.time)
            assertEquals(expected, r.queue.requests.last().delayMillis)
            assertTrue(r.store.value.pending)
            val next = r.reconstruct()
            assertEquals(r.store.value, next.store.read())
            next.time = r.store.value.dueAt
            r = next
        }
        assertEquals(8, r.store.value.retries)
    }

    @Test fun `Retry After extends the cap and early workers cannot read credentials`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.offline = true
        r.session.due = r.time + 3_600_000
        r.policy.dispatch(r.queue.requests.last())
        assertEquals(3_600_000, r.queue.requests.last().delayMillis)
        val reopened = r.reconstruct()
        reopened.policy.dispatch(SyncWorkRequest(r.store.value.generation))
        assertEquals(0, reopened.session.resumes)
        assertEquals(0, reopened.session.runs)
    }

    @Test fun `credential resume network failures use the persisted capped retry policy`() = runTest {
        var r = Rig()
        r.authenticate()
        for (expected in listOf(10_000L, 10_000, 20_000, 40_000)) {
            r.session.enabled = false
            r.session.onResume = { throw SyncAccountServiceError(SyncAccountIssue.Http(
                SyncHTTPClientError.Transport(HttpTransportError.NetworkFailure))) }
            r.policy.dispatch(SyncWorkRequest(r.store.value.generation))
            assertEquals(expected, r.store.value.dueAt - r.time)
            val next = r.reconstruct()
            next.time = r.store.value.dueAt
            r = next
        }
        assertEquals(4, r.store.value.retries)
    }

    @Test fun `save while completion enqueues one successor without replacing the running pass`() = runTest {
        val r = Rig()
        r.authenticate()
        val request = r.queue.requests.single()
        r.session.onRun = {
            r.policy.saved()
            r.policy.saved()
            assertEquals(1, r.queue.requests.size)
        }
        r.policy.dispatch(request)
        assertTrue(r.store.value.pending)
        assertEquals(2, r.queue.requests.size)
        assertEquals(3_000, r.queue.requests.last().delayMillis)
        assertEquals(listOf(r.store.writes.first().generation).size, r.queue.cancellations.size)
        r.session.onRun = {}
        r.session.trigger++
        r.time += 3_000
        r.policy.dispatch(r.queue.requests.last())
        assertFalse(r.store.value.pending)
        assertEquals(2, r.session.runs)
    }

    @Test fun `successor is persisted before enqueue and a lost enqueue recovers at authorized entry`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.onRun = { r.policy.saved() }
        r.queue.onOnce = { error("Synthetic enqueue failure") }
        assertFailsWith<IllegalStateException> { r.policy.dispatch(r.queue.requests.first()) }
        assertTrue(r.store.value.pending)
        val reopened = r.reconstruct()
        reopened.policy.enter(SyncForegroundOwner.LIBRARY)
        reopened.policy.leave(SyncForegroundOwner.LIBRARY)
        assertEquals(1, reopened.queue.requests.size)
    }

    @Test fun `cancellation propagates to the pass retains durable intent and schedules an ordinary successor`() = runTest {
        val r = Rig()
        r.authenticate()
        val entered = CompletableDeferred<Unit>()
        var canceled = false
        r.session.onRun = { try { entered.complete(Unit); awaitCancellation() } finally { canceled = true } }
        val worker = launch { r.policy.dispatch(r.queue.requests.single()) }
        entered.await()
        worker.cancelAndJoin()
        assertTrue(canceled)
        assertTrue(r.store.value.pending)
        assertEquals(0, r.store.value.consumed)
        assertEquals(10_000, r.queue.requests.last().delayMillis)
        assertFalse(r.queue.requests.last().expedited)
    }

    @Test fun `two worker deliveries admit only one background pass`() = runTest {
        val r = Rig()
        r.authenticate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        r.session.onRun = { entered.complete(Unit); release.await() }
        val worker = launch { r.policy.dispatch(r.queue.requests.single()) }
        entered.await()
        r.policy.dispatch(SyncWorkRequest(r.store.value.generation))
        assertEquals(1, r.session.runs)
        release.complete(Unit)
        worker.join()
        r.policy.dispatch(r.queue.requests.first())
        assertEquals(1, r.session.runs)
    }

    @Test fun `401 survives process reconstruction and all entries stay stopped until reauthentication`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.onRun = { r.session.needsSignIn = true }
        r.policy.dispatch(r.queue.requests.single())
        assertTrue(r.store.value.needsSignIn)
        assertTrue(r.queue.cancellations.contains(r.store.value.generation))
        val reopened = r.reconstruct()
        assertTrue(reopened.policy.authenticationStopped())
        reopened.policy.dispatch(SyncWorkRequest(r.store.value.generation))
        reopened.policy.enter(SyncForegroundOwner.ACCOUNT)
        reopened.policy.saved()
        assertEquals(0, reopened.session.resumes)
        assertEquals(0, reopened.session.runs)
        assertTrue(reopened.queue.requests.isEmpty())
        reopened.session.needsSignIn = false
        reopened.session.enabled = true
        reopened.session.connection = UUID.randomUUID().toString()
        reopened.policy.authenticated(reopened.session.connection)
        assertFalse(reopened.store.value.needsSignIn)
    }

    @Test fun `foreground 401 publication persists even without any OS worker`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.needsSignIn = true
        r.policy.changed()
        assertTrue(r.reconstruct().policy.authenticationStopped())
    }

    @Test fun `stopped Account entry releases admission so login queues runnable work without reentry`() = runTest {
        val original = Rig()
        original.authenticate()
        original.session.needsSignIn = true
        original.policy.changed()
        val r = original.reconstruct()
        r.policy.enter(SyncForegroundOwner.ACCOUNT)
        assertTrue(r.session.modes.isEmpty())
        r.session.needsSignIn = false
        r.session.enabled = true
        r.session.connection = UUID.randomUUID().toString()
        r.authenticate()
        assertFalse(r.store.value.needsSignIn)
        assertTrue(r.store.value.pending)
        assertEquals(1, r.queue.requests.size)
        r.policy.dispatch(r.queue.requests.single())
        assertEquals(1, r.session.runs)
        assertFalse(r.store.value.pending)
        r.policy.leave(SyncForegroundOwner.ACCOUNT)
        assertTrue(r.session.modes.isEmpty(), "Paired leave of rejected admission is safe")
    }

    @Test fun `stopped Account entry preserves a different foreground owner`() = runTest {
        val r = Rig()
        r.initial()
        r.policy.enter(SyncForegroundOwner.LIBRARY)
        r.session.needsSignIn = true
        r.policy.changed()
        r.policy.enter(SyncForegroundOwner.ACCOUNT)
        r.session.needsSignIn = false
        r.session.enabled = true
        r.authenticate()
        r.policy.leave(SyncForegroundOwner.ACCOUNT)
        assertEquals(listOf(SyncExecutionMode.FOREGROUND), r.session.modes)
        assertEquals(1, r.queue.requests.size)
        r.policy.leave(SyncForegroundOwner.LIBRARY)
        assertEquals(SyncExecutionMode.BACKGROUND, r.session.modes.last())
        assertEquals(2, r.queue.requests.size)
    }

    @Test fun `suspended rejected entry cannot release a newer admission for the same owner`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.needsSignIn = true
        r.policy.changed()
        val stopped = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        r.session.onStop = { stopped.complete(Unit); release.await() }
        val old = launch { r.policy.enter(SyncForegroundOwner.ACCOUNT) }
        stopped.await()
        r.policy.leave(SyncForegroundOwner.ACCOUNT)
        r.session.needsSignIn = false
        r.session.enabled = true
        r.authenticate()
        r.policy.enter(SyncForegroundOwner.ACCOUNT)
        release.complete(Unit)
        old.join()
        r.policy.leave(SyncForegroundOwner.ACCOUNT)
        assertEquals(listOf(SyncExecutionMode.BACKGROUND, SyncExecutionMode.FOREGROUND, SyncExecutionMode.BACKGROUND), r.session.modes)
    }

    @Test fun `an inactive connection after failed activation cannot clear a persisted 401`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.needsSignIn = true
        r.policy.changed()
        val generation = r.store.value.generation
        r.session.connected = false
        r.policy.enter(SyncForegroundOwner.ACCOUNT)
        assertTrue(r.store.value.needsSignIn)
        assertEquals(generation, r.store.value.generation)
        assertEquals(0, r.session.resumes)
    }

    @Test fun `sign out changes generation before cancel and old jobs are no ops after new login`() = runTest {
        val r = Rig()
        r.authenticate()
        val old = r.queue.requests.single()
        r.policy.signedOut()
        assertNull(r.store.value.connection)
        assertNotEquals(old.generation, r.store.value.generation)
        r.policy.dispatch(old)
        assertEquals(0, r.session.resumes)
        r.authenticate()
        r.policy.dispatch(old)
        assertEquals(0, r.session.resumes)
    }

    @Test fun `late completion cannot consume a replacement generation`() = runTest {
        val r = Rig()
        r.authenticate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        r.session.onRun = { entered.complete(Unit); release.await() }
        val old = launch { r.policy.dispatch(r.queue.requests.single()) }
        entered.await()
        r.policy.signedOut()
        r.session.connection = UUID.randomUUID().toString()
        r.authenticate()
        val expected = r.store.value
        release.complete(Unit)
        old.join()
        assertEquals(expected, r.store.value)
    }

    @Test fun `inactive or mismatched connection refuses even a due current-generation job`() = runTest {
        for (signedOut in listOf(false, true)) {
            val r = Rig()
            r.authenticate()
            if (signedOut) r.session.connected = false else r.session.connection = UUID.randomUUID().toString()
            r.policy.dispatch(r.queue.requests.single())
            assertEquals(0, r.session.resumes)
            assertNull(r.store.value.connection)
        }
    }

    @Test fun `blocking engine report is retained without claiming or retrying sync success`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.blocking = SyncBlockingIssue.RECOVERY_REQUIRED
        r.policy.dispatch(r.queue.requests.single())
        assertEquals(0, r.session.runs)
        assertTrue(r.store.value.pending)
        assertEquals(SyncBlockingIssue.RECOVERY_REQUIRED, r.session.facts().report.blockingIssue)
    }

    @Test fun `completed reauthentication cannot reuse the previous native version mapping`() = runTest {
        val r = Rig()
        r.authenticate()
        r.policy.enter(SyncForegroundOwner.LIBRARY)
        repeat(4) {
            r.policy.saved()
            r.session.trigger++
            r.policy.changed()
            r.session.consumed = r.session.trigger
            r.policy.changed()
        }
        assertTrue(r.store.value.consumed > 1)
        r.session.connection = UUID.randomUUID().toString()
        r.session.epoch++
        r.session.trigger++
        r.session.consumed = r.session.trigger // A fast foreground activation completed before its auth hook.
        r.policy.authenticated(r.session.connection)
        r.policy.changed()
        assertTrue(r.store.value.consumed <= r.store.value.trigger)
    }

    @Test fun `a fast foreground pass consumed before observation needs no second worker pass`() = runTest {
        val r = Rig()
        r.initial()
        r.policy.enter(SyncForegroundOwner.LIBRARY)
        r.policy.saved()
        r.time += 3_000
        r.session.trigger++
        r.session.consumed = r.session.trigger
        r.policy.changed()
        assertFalse(r.store.value.pending)
        r.policy.leave(SyncForegroundOwner.LIBRARY)
        assertEquals(1, r.queue.requests.size)
        assertEquals(1, r.session.runs)
    }

    @Test fun `failed foreground admission cannot suppress subsequent OS dispatch`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.onResume = { throw SyncAccountServiceError(SyncAccountIssue.Http(
            SyncHTTPClientError.Transport(HttpTransportError.NetworkFailure))) }
        assertFailsWith<SyncAccountServiceError> { r.policy.enter(SyncForegroundOwner.LIBRARY) }
        r.session.onResume = {}
        r.policy.dispatch(r.queue.requests.last())
        assertEquals(1, r.session.runs)
    }

    @Test fun `leaving while foreground entry is suspended cannot rearm foreground timers`() = runTest {
        val r = Rig()
        r.authenticate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        r.session.onResume = { entered.complete(Unit); release.await() }
        val entry = launch { r.policy.enter(SyncForegroundOwner.LIBRARY) }
        entered.await()
        r.policy.leave(SyncForegroundOwner.LIBRARY)
        release.complete(Unit)
        entry.join()
        assertEquals(SyncExecutionMode.BACKGROUND, r.session.modes.last())
        assertEquals(0, r.session.modes.count { it == SyncExecutionMode.FOREGROUND })
    }

    @Test fun `failed OS registration during foreground entry releases its owner`() = runTest {
        val original = Rig()
        original.authenticate()
        val r = original.reconstruct()
        r.queue.onPeriodic = { error("Synthetic registration failure") }
        assertFailsWith<IllegalStateException> { r.policy.enter(SyncForegroundOwner.LIBRARY) }
        r.queue.onPeriodic = {}
        r.policy.dispatch(SyncWorkRequest(r.store.value.generation, r.store.value.trigger))
        assertEquals(1, r.session.runs)
    }

    @Test fun `engine requested background reruns back off instead of creating an immediate dispatch loop`() = runTest {
        val r = Rig()
        r.authenticate()
        r.session.onRun = { r.session.trigger++ }
        repeat(4) {
            r.policy.dispatch(r.queue.requests.last())
            if (it > 0) assertTrue(r.queue.requests.last().delayMillis >= 10_000)
            r.time = r.store.value.dueAt
        }
        assertTrue(r.store.value.pending)
        assertTrue(r.store.value.retries > 0)
    }
}
