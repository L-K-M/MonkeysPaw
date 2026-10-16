@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.lang.reflect.InvocationTargetException
import java.time.Instant
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlin.test.*

class SyncCoordinatorTest {
    private val v = SyncTestValues
    private val groupScope = PromptScope.Group(v.group.rawValue)
    private val groupPath = "Groups/Team/a.md"

    @Test fun groupPushCanonicalizationEmitsACommittedRefresh() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        h.groups[v.group] = h.groups.getValue(v.group).copy(role = Role.EDITOR)
        h.states.update(h.binding) { it.copy(groups = h.groups) }
        h.files.put(SyncLocalScanner.canonical(EngineHarness.source("Earlier edit"), "a.md", v.groupScope).bytes, groupPath)
        val raw = EngineHarness.source("Saved before upload", "private: true\nfavorite: true\n# local formatting\n")
        var refreshes = 0
        var beforePush = -1

        val result = coordinator(h) { refreshes++ }.run(phase = { phase ->
            if (phase == SyncPhase.PUSHING) {
                // A save after the final scan is reread by push and canonicalized by its acknowledgement.
                h.files.put(raw, groupPath)
                beforePush = refreshes
            }
        })
        assertEquals(1, result.counts.pushed)
        assertFalse(result.rerun)
        assertContentEquals(SyncLocalScanner.canonical(raw, "a.md", v.groupScope).bytes, h.files.read(groupPath))
        assertEquals(true, h.state.favorites[v.personalID])
        assertTrue(beforePush >= 0)
        assertTrue(refreshes > beforePush, "The push commit must refresh consumers after canonical publication")
    }

    @Test fun pushConflictRefreshesTheInstalledHeadAndPrivateCopy() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed()
        h.files.put(EngineHarness.source("Local edit"), "a.md")
        val server = EngineHarness.source("Concurrent server edit")
        var beforePush = -1L
        h.respond = { request -> if (request.method != HttpMethod.PUT) null else {
            beforePush = h.engine.libraryVersion.value
            h.remote[v.personal.rawValue] = EngineHarness.prompt(server, 2)
            HttpResponse(409, body = ErrorResponse.codec.encode(ErrorResponse.Conflict(
                ConflictHead(2, PromptScope.User, "a.md", server.decodeToString()))))
        } }
        h.start()
        assertNull(h.engine.runBackground().blockingIssue)
        assertContentEquals(server, h.files.read("a.md"))
        val copy = h.files.listFiles().single { it.relativePath.startsWith("Conflicts/") }
        assertTrue("Local edit" in h.files.text(copy.relativePath))
        assertTrue(beforePush >= 0)
        assertTrue(h.engine.libraryVersion.value > beforePush, "The installed head and private copy must refresh consumers")
        assertEquals(1, h.pulls)
        h.engine.stop()
    }

    @Test fun pendingPushRecoveryRefreshesAcknowledgementsAndConflictCopiesWithoutCollecting() = runTest {
        for (conflict in listOf(false, true)) {
            val h = EngineHarness(testScheduler, backgroundScope)
            h.seed()
            val local = EngineHarness.source("Local edit")
            h.files.put(local, "a.md")
            h.respond = { request -> if (request.method == HttpMethod.PUT) throw HttpTransportError.NetworkFailure else null }
            h.start()
            assertEquals(SyncStatus.OFFLINE, h.engine.runBackground().status)
            assertNotNull(h.pending.load(h.binding))
            val server = if (conflict) EngineHarness.source("Concurrent server edit") else local
            h.remote[v.personal.rawValue] = EngineHarness.prompt(server, 2)
            h.respond = null
            val beforeRecovery = h.engine.libraryVersion.value
            val pulls = h.pulls
            val writes = h.writes.size

            h.engine.recoverJournal()
            assertContentEquals(server, h.files.read("a.md"))
            assertEquals(if (conflict) 1 else 0, h.files.listFiles().count { it.relativePath.startsWith("Conflicts/") })
            assertTrue(h.engine.libraryVersion.value > beforeRecovery, "Pending replay must publish its committed refresh")
            assertEquals(pulls, h.pulls)
            assertEquals(writes, h.writes.size)
            assertNull(h.pending.load(h.binding))
            h.engine.stop()
        }
    }

    @Test fun explicitRecoveryReflushesUncertainPushPublicationOnTheSameGraph() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.start()
        h.rig.dataOperations.onOperation = {
            if (it == "file:sync/push.json") throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED)
        }
        assertNull(h.engine.runBackground().lastSuccess)
        val exact = h.data.read("sync/push.json")
        assertEquals(SyncError.DurabilityUncertain, h.pending.snapshot.error)
        assertTrue(h.writes.isEmpty())
        val requests = h.requests.size
        assertFailsWith<SyncError.DurabilityUncertain> { h.engine.recoverJournal() }
        assertEquals(requests, h.requests.size)

        h.rig.dataOperations.onOperation = null
        h.rig.dataOperations.calls.clear()
        h.respond = { request ->
            assertEquals(HttpMethod.GET, request.method)
            assertContentEquals(exact, h.data.read("sync/push.json"))
            assertTrue(h.rig.dataOperations.calls.containsAll(
                listOf("file:sync/push.json", "directory:sync", "directory:<root>")))
            null
        }
        h.engine.recoverJournal()
        assertEquals(requests + 1, h.requests.size)
        assertNull(h.pending.load(h.binding))
        assertContentEquals(EngineHarness.source(), h.files.read("a.md"))
        assertTrue(h.writes.isEmpty())
        assertNull(h.engine.reports.value.blockingIssue)
        assertEquals(SyncStopResult.STOPPED, h.engine.stop())
    }

    @Test fun explicitRecoveryReflushesUncertainPushDeletionOnTheSameGraph() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.start()
        h.data.onDelete = { path -> if (path == "sync/push.json") {
            h.rig.dataOperations.onOperation = {
                if (it == "directory:sync") throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED)
            }
        } }
        assertNull(h.engine.runBackground().lastSuccess)
        assertEquals(SyncError.DurabilityUncertain, h.pending.snapshot.error)
        assertNull(h.data.stamp("sync/push.json"))
        assertEquals(1, h.state.prompts[v.personalID]!!.rev)
        assertEquals(1, h.writes.size)
        val requests = h.requests.size

        h.data.onDelete = null
        h.rig.dataOperations.onOperation = null
        h.rig.dataOperations.calls.clear()
        h.engine.recoverJournal()
        assertEquals(listOf("directory:sync", "directory:<root>"), h.rig.dataOperations.calls)
        assertEquals(requests, h.requests.size)
        assertNull(h.pending.load(h.binding))
        assertNull(h.engine.reports.value.blockingIssue)
        assertEquals(SyncStopResult.STOPPED, h.engine.stop())
    }

    @Test fun explicitRecoveryValidatesUncertainPushBindingBeforeReflush() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.start()
        h.rig.dataOperations.onOperation = {
            if (it == "file:sync/push.json") throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED)
        }
        h.engine.runBackground()
        val exact = h.data.read("sync/push.json")
        val rebound = WireJson.parse(exact).objectValue().setting("root", wireString("/another"))
        h.data.put(syncDocumentBytes(rebound), "sync/push.json")
        h.rig.dataOperations.onOperation = null
        h.rig.dataOperations.calls.clear()
        val requests = h.requests.size

        assertFailsWith<SyncError.BindingMismatch> { h.engine.recoverJournal() }
        assertEquals(SyncError.DurabilityUncertain, h.pending.snapshot.error)
        assertTrue(h.rig.dataOperations.calls.isEmpty())
        assertEquals(requests, h.requests.size)
        h.data.put(exact, "sync/push.json")
        h.engine.recoverJournal()
        assertNull(h.pending.load(h.binding))
        assertEquals(SyncStopResult.STOPPED, h.engine.stop())
    }

    @Test fun pullCleanupFailureBlocksSuccessAndExplicitRecoveryRetriesWithoutRestarting() = runTest {
        for (failure in listOf<Throwable>(StoreError.IOFailure, AssertionError("Synthetic cleanup failure"))) {
            val h = EngineHarness(testScheduler, backgroundScope)
            val bytes = EngineHarness.source("Downloaded head")
            h.remote[v.personal.rawValue] = EngineHarness.prompt(bytes)
            h.start()
            h.data.onDelete = { if (it.startsWith("sync/pull-")) throw failure }

            val result = h.engine.runBackground()
            assertEquals(SyncBlockingIssue.RECOVERY_REQUIRED, result.blockingIssue)
            assertNull(result.lastSuccess)
            assertEquals(1, result.counts.pulled)
            assertContentEquals(bytes, h.files.read("a.md"))
            assertEquals("user-1", h.state.cursors[v.userScope])
            assertTrue(h.data.listFiles().any { it.relativePath.startsWith("sync/pull-") })

            val requests = h.requests.size
            val pages = h.data.listFiles().filter { it.relativePath.startsWith("sync/pull-") }
            assertFailsWith<SyncPullCollectorError.StagingFailed> { h.engine.recoverJournal() }
            assertEquals(requests, h.requests.size)
            assertEquals(pages, h.data.listFiles().filter { it.relativePath.startsWith("sync/pull-") })
            h.data.onDelete = null
            h.engine.recoverJournal()
            assertEquals(requests, h.requests.size)
            assertNull(h.engine.reports.value.blockingIssue)
            assertTrue(h.data.listFiles().none { it.relativePath.startsWith("sync/pull-") })
            assertEquals(SyncStopResult.STOPPED, h.engine.stop())
        }
    }

    @Test fun laterPassSweepsFailedCollectionCleanupBeforeCollectingMorePages() = runTest {
        for (storageRecovered in listOf(true, false)) {
            val h = EngineHarness(testScheduler, backgroundScope)
            val bytes = EngineHarness.source("Downloaded head")
            h.remote[v.personal.rawValue] = EngineHarness.prompt(bytes)
            h.start()
            h.data.onDelete = { if (it.startsWith("sync/pull-")) throw StoreError.IOFailure }
            h.respond = { request -> if (!request.url.endsWith("/sync/pull")) null else {
                if (h.pulls > 1) throw HttpTransportError.NetworkFailure
                val page = PullResponse.codec.decode(h.pullResponse().body)
                HttpResponse(200, body = PullResponse.codec.encode(page.copy(
                    scopes = page.scopes.map { it.copy(cursor = "next-page", hasMore = true) })))
            } }
            assertEquals(SyncStatus.OFFLINE, h.engine.runBackground().status)
            val pages = h.data.listFiles().filter { it.relativePath.startsWith("sync/pull-") }.map { it.relativePath }
            assertTrue(pages.isNotEmpty())
            val pulls = h.pulls
            if (storageRecovered) h.data.onDelete = null
            var leftoversAtCollection: List<String>? = null
            h.respond = { request ->
                if (request.url.endsWith("/sync/pull")) {
                    leftoversAtCollection = pages.filter { h.data.stamp(it) != null }
                }
                null
            }
            advanceTimeBy(5_001)

            val result = h.engine.runBackground()
            if (storageRecovered) {
                assertEquals(emptyList(), leftoversAtCollection, "Sweep old pages before another collection")
                assertNotNull(result.lastSuccess)
                assertContentEquals(bytes, h.files.read("a.md"))
                assertTrue(h.data.listFiles().none { it.relativePath.startsWith("sync/pull-") })
            } else {
                assertEquals(pulls, h.pulls)
                assertNull(result.lastSuccess)
                assertEquals(SyncBlockingIssue.RECOVERY_REQUIRED, result.blockingIssue)
                assertEquals(pages, h.data.listFiles().filter { it.relativePath.startsWith("sync/pull-") }.map { it.relativePath })
            }
            h.engine.stop()
        }
    }

    @Test fun deniedDeleteFallbackSkipsAnUnrootableRecordBeforeTheMatchingRecord() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        h.files.delete(groupPath)
        val unrootable = SyncPromptState(v.groupScope, "a".repeat(Limits.maxRootedPathBytes), 0)
        val state = h.state.copy(prompts = linkedMapOf(v.groupID to unrootable) + h.state.prompts)
        h.states.update(h.binding) { state }
        assertFailsWith<StoreError.InvalidPath> { SyncLocalScanner.rooted(unrootable.path, unrootable.scope, state.groups) }

        // The scanner rejects this pending path earlier; isolate the defensive fallback without widening its API.
        val restored = coordinator(h).restoreDeniedForTest(groupPath, state,
            SyncReconciliationSnapshot(h.binding, emptyList()))
        assertFalse(restored)
        assertContentEquals(h.remote.getValue(v.personal.rawValue).content.encodeToByteArray(), h.files.read(groupPath))
        assertEquals(unrootable, h.state.prompts[v.groupID])
        assertTrue(h.writes.isEmpty())
    }

    @Test fun deniedHeadGETPreservesFreshUncanonicalizableBytesAndRestoresTheHead() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        h.files.put(EngineHarness.source("First local edit"), groupPath)
        val later = EngineHarness.source("Future local edit", "format: 99\n")
        assertEquals(v.personal, PromptCodec.parseFile(later, "a.md").frontMatter.id)
        assertFailsWith<PromptWriteError.UnsupportedFormat> { SyncLocalScanner.canonical(later, "a.md", v.groupScope) }
        h.respond = { if (it.method == HttpMethod.GET) h.files.put(later, groupPath); null }

        h.start()
        val report = h.engine.runBackground()
        assertEquals(SyncStatus.SYNC_ERROR, report.status)
        assertNull(report.blockingIssue)
        assertTrue(report.details.any { it.code == PromptIssueCode.UNSUPPORTED_FORMAT.rawValue })
        assertContentEquals(h.remote.getValue(v.personal.rawValue).content.encodeToByteArray(), h.files.read(groupPath))
        val copy = h.files.listFiles().single { it.relativePath.startsWith("Conflicts/") }
        assertContentEquals(later, h.files.read(copy.relativePath))
        assertTrue(h.data.listFiles().filter { it.relativePath.endsWith(".bin") }.any { h.data.read(it.relativePath).contentEquals(later) })
        assertTrue(h.writes.isEmpty())
        h.engine.stop()
    }

    @Test fun adoptionReportsScanningBeforeMatchingAndPublishingTheIdentity() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.files.put(EngineHarness.source(id = null), "a.md")
        h.remote[v.personal.rawValue] = EngineHarness.prompt(EngineHarness.source())
        var currentPhase: SyncPhase? = null
        val publicationPhases = mutableListOf<SyncPhase?>()
        h.files.onWrite = { if (it == "a.md") publicationPhases.add(currentPhase) }

        coordinator(h).run(phase = { currentPhase = it })
        assertEquals(listOf<SyncPhase?>(SyncPhase.SCANNING), publicationPhases)
        assertEquals(v.personal, PromptCodec.parseFile(h.files.read("a.md"), "a.md").frontMatter.id)
        assertTrue(h.writes.isEmpty())
    }

    @Test fun locallyDeniedViewerEditPreservesRawPersonalMetadataAndRestoresExactHead() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        val raw = EngineHarness.source("Unsynced edit", "private: true\nfavorite: true\n# local formatting\n")
        h.files.put(raw, groupPath)
        h.start()
        val result = h.engine.runBackground()
        assertEquals(SyncStatus.HAS_CONFLICTS, result.status)
        assertContentEquals(h.remote.getValue(v.personal.rawValue).content.encodeToByteArray(), h.files.read(groupPath))
        assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes[groupPath])
        assertTrue(h.requests.any { it.method == HttpMethod.GET })
        assertTrue(h.writes.isNotEmpty())
        for (request in h.writes) assertEquals(PromptScope.User, PutPromptRequest.codec.decode(request.body!!).scope)
        val copy = h.files.listFiles().single { it.relativePath.startsWith("Conflicts/") }
        val source = h.files.text(copy.relativePath)
        assertTrue("Unsynced edit" in source)
        val document = PromptCodec.parse(source, "copy.md")
        assertTrue(document.frontMatter.isPrivate)
        assertTrue(document.frontMatter.favorite)
        assertTrue(h.data.listFiles().filter { it.relativePath.endsWith(".bin") }.any { h.data.read(it.relativePath).contentEquals(raw) })
        assertEquals(SyncPromptOrigin.ConflictOf(v.personal), h.state.prompts.values.single { it.origin != null }.origin)
        h.engine.stop()
    }

    @Test fun idlessViewerCreateGetsAnIdentityOnlyInAPrivateRescue() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.groups[v.group] = SyncGroupState("Team", "Team", Role.VIEWER)
        h.states.update(h.binding) { SyncState(h.binding, v.uuid, mapOf(v.userScope to "old", v.groupScope to "old-group"), h.groups) }
        h.files.put(EngineHarness.source("Viewer create", "private: true\n", id = null), groupPath)
        h.start()
        val result = h.engine.runBackground()
        assertNull(h.files.stamp(groupPath))
        assertEquals(SyncStatus.HAS_CONFLICTS, result.status)
        assertTrue(h.requests.none { it.method == HttpMethod.GET })
        assertTrue(h.writes.all { PutPromptRequest.codec.decode(it.body!!).scope == PromptScope.User })
        val copy = h.files.listFiles().single()
        assertTrue(copy.relativePath.startsWith("Conflicts/"))
        assertNotNull(PromptCodec.parseFile(h.files.read(copy.relativePath), "copy.md").frontMatter.id)
        assertEquals(SyncPromptOrigin.Rescued, h.state.prompts.values.single().origin)
        h.engine.stop()
    }

    @Test fun locallyDeniedViewerDeleteRestoresHeadWithoutASharedDelete() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        h.files.delete(groupPath)
        h.start(); h.engine.runBackground()
        assertContentEquals(h.remote.getValue(v.personal.rawValue).content.encodeToByteArray(), h.files.read(groupPath))
        assertTrue(h.writes.isEmpty())
        assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes[groupPath])
        h.engine.stop()
    }

    @Test fun headTransportFailureKeepsDeniedBytesAndCannotClaimSuccessfulSync() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        val raw = EngineHarness.source("Keep offline", "private: true\n")
        h.files.put(raw, groupPath)
        h.respond = { if (it.method == HttpMethod.GET) throw HttpTransportError.NetworkFailure else null }
        h.start()
        val report = h.engine.runBackground()
        assertEquals(SyncStatus.OFFLINE, report.status)
        assertNull(report.lastSuccess)
        assertContentEquals(raw, h.files.read(groupPath))
        assertTrue(h.writes.isEmpty())
        assertEquals(1, h.files.listFiles().size)
        h.engine.stop()
    }

    @Test fun headGETRereadsALaterSavedVersionBeforePreserving() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        h.files.put(EngineHarness.source("First local edit"), groupPath)
        val later = EngineHarness.source("Later saved edit", "# retain exact newest bytes\nprivate: true\n")
        h.respond = { if (it.method == HttpMethod.GET) h.files.put(later, groupPath); null }
        h.start(); h.engine.runBackground()
        val copy = h.files.listFiles().single { it.relativePath.startsWith("Conflicts/") }
        assertTrue("Later saved edit" in h.files.text(copy.relativePath))
        assertFalse("First local edit" in h.files.text(copy.relativePath))
        assertTrue(h.data.listFiles().filter { it.relativePath.endsWith(".bin") }.any { h.data.read(it.relativePath).contentEquals(later) })
        h.engine.stop()
    }

    @Test fun inaccessibleOrMismatchedDeniedHeadCannotAuthorizeRestoration() = runTest {
        for (status in listOf(403, 404, 410, 200)) {
            val h = EngineHarness(testScheduler, backgroundScope)
            h.seed(path = groupPath, group = true)
            h.files.put(EngineHarness.source("Keep privately"), groupPath)
            h.respond = { request -> if (request.method != HttpMethod.GET) null else when (status) {
                200 -> HttpResponse(200, body = Prompt.codec.encode(EngineHarness.prompt(EngineHarness.source(), 1, groupScope, "other.md")))
                410 -> HttpResponse(410, body = ErrorResponse.codec.encode(ErrorResponse.Deleted))
                403 -> EngineHarness.errorResponse(403, FailureCode.FORBIDDEN)
                else -> EngineHarness.errorResponse(404, FailureCode.NOT_FOUND)
            } }
            h.start(); h.engine.runBackground()
            assertNull(h.files.stamp(groupPath))
            assertTrue(h.files.listFiles().single().relativePath.startsWith("Conflicts/"))
            assertTrue(h.writes.all { PutPromptRequest.codec.decode(it.body!!).scope == PromptScope.User })
            h.engine.stop()
        }
    }

    @Test fun viewerHeadCollisionRescuesOccupantAndRecollectsBeforeAnyPushCandidate() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        val other = EngineHarness.source("Other server head", id = v.groupPrompt)
        h.files.put(other, "Groups/Team/b.md")
        h.states.update(h.binding) { it.copy(prompts = it.prompts +
            (v.groupID to SyncPromptState(v.groupScope, "b.md", 1, SyncHash.of(other))), favorites = mapOf(v.groupID to true)) }
        h.remote[v.groupPrompt.rawValue] = EngineHarness.prompt(other, 1, groupScope, "b.md", v.groupPrompt.rawValue)
        h.files.put(EngineHarness.source("Local edit"), groupPath)
        var moved = false
        h.respond = { request ->
            if (!moved && request.method == HttpMethod.GET) {
                moved = true
                h.files.move(groupPath, "Groups/Team/c.md")
                h.files.move("Groups/Team/b.md", groupPath)
            }
            null
        }
        h.start()
        val partial = h.engine.runBackground()
        assertNull(partial.lastSuccess)
        assertEquals(1, h.pulls)
        assertTrue(h.writes.isEmpty(), "No push can follow an internal scope reset before recollection")
        assertEquals(0, h.state.prompts[v.groupID]!!.rev)
        assertNull(h.state.prompts[v.groupID]!!.canonicalHash)
        assertEquals(true, h.state.favorites[v.groupID])
        assertEquals("0", h.state.cursors[v.groupScope])
        h.engine.runBackground()
        assertEquals(2, h.pulls)
        assertContentEquals(h.remote.getValue(v.personal.rawValue).content.encodeToByteArray(), h.files.read(groupPath))
        assertContentEquals(h.remote.getValue(v.groupPrompt.rawValue).content.encodeToByteArray(), h.files.read("Groups/Team/b.md"))
        assertTrue(h.writes.none { it.method == HttpMethod.DELETE })
        assertTrue(h.writes.all { PutPromptRequest.codec.decode(it.body!!).scope == PromptScope.User })
        h.engine.stop()
    }

    @Test fun accessFingerprintsAreStableAcrossRestartNamesAndFolderOrderingButChangeWithRole() {
        val a = SyncGroupState("Team", "Team", Role.EDITOR)
        val b = SyncGroupState("Other", "Other", Role.VIEWER)
        val first = SyncCoordinator.accessGeneration(linkedMapOf(v.group to a, v.otherUser to b))
        assertTrue(first >= 0)
        assertEquals(first, SyncCoordinator.accessGeneration(linkedMapOf(v.otherUser to b, v.group to a)))
        assertEquals(first, SyncCoordinator.accessGeneration(mapOf(v.group to a.copy(name = "Renamed", folder = "Folder"), v.otherUser to b)))
        assertNotEquals(first, SyncCoordinator.accessGeneration(mapOf(v.group to a.copy(role = Role.VIEWER), v.otherUser to b)))
        assertEquals(0, SyncCoordinator.accessGeneration(emptyMap()))
    }

    @Test fun unchangedInputErrorSurvivesReauthenticationAndIsNotPushedOrImmediatelyRerun() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(rev = 0)
        h.respond = { request -> if (request.method == HttpMethod.PUT) EngineHarness.errorResponse(404, FailureCode.NOT_FOUND) else null }
        h.start(); val first = h.engine.runBackground()
        assertEquals(SyncStatus.SYNC_ERROR, first.status)
        assertNull(first.lastSuccess)
        val fingerprint = h.state.prompts[v.personalID]!!.lastError!!.fingerprint
        h.engine.stop()
        h.start(SyncExecutionMode.FOREGROUND); runCurrent()
        assertEquals(fingerprint, h.state.prompts[v.personalID]!!.lastError!!.fingerprint)
        assertEquals(1, h.writes.size)
        advanceTimeBy(5_001); runCurrent(); assertEquals(1, h.writes.size)
        assertEquals(2, h.pulls)
        assertNull(h.engine.reports.value.lastSuccess)
        h.engine.stop(); h.engine.drain()
    }

    @Test fun restorePushesPreservedWritableVersionsOnlyAfterEveryScopeCommits() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(EngineHarness.source("Preserved local"), rev = 8)
        h.groups[v.group] = SyncGroupState("Team", "Team", Role.EDITOR)
        val groupBytes = EngineHarness.source("Group local", id = v.groupPrompt)
        h.files.put(groupBytes, "Groups/Team/g.md")
        h.states.update(h.binding) { it.copy(groups = h.groups, cursors = it.cursors + (v.groupScope to "old group"),
            prompts = it.prompts + (v.groupID to SyncPromptState(v.groupScope, "g.md", 8,
                SyncHash.of(SyncLocalScanner.canonical(groupBytes, "g.md", v.groupScope).bytes)))) }
        h.remote[v.personal.rawValue] = EngineHarness.prompt(EngineHarness.source("Restored server"), 3)
        h.remote[v.groupPrompt.rawValue] = EngineHarness.prompt(EngineHarness.source("Group restored", id = v.groupPrompt),
            3, groupScope, "g.md", v.groupPrompt.rawValue)
        val database = SyncIdentifiers.uuid("22345678-1234-abcd-9876-123456789abc")
        h.respond = { request -> when {
            request.url.endsWith("/sync/pull") -> {
                val pull = PullResponse.codec.decode(h.pullResponse().body).copy(databaseID = database.toString())
                HttpResponse(200, body = PullResponse.codec.encode(pull))
            }
            request.method == HttpMethod.PUT -> {
                assertEquals(database, h.state.databaseID)
                assertEquals(setOf(v.userScope, v.groupScope), h.state.cursors.keys)
                val put = PutPromptRequest.codec.decode(request.body!!)
                assertEquals(3, put.baseRev)
                assertTrue("local" in put.content)
                null
            }
            else -> null
        } }
        h.start()
        assertNotNull(h.engine.runBackground().lastSuccess)
        assertEquals(2, h.writes.size)
        assertEquals(database, h.state.databaseID)
        h.engine.stop()
    }

    @Test fun boundedPreparationLeavesCursorsUnacknowledgedAndAlwaysDiscardsStaging() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.files.put(EngineHarness.source(id = null), "a.md")
        h.remote[v.personal.rawValue] = EngineHarness.prompt(EngineHarness.source())
        val coordinator = SyncCoordinator(SyncWorkPermit(h.binding, 1, coroutineContext[Job]), h.client, h.data,
            h.states, h.accounts, h.rig.mutations, h.rig.journal, h.pending, "Device", { v.device },
            { Instant.parse("2026-10-14T12:00:00Z") }, MonotonicClock { testScheduler.currentTime * 1_000_000 }, preparationLimit = 1)
        assertFailsWith<SyncCoordinatorError.NoProgress> { coordinator.run() }
        assertTrue(h.state.cursors.isEmpty())
        assertNull(h.state.databaseID)
        assertTrue(h.writes.isEmpty())
        assertTrue(h.data.listFiles().none { it.relativePath.startsWith("sync/pull-") })
    }

    @Test fun requiredSnapshotRecollectionIsBoundedWithoutAnyStatePublication() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.states.update(h.binding) { SyncState(h.binding, v.uuid, mapOf(v.userScope to "0")) }
        h.accounts.updateBinding(h.binding.root) { SyncLibraryBinding(h.binding.root, h.binding.account) }
        val before = h.state
        h.respond = { HttpResponse(200, body = PullResponse.codec.encode(PullResponse(v.uuid.toString(),
            listOf(SyncScope(ScopeIdentity.User(v.user.rawValue), Mode.DELTA, 0, "0", false, emptyList())), emptyList()))) }
        h.start(); val report = h.engine.runBackground()
        assertEquals(2, h.pulls)
        assertTrue(report.retrying)
        assertNull(report.lastSuccess)
        assertEquals(before, h.state)
        assertTrue(h.data.listFiles().none { it.relativePath.startsWith("sync/pull-") })
        h.engine.stop()
    }

    @Test fun accessibleMovedHeadIsInstalledBeforeItsRemovedGroupIsRetired() = runTest {
        val h = EngineHarness(testScheduler, backgroundScope)
        h.seed(path = groupPath, group = true)
        val bytes = h.remote.getValue(v.personal.rawValue).content.encodeToByteArray()
        h.remote[v.personal.rawValue] = EngineHarness.prompt(bytes, 2, PromptScope.User)
        h.groups.clear()
        h.respond = { request -> if (!request.url.endsWith("/sync/pull")) null else {
            val pull = PullResponse.codec.decode(h.pullResponse().body).copy(removed = listOf(v.groupScope.rawValue))
            HttpResponse(200, body = PullResponse.codec.encode(pull))
        } }
        h.start()
        val report = h.engine.runBackground()
        assertNotNull(report.lastSuccess)
        assertContentEquals(bytes, h.files.read("a.md"))
        assertNull(h.files.stamp(groupPath))
        assertTrue(h.state.groups.isEmpty())
        assertEquals(v.userScope, h.state.prompts[v.personalID]!!.scope)
        assertTrue(h.files.listFiles().none { it.relativePath.startsWith("Conflicts/") })
        assertTrue(h.writes.isEmpty())
        h.engine.stop()
    }

    @Test fun suspendedHTTPNeverHoldsTheOrdinaryLibraryMutationLock() = runBlocking {
        val rig = SyncJournalHarness(seed = false)
        val arrived = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val server = SyncServerURL(rig.binding.account.serverURL)
        val client = SyncHTTPClient(server, HttpTransport {
            arrived.complete(Unit); release.await()
            HttpResponse(200, body = PullResponse.codec.encode(PullResponse(v.uuid.toString(),
                listOf(SyncScope(ScopeIdentity.User(v.user.rawValue), Mode.SNAPSHOT, 0, "0", false, emptyList())), emptyList())))
        }, SyncCredential(server, ch.lkmc.monkeyspaw.core.domain.llm.SecretValue("A".repeat(43))))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val graph = SyncEngineGraph(rig.local.state, rig.states, rig.accounts, rig.mutations, rig.journal,
            SyncPendingOperationStore(rig.local.state, rig.dataOperations))
        val engine = SyncEngine(graph, scope, Dispatchers.IO, Clock { Instant.parse("2026-10-14T12:00:00Z") },
            { v.device }, MonotonicClock(System::nanoTime))
        engine.start(rig.binding, client, "Device")
        val worker = launch { engine.runBackground() }
        arrived.await()
        try {
            withTimeout(3_000) {
                async(Dispatchers.Default) { rig.local.library.save(PromptCodec.parse("Ordinary save", "local.md"), "local.md") }.await()
            }
            assertEquals("Ordinary save", rig.local.library.load("local.md").document.body)
        } finally {
            engine.stop(); release.complete(Unit); worker.join(); engine.drain(); scope.cancel()
        }
    }

    private fun coordinator(h: EngineHarness, committed: () -> Unit = {}) = SyncCoordinator(SyncWorkPermit(h.binding, 1), h.client, h.data,
        h.states, h.accounts, h.rig.mutations, h.rig.journal, h.pending, "Device", { v.device },
        { Instant.parse("2026-10-14T12:00:00Z") }, MonotonicClock { h.scheduler.currentTime * 1_000_000 }, committed = committed)

    private suspend fun SyncCoordinator.restoreDeniedForTest(path: String, state: SyncState,
                                                            local: SyncReconciliationSnapshot): Boolean =
        suspendCoroutineUninterceptedOrReturn { continuation ->
            val method = javaClass.getDeclaredMethod("restoreDenied", String::class.java, SyncState::class.java,
                SyncReconciliationSnapshot::class.java, Continuation::class.java)
            method.isAccessible = true
            try { method.invoke(this, path, state, local, continuation) }
            catch (error: InvocationTargetException) { throw error.targetException }
        }
}
