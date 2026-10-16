@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

internal class EngineHarness(val scheduler: TestCoroutineScheduler, scope: CoroutineScope,
                             val rig: SyncJournalHarness = SyncJournalHarness(seed = false)) {
    val binding get() = rig.binding
    val files get() = rig.local.prompts
    val data get() = rig.local.state
    val states get() = rig.states
    val accounts get() = rig.accounts
    val pending = SyncPendingOperationStore(data, rig.dataOperations)
    val graph = SyncEngineGraph(data, states, accounts, rig.mutations, rig.journal, pending)
    val remote = linkedMapOf<String, Prompt>()
    val groups = linkedMapOf<ULID, SyncGroupState>()
    val requests = mutableListOf<HttpRequest>()
    var respond: (suspend (HttpRequest) -> HttpResponse?)? = null
    var sequence = 0L
    private var entropy = 0
    private val clock = MonotonicClock { scheduler.currentTime * 1_000_000 }
    private val wall = Clock { Instant.parse("2026-10-14T12:00:00Z").plusMillis(scheduler.currentTime) }
    val transport = HttpTransport { request ->
        requests.add(request)
        respond?.invoke(request) ?: response(request)
    }
    val server = SyncServerURL(binding.account.serverURL)
    val client = SyncHTTPClient(server, transport, SyncCredential(server, SecretValue("A".repeat(43))), clock)
    val engine = SyncEngine(graph, scope, StandardTestDispatcher(scheduler), wall,
        { ULID.generate(wall.now(), ByteArray(10).also { it[8] = (entropy shr 8).toByte(); it[9] = (++entropy).toByte() }) }, clock)
    val state get() = states.load(binding)!!
    val pulls get() = requests.count { it.url.endsWith("/sync/pull") }
    val writes get() = requests.filter { it.method == HttpMethod.PUT || it.method == HttpMethod.DELETE || it.url.endsWith("/move") }

    suspend fun start(mode: SyncExecutionMode = SyncExecutionMode.BACKGROUND) = engine.start(binding, client, "Device", mode)
    fun seed(bytes: ByteArray = source(), path: String = "a.md", rev: Long = 1, group: Boolean = false) {
        val scope = if (group) SyncScopeKey.Group(SyncTestValues.group) else SyncTestValues.userScope
        if (group) groups[SyncTestValues.group] = SyncGroupState("Team", "Team", Role.VIEWER)
        files.put(bytes, path)
        val canonical = SyncLocalScanner.canonical(bytes, "a.md", scope).bytes
        val id = SyncTestValues.personalID
        states.update(binding) { SyncState(binding, SyncTestValues.uuid,
            mapOf(SyncTestValues.userScope to "old") + if (group) mapOf(scope to "old-group") else emptyMap(),
            groups, mapOf(id to SyncPromptState(scope, "a.md", rev, if (rev == 0L) null else SyncHash.of(canonical)))) }
        if (rev > 0) remote[SyncTestValues.personal.rawValue] = prompt(canonical, rev, if (group) PromptScope.Group(SyncTestValues.group.rawValue) else PromptScope.User)
    }
    private fun response(request: HttpRequest): HttpResponse = when {
        request.url.endsWith("/sync/pull") -> pullResponse()
        request.method == HttpMethod.GET -> remote[request.url.substringAfterLast('/')]?.let { HttpResponse(200, body = Prompt.codec.encode(it)) }
            ?: errorResponse(404, FailureCode.NOT_FOUND)
        request.method == HttpMethod.PUT -> {
            val put = PutPromptRequest.codec.decode(request.body!!)
            val id = request.url.substringAfterLast('/')
            val rev = (remote[id]?.rev ?: 0) + 1
            assertEquals(rev - 1, put.baseRev)
            remote[id] = prompt(put.content.encodeToByteArray(), rev, put.scope, put.path, id)
            HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(rev, ++sequence)))
        }
        request.method == HttpMethod.DELETE -> {
            val id = request.url.substringAfterLast('/').substringBefore('?')
            val rev = (remote.remove(id)?.rev ?: 0) + 1
            HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(rev, ++sequence)))
        }
        else -> fail("Unexpected request")
    }
    fun pullResponse(items: List<Prompt> = remote.values.toList()): HttpResponse {
        val head = maxOf(1, sequence, items.maxOfOrNull { it.rev } ?: 0)
        fun items(scope: PromptScope) = items.filter { it.scope == scope }.sortedBy { it.id }.map {
            FeedItem.Upsert(head, FeedPrompt(it.id, it.rev, it.path, it.content))
        }
        val scopes = listOf(SyncScope(ScopeIdentity.User(binding.account.userID.rawValue), Mode.SNAPSHOT, head,
            "user-$head", false, items(PromptScope.User))) + groups.map { (id, group) ->
            SyncScope(ScopeIdentity.Group(id.rawValue, group.name, group.role), Mode.SNAPSHOT, head,
                "group-$head", false, items(PromptScope.Group(id.rawValue)))
        }
        return HttpResponse(200, body = PullResponse.codec.encode(PullResponse(SyncTestValues.uuid.toString(), scopes, emptyList())))
    }
    companion object {
        fun source(body: String = "body", extra: String = "", id: ULID? = SyncTestValues.personal) =
            ("---\n" + (id?.let { "id: '${it.rawValue}'\n" } ?: "") + "title: Exact\n$extra---\n$body").encodeToByteArray()
        fun prompt(bytes: ByteArray, rev: Long = 1, scope: PromptScope = PromptScope.User,
                   path: String = "a.md", id: String = SyncTestValues.personal.rawValue) =
            Prompt(id, rev, scope, path, (if (scope is PromptScope.Group)
                ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm.group(bytes, LibraryPath.filename(path)).bytes
                else bytes).decodeToString())
        fun errorResponse(status: Int, code: FailureCode) = HttpResponse(status, body = ErrorResponse.codec.encode(ErrorResponse.Failure(code)))
    }
}

class SyncEngineTest {
    @Test fun backgroundActivationIsLocalAndRunsOnePassWithoutTimers() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.files.put(EngineHarness.source(), "a.md")
        h.start()
        assertTrue(h.requests.isEmpty())
        val result = h.engine.runBackground()
        assertEquals(1, h.pulls)
        assertEquals(1, result.counts.pushed)
        assertEquals(SyncStatus.IDLE, result.status)
        assertNotNull(result.lastSuccess)
        advanceTimeBy(600_001); runCurrent()
        assertEquals(1, h.pulls)
        assertEquals(SyncStopResult.STOPPED, h.engine.stop())
    }

    @Test fun foregroundPollsEvery60SecondsAndSavedEditsDebounce3Seconds() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(1, h.pulls)
        advanceTimeBy(59_999); runCurrent(); assertEquals(1, h.pulls)
        advanceTimeBy(1); runCurrent(); assertEquals(2, h.pulls)
        h.engine.localSave(); advanceTimeBy(2_000); h.engine.localSave()
        advanceTimeBy(2_999); runCurrent(); assertEquals(2, h.pulls)
        advanceTimeBy(1); runCurrent(); assertEquals(3, h.pulls)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun transientBackoffDoublesFrom5Through600AndManualSyncOverridesIt() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.respond = { throw HttpTransportError.NetworkFailure }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(SyncStatus.OFFLINE, h.engine.reports.value.status)
        for (seconds in listOf(5L, 10, 20, 40, 80, 160, 320, 600, 600)) {
            val before = h.requests.size
            advanceTimeBy(seconds * 1_000 - 1); runCurrent(); assertEquals(before, h.requests.size)
            advanceTimeBy(1); runCurrent(); assertEquals(before + 1, h.requests.size)
        }
        assertNull(h.engine.reports.value.lastSuccess)
        val before = h.requests.size
        h.respond = null
        h.engine.syncNow(); runCurrent()
        assertEquals(before + 1, h.requests.size)
        assertNotNull(h.engine.reports.value.lastSuccess)
        assertEquals(0, h.engine.scheduling.value.retryCount)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun retryAfterExtendsTheDelayAndBackgroundLeavesSchedulingToTheWorker() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.respond = { HttpResponse(429, headers = mapOf("retry-after" to "900"),
            body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.RATE_LIMITED))) }
        h.start()
        val result = h.engine.runBackground()
        assertEquals(SyncStatus.OFFLINE, result.status)
        assertEquals(Instant.parse("2026-10-14T12:15:00Z"), h.engine.scheduling.value.nextEligibleAt)
        val version = h.engine.scheduling.value.triggerVersion
        advanceTimeBy(899_999); runCurrent()
        h.engine.runBackground(version = version)
        assertEquals(1, h.requests.size)
        advanceTimeBy(1); runCurrent()
        assertEquals(1, h.requests.size)
        h.respond = null
        h.engine.runBackground(version = version)
        assertEquals(2, h.requests.size)
        h.engine.stop()
    }

    @Test fun unauthorizedStopsAllTriggersUntilReauthentication() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.respond = { EngineHarness.errorResponse(401, FailureCode.UNAUTHORIZED) }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(SyncStatus.NEEDS_SIGN_IN, h.engine.reports.value.status)
        assertTrue(h.engine.scheduling.value.needsSignIn)
        h.engine.syncNow(); h.engine.localSave(); h.engine.runBackground()
        advanceTimeBy(1_000_000); runCurrent()
        assertEquals(1, h.requests.size)
        assertFailsWith<SyncPushError.Busy> { h.engine.recoverJournal() }
        h.respond = null
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(2, h.requests.size)
        assertFalse(h.engine.reports.value.needsSignIn)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun manualSyncCannotBypassBlockingProtocolOrRecoveryErrors() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.respond = { HttpResponse(200, body = "{}".encodeToByteArray()) }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(SyncBlockingIssue.INVALID_PROTOCOL, h.engine.reports.value.blockingIssue)
        h.engine.syncNow(); h.engine.localSave(); advanceTimeBy(600_000); runCurrent()
        assertEquals(1, h.requests.size)
        assertNull(h.engine.reports.value.lastSuccess)
        h.engine.stop()
    }

    @Test fun overlappingWorkerJoinsForegroundPassAndConsumedVersionDoesNoHTTP() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        val release = CompletableDeferred<Unit>()
        h.respond = { release.await(); null }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        val scheduled = h.engine.scheduling.value
        val worker = async { h.engine.runBackground(scheduled.epoch, scheduled.triggerVersion) }
        runCurrent(); assertEquals(1, h.pulls)
        release.complete(Unit); worker.await(); runCurrent()
        h.engine.runBackground(scheduled.epoch, scheduled.triggerVersion)
        assertEquals(1, h.pulls)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun cancellingAJoiningWorkerDoesNotCancelForegroundWork() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        val release = CompletableDeferred<Unit>()
        h.respond = { release.await(); null }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        val worker = launch { h.engine.runBackground() }
        runCurrent(); worker.cancelAndJoin()
        assertEquals(SyncPhase.RESYNCING, h.engine.reports.value.phase)
        release.complete(Unit); runCurrent()
        assertNotNull(h.engine.reports.value.lastSuccess)
        assertEquals(1, h.pulls)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun manyTriggersDuringOnePassCoalesceIntoOneRerun() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        val release = CompletableDeferred<Unit>()
        h.respond = { if (h.pulls == 1) release.await(); null }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        repeat(20) { h.engine.syncNow() }
        runCurrent(); assertEquals(1, h.pulls)
        release.complete(Unit); runCurrent()
        assertEquals(2, h.pulls)
        assertEquals(SyncStatus.IDLE, h.engine.reports.value.status)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun furtherDirtyRerunsAreBoundedAndPartialPassDoesNotAdvanceLastSuccess() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.respond = {
            h.files.put(EngineHarness.source("Future", "format: 99\n"), "invalid.md")
            h.engine.committedMutation(SyncChangeOrigin.USER)
            delay(3_001)
            null
        }
        h.start(SyncExecutionMode.FOREGROUND)
        advanceTimeBy(6_003); runCurrent()
        assertEquals(2, h.pulls)
        assertTrue(h.engine.reports.value.retrying)
        assertNull(h.engine.reports.value.lastSuccess)
        assertEquals(1, h.engine.scheduling.value.retryCount)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun ownCommittedChangesRefreshWithoutSchedulingAPushLoop() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.remote[SyncTestValues.personal.rawValue] = EngineHarness.prompt(EngineHarness.source())
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(1, h.pulls)
        assertTrue(h.engine.libraryVersion.value > 0)
        val version = h.engine.scheduling.value.triggerVersion
        val refresh = h.engine.libraryVersion.value
        h.engine.committedMutation(SyncChangeOrigin.SYNC)
        advanceTimeBy(3_001); runCurrent()
        assertEquals(refresh + 1, h.engine.libraryVersion.value)
        assertEquals(version, h.engine.scheduling.value.triggerVersion)
        assertEquals(1, h.pulls)
        assertTrue(h.writes.isEmpty())
        h.engine.stop(); h.engine.drain()
    }

    @Test fun errorAndPartialConvergencePreservePreviousSuccessTime() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start(); val success = h.engine.runBackground().lastSuccess
        advanceTimeBy(1_000)
        h.files.put("---\nformat: 99\n---\nFuture", "future.md")
        val partial = h.engine.runBackground()
        assertEquals(SyncStatus.SYNC_ERROR, partial.status)
        assertEquals(success, partial.lastSuccess)
        h.respond = { throw HttpTransportError.NetworkFailure }
        assertEquals(success, h.engine.runBackground().lastSuccess)
        h.engine.stop()
    }

    @Test fun passSweepsOnlyStalePrivatePullPagesAndAttemptsAllThrowableDeletes() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        for (path in listOf("sync/pull-old-0.json", "sync/pull-old-1.json", "sync/push-canary.json", "other/pull-safe.json")) h.data.put("canary", path)
        val attempted = mutableListOf<String>()
        h.data.onDelete = { attempted.add(it); if (it.endsWith("-0.json")) throw AssertionError("Synthetic failure") }
        h.start()
        assertEquals(SyncBlockingIssue.RECOVERY_REQUIRED, h.engine.runBackground().blockingIssue)
        assertEquals(setOf("sync/pull-old-0.json", "sync/pull-old-1.json"), attempted.toSet())
        assertNull(h.engine.reports.value.lastSuccess)
        assertTrue(h.requests.isEmpty())
        h.data.onDelete = null
        h.engine.recoverJournal()
        assertNotNull(h.data.stamp("sync/push-canary.json"))
        assertNotNull(h.data.stamp("other/pull-safe.json"))
        assertTrue(h.data.listFiles().none { it.relativePath.startsWith("sync/pull-") })
        h.engine.stop()
    }

    @Test fun stagingCleanupDoesNotHoldTheEngineLockOrBlockStop() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val h = EngineHarness(TestCoroutineScheduler(), scope)
        val engine = SyncEngine(h.graph, scope, Dispatchers.IO, Clock { Instant.EPOCH },
            { SyncTestValues.device }, MonotonicClock(System::nanoTime))
        h.data.put("stale", "sync/pull-old-0.json")
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        h.data.onDelete = {
            arrived.countDown()
            check(release.await(10, TimeUnit.SECONDS))
        }
        val controls = Executors.newSingleThreadExecutor { Thread(it).apply { isDaemon = true } }
        val work = scope.launch {
            engine.start(h.binding, h.client, "Device")
            engine.runBackground()
        }
        try {
            assertTrue(arrived.await(5, TimeUnit.SECONDS), "Cleanup must reach the blocked deletion")
            val stopped = controls.submit<SyncStopResult> { engine.localSave(); engine.stop() }
            assertEquals(SyncStopResult.BUSY, stopped.get(3, TimeUnit.SECONDS))
            assertTrue(h.requests.isEmpty())
        } finally {
            release.countDown()
            engine.stop(); work.join(); engine.drain(); scope.cancel(); controls.shutdownNow()
        }
    }

    @Test fun cancelledStagingSweepDoesNotBecomeARecoveryFailure() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start()
        h.data.put("stale", "sync/pull-old-0.json")
        h.data.onDelete = { throw CancellationException("Synthetic cancellation") }
        val report = h.engine.runBackground()
        assertNull(report.blockingIssue)
        assertNull(report.lastSuccess)
        assertEquals(0, h.engine.scheduling.value.retryCount)
        assertTrue(h.requests.isEmpty())
        h.data.onDelete = null
        h.engine.recoverJournal()
        assertTrue(h.data.listFiles().none { it.relativePath.startsWith("sync/pull-") })
        h.engine.stop()
    }

    @Test fun changingToBackgroundCancelsForegroundTimersAndStaleEpochWorkIsANoop() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        val old = h.engine.scheduling.value
        h.engine.localSave()
        h.engine.setExecutionMode(SyncExecutionMode.BACKGROUND)
        assertTrue(h.engine.scheduling.value.triggerVersion > h.engine.scheduling.value.consumedVersion,
            "Interrupted foreground debounce must remain pending for native background dispatch")
        advanceTimeBy(600_001); runCurrent()
        assertEquals(1, h.pulls)
        h.engine.stop()
        h.start()
        h.engine.runBackground(old.epoch, old.triggerVersion)
        assertEquals(1, h.pulls)
        h.engine.stop()
    }

    @Test fun cancellingAdmittedBackgroundHTTPLeavesNoLateWritesOrReports() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        val arrived = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        h.respond = { withContext(NonCancellable) { arrived.complete(Unit); release.await() }; h.pullResponse() }
        h.start()
        val worker = launch { h.engine.runBackground() }
        arrived.await()
        val snapshot = h.data.bytesSnapshot()
        worker.cancel()
        runCurrent()
        val stopped = h.engine.reports.value
        release.complete(Unit); worker.join(); h.engine.drain(); runCurrent()
        assertEquals(snapshot, h.data.bytesSnapshot())
        assertEquals(stopped, h.engine.reports.value)
        assertNull(stopped.lastSuccess)
        assertTrue(h.files.listFiles().isEmpty())
        h.engine.stop()
    }

    @Test fun cancellationBeforeAdmissionDoesNotDispatchHTTP() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start()
        val worker = launch(start = CoroutineStart.UNDISPATCHED) { h.engine.runBackground() }
        worker.cancel(); worker.join(); h.engine.drain()
        assertTrue(h.requests.isEmpty())
        assertNull(h.engine.reports.value.lastSuccess)
        h.engine.stop()
    }

    @Test fun rootLossCancelsHTTPAndRestorationUsesANewEpoch() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        val release = CompletableDeferred<Unit>()
        h.respond = { withContext(NonCancellable) { release.await() }; null }
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(SyncStopResult.BUSY, h.engine.rootHealthChanged(SyncRootHealth.UNAVAILABLE))
        val lost = h.engine.reports.value
        assertEquals(SyncBlockingIssue.ROOT_UNAVAILABLE, lost.blockingIssue)
        release.complete(Unit); h.engine.drain(); runCurrent()
        assertEquals(lost, h.engine.reports.value)
        assertTrue(h.files.listFiles().isEmpty())
        h.respond = null
        h.engine.rootHealthChanged(SyncRootHealth.AVAILABLE); runCurrent()
        assertEquals(2, h.pulls)
        assertNotNull(h.engine.reports.value.lastSuccess)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun stoppingAtStatePublicationDrainsDurableAdmissionButPreventsLaterWorkAndReports() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.states.update(h.binding) { SyncState(h.binding, SyncTestValues.uuid, mapOf(SyncTestValues.userScope to "old")) }
        h.accounts.updateBinding(h.binding.root) { SyncLibraryBinding(h.binding.root, h.binding.account) }
        h.remote[SyncTestValues.personal.rawValue] = EngineHarness.prompt(EngineHarness.source())
        h.start()
        var stopped: SyncReport? = null
        h.data.onWrite = { path -> if (path == "sync/state.json") {
            assertEquals(SyncStopResult.BUSY, h.engine.stop())
            stopped = h.engine.reports.value
        } }
        val worker = launch { h.engine.runBackground() }
        worker.join(); h.engine.drain(); runCurrent()
        assertNotNull(stopped)
        assertEquals(stopped, h.engine.reports.value)
        assertEquals("user-1", h.state.cursors[SyncTestValues.userScope])
        assertContentEquals(EngineHarness.source(), h.files.read("a.md"))
        assertTrue(h.writes.isEmpty())
        h.data.onWrite = null
        assertEquals(SyncStopResult.STOPPED, h.engine.retire())
    }

    @Test fun pendingPushRecoveryPrecedesPullAfterLostAcknowledgement() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.start()
        h.respond = { request -> if (request.method == HttpMethod.PUT) {
            val put = PutPromptRequest.codec.decode(request.body!!)
            h.remote[SyncTestValues.personal.rawValue] = EngineHarness.prompt(put.content.encodeToByteArray())
            throw HttpTransportError.NetworkFailure
        } else null }
        assertEquals(SyncStatus.OFFLINE, h.engine.runBackground().status)
        assertNotNull(h.pending.load(h.binding))
        h.engine.stop(); h.engine.drain()
        h.respond = null
        h.start()
        val before = h.requests.size
        assertNotNull(h.engine.runBackground().lastSuccess)
        assertEquals(HttpMethod.GET, h.requests[before].method)
        assertTrue(h.requests[before + 1].url.endsWith("/sync/pull"))
        assertNull(h.pending.load(h.binding))
        assertEquals(1, h.writes.size)
        h.engine.stop()
    }

    @Test fun pendingApplyRecoveryPrecedesCollectionAndRetirementRequiresRecovery() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed()
        val file = h.rig.mutations.read("a.md")!!
        val bytes = EngineHarness.source("Recovered")
        val edit = h.rig.mutations.publication(bytes, "a.md", file, SyncIdentityTransition(file.identity, file.identity))
        val next = h.state.copy(prompts = mapOf(file.identity to SyncPromptState(SyncTestValues.userScope, "a.md", 2, SyncHash.of(bytes))))
        h.rig.libraryOperations.afterPublish = { throw StoreError.IOFailure }
        assertFails { h.rig.journal.apply(SyncApplyPlan(h.state, next, listOf(edit))) }
        assertNotNull(h.rig.journal.pending)
        h.rig.libraryOperations.afterPublish = null
        h.start()
        assertEquals(SyncStopResult.RECOVERY_REQUIRED, h.engine.retire())
        h.engine.recoverJournal()
        assertTrue(h.requests.isEmpty())
        assertNull(h.rig.journal.pending)
        assertContentEquals(bytes, h.files.read("a.md"))
        assertEquals(SyncStopResult.STOPPED, h.engine.retire())
    }

    @Test fun reportsUseRequiredPrecedenceAndOwnImmutableDetails() {
        val details = mutableListOf(SyncFileDetail("a.md", "forbidden"))
        val report = SyncReport(details = details, counts = SyncCounts(fileErrors = 1, conflicts = 1))
        details.clear()
        assertEquals(1, report.details.size)
        assertEquals(SyncStatus.SYNC_ERROR, report.status)
        assertEquals(SyncStatus.HAS_CONFLICTS, report.copy(counts = SyncCounts(conflicts = 1)).status)
        assertEquals(SyncStatus.OFFLINE, report.copy(offline = true).status)
        assertEquals(SyncStatus.SYNCING, report.copy(offline = true, phase = SyncPhase.RESYNCING).status)
        assertEquals(SyncStatus.SYNC_ERROR, report.copy(phase = SyncPhase.RESYNCING, blockingIssue = SyncBlockingIssue.INVALID_STATE).status)
        assertEquals(SyncStatus.NEEDS_SIGN_IN, report.copy(blockingIssue = SyncBlockingIssue.INVALID_STATE, needsSignIn = true).status)
    }

    @Test fun staleCommittedEventsCannotRefreshOrTriggerANewEpoch() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start()
        val old = h.engine.scheduling.value.epoch
        h.engine.stop(); h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        val version = h.engine.libraryVersion.value
        val trigger = h.engine.scheduling.value.triggerVersion
        h.engine.committedMutation(SyncChangeOrigin.USER, old)
        h.engine.committedMutation(SyncChangeOrigin.SYNC, old)
        advanceTimeBy(3_001); runCurrent()
        assertEquals(version, h.engine.libraryVersion.value)
        assertEquals(trigger, h.engine.scheduling.value.triggerVersion)
        assertEquals(1, h.pulls)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun accountSessionStopDropsTheCredentialEvenWithPendingNetworkIntent() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.respond = { if (it.method == HttpMethod.PUT) throw HttpTransportError.NetworkFailure else null }
        h.start(); h.engine.runBackground()
        assertNotNull(h.pending.load(h.binding))
        h.engine.stopAccountSession(); h.engine.drain()
        val before = h.requests.size
        assertFails { h.engine.recoverJournal() }
        h.engine.syncNow(); h.engine.runBackground()
        assertEquals(before, h.requests.size)
        assertFalse(h.engine.reports.value.enabled)
    }

    @Test fun persistedUnauthorizedStopCanBeReinstatedWithoutAccountOrHTTPAccess() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.engine.requireSignIn()
        h.engine.setExecutionMode(SyncExecutionMode.FOREGROUND)
        h.engine.syncNow(); h.engine.localSave(); h.engine.runBackground()
        advanceTimeBy(600_001); runCurrent()
        assertTrue(h.requests.isEmpty())
        assertEquals(SyncStatus.NEEDS_SIGN_IN, h.engine.reports.value.status)
        assertTrue(h.engine.scheduling.value.needsSignIn)
        h.start(); h.engine.runBackground()
        assertFalse(h.engine.scheduling.value.needsSignIn)
        h.engine.stop()
    }

    @Test fun establishedGraphCannotBeReboundToDifferentRootCapabilities() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.start(); h.engine.stop()
        val before = h.engine.reports.value
        val other = SyncLibraryIdentity(h.binding.account, SyncLibraryRoot("/different-library"))
        assertFailsWith<SyncError.BindingMismatch> { h.engine.start(other, h.client, "Device") }
        assertEquals(before, h.engine.reports.value)
        assertTrue(h.requests.isEmpty())
    }

    @Test fun nextWorkerCanResumeCancelledPendingIntentOnTheSameGraph() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        val sent = CompletableDeferred<Unit>()
        h.respond = { request -> if (request.method == HttpMethod.PUT) {
            val put = PutPromptRequest.codec.decode(request.body!!)
            h.remote[SyncTestValues.personal.rawValue] = EngineHarness.prompt(put.content.encodeToByteArray())
            sent.complete(Unit)
            awaitCancellation()
        } else null }
        h.start()
        val worker = launch { h.engine.runBackground() }
        sent.await()
        worker.cancelAndJoin(); h.engine.drain()
        assertNotNull(h.pending.load(h.binding))
        h.respond = null
        val due = h.engine.scheduling.value
        val before = h.requests.size
        val result = h.engine.runBackground(due.epoch, due.triggerVersion)
        assertNotNull(result.lastSuccess)
        assertNull(h.pending.load(h.binding))
        assertEquals(HttpMethod.GET, h.requests[before].method)
        assertEquals(1, h.writes.size)
        h.engine.stop()
    }

    @Test fun cancelledRecoveryBeforeAdmissionCannotDispatchHTTP() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.respond = { if (it.method == HttpMethod.PUT) throw HttpTransportError.NetworkFailure else null }
        h.start(); h.engine.runBackground(); h.engine.stop(); h.engine.drain()
        assertNotNull(h.pending.load(h.binding))
        h.respond = null
        val before = h.requests.size
        val recovery = launch(start = CoroutineStart.UNDISPATCHED) { h.engine.recoverJournal() }
        recovery.cancelAndJoin(); h.engine.drain()
        assertEquals(before, h.requests.size)
        assertNotNull(h.pending.load(h.binding))
        assertNull(h.engine.reports.value.lastSuccess)
    }
}
