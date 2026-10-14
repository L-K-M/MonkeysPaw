package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.time.Instant
import kotlin.test.*

internal class PushTransport(val respond: suspend (HttpRequest) -> HttpResponse) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()
    override suspend fun send(request: HttpRequest): HttpResponse { requests.add(request); return respond(request) }
}

internal class PushHarness(val scan: ScanHarness = ScanHarness()) {
    val binding get() = scan.binding
    val files get() = scan.files
    val data get() = scan.rig.local.state
    val operations get() = scan.rig.dataOperations
    val states get() = scan.states
    val mutations get() = scan.mutations
    val journal get() = scan.journal
    val pending = SyncPendingOperationStore(data, operations)
    var owner: SyncLibraryBinding? = null
    val state get() = states.load(binding)!!
    val record get() = state.prompts[SyncTestValues.personalID]!!

    fun seed(rev: Long = 0, base: ByteArray = ScanHarness.bytes(), groups: Boolean = false,
             scope: SyncScopeKey = SyncTestValues.userScope): PushHarness {
        val g = if (groups) ScanHarness.groups() else emptyMap()
        val path = SyncLocalScanner.rooted("a.md", scope, g)
        files.put(base, path)
        scan.state(g, mapOf(SyncTestValues.personalID to ScanHarness.record(base, scope, rev = rev)))
        scan.rig.clearCalls()
        return this
    }

    fun candidate(): SyncLocalChange = scan.prepare().changes.first {
        when (it) {
            is SyncLocalChange.Delete -> it.identity == SyncTestValues.personalID
            is SyncLocalChange.Create -> it.prompt.identity == SyncTestValues.personalID
            is SyncLocalChange.Update -> it.prompt.identity == SyncTestValues.personalID
            is SyncLocalChange.Rename -> it.prompt.identity == SyncTestValues.personalID
            is SyncLocalChange.Move -> it.prompt.identity == SyncTestValues.personalID
        }
    }

    fun engine(transport: PushTransport, permit: SyncWorkPermit? = null): SyncPushEngine {
        val server = SyncServerURL(binding.account.serverURL)
        val client = SyncHTTPClient(server, transport, SyncCredential(server, SecretValue("A".repeat(43))))
        return SyncPushEngine(binding, client, states, pending, mutations, journal, { owner }, "Device", { SyncTestValues.device },
            { Instant.parse("2026-10-14T12:34:00Z") }, permit)
    }

    fun restart(): PushHarness = PushHarness(ScanHarness(scan.rig.restart())).also { it.owner = owner }
    fun team() = SyncScopeKey.Group(SyncTestValues.group)
    fun move(edit: ByteArray? = null, destination: String = "Groups/Team/a.md") {
        files.move("a.md", destination)
        edit?.let { files.put(it, destination) }
    }
}

class SyncPushEngineTest {
    private val v = SyncTestValues
    private val available = SyncReconciliationSnapshot.Availability.AVAILABLE

    @Test fun pushMetadataIODoesNotGrowWithUnrelatedLibraryFiles() = runTest {
        val stateReads = mutableListOf<Int>()
        val retainedInventories = mutableListOf<Int>()
        for (count in listOf(0, 32)) {
            val h = PushHarness().seed()
            val change = h.candidate()
            repeat(count) { h.files.put("Unrelated $it", "other-$it.md") }
            h.data.reads.clear()
            h.operations.calls.clear()
            assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(PushTransport { ack(1) }).push(change, available))
            stateReads.add(h.data.reads.count { it == "sync/state.json" })
            retainedInventories.add(h.operations.calls.count { it == "inventory" })
        }
        assertEquals(stateReads.first(), stateReads.last(), "State reads must not grow per file")
        assertEquals(retainedInventories.first(), retainedInventories.last(), "Retained inventories must not grow per file")
    }

    @Test fun acknowledgementRetainsNewerFavoriteIntentWhenRawSourceChangesDuringHTTP() = runTest {
        val h = PushHarness().seed(3, groups = true, scope = v.groupScope)
        val path = "Groups/Team/a.md"
        h.files.put(ScanHarness.bytes("Sent"), path)
        val change = h.candidate()
        h.files.put(ScanHarness.bytes("Sent", extra = "favorite: true\n"), path)
        h.states.update(h.binding) { it.copy(prompts = it.prompts +
            (v.personalID to h.record.copy(favoriteInput = SyncFavoriteInput(true)))) }
        val fresh = ScanHarness.bytes("Saved during HTTP", extra = "favorite: true\n")
        val transport = PushTransport { h.files.put(fresh, path); ack(4) }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(transport).push(change, available))
        assertEquals(SyncFavoriteInput(true), h.record.favoriteInput)
        assertFalse(h.state.favorites[v.personalID] == true)
        assertIs<SyncLocalChange.Update>(h.candidate())
        assertFalse(h.state.favorites[v.personalID] == true)
        assertNull(h.record.favoriteInput)
    }

    @Test fun rereadsFreshBytesAndFlushesExactPrivateRequestBeforeHTTPWithoutAdvancingCursors() = runTest {
        val h = PushHarness().seed()
        val change = h.candidate()
        val fresh = ScanHarness.bytes("\uFEFFFresh\r\n", extra = "# verbatim private comment\n")
        h.files.put(fresh, "a.md")
        val old = h.state
        val t = PushTransport { request ->
            val put = PutPromptRequest.codec.decode(request.body!!)
            assertEquals(0, put.baseRev)
            assertContentEquals(fresh, put.content.encodeToByteArray())
            val pending = SyncPendingOperationJson.codec.decode(WireJson.parse(h.data.read("sync/push.json")).objectValue())
            assertContentEquals(fresh, pending.intent.sentBytes)
            assertEquals(SyncHash.of(fresh), pending.intent.sentHash)
            assertEquals(v.userScope, pending.intent.scope)
            assertEquals("a.md", pending.intent.path)
            assertTrue(h.data.isPrivate("sync/push.json"))
            assertTrue("file:sync/push.json" in h.operations.calls)
            assertTrue("directory:sync" in h.operations.calls && "directory:<root>" in h.operations.calls)
            assertContentEquals(PutPromptRequest.codec.encode(PutPromptRequest(0, PromptScope.User, "a.md", fresh.decodeToString())), request.body)
            ack(1, 99999)
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(change, available))
        assertEquals(SyncHash.of(fresh), h.record.canonicalHash)
        assertEquals(old.cursors, h.state.cursors)
        assertEquals(old.databaseID, h.state.databaseID)
        assertNull(h.data.stamp("sync/push.json"))
    }

    @Test fun lostCreateAndEditRepliesRecoverBeforeAnotherPullAndLeaveNewerSavedBytesDirty() = runTest {
        for (rev in listOf(0L, 3L)) {
            val h = PushHarness().seed(rev)
            val sent = ScanHarness.bytes("Sent")
            val fresh = ScanHarness.bytes("Saved while offline")
            h.files.put(sent, "a.md")
            val change = h.candidate()
            val cursors = h.state.cursors
            assertFailsWith<SyncHTTPClientError.Transport> { h.engine(PushTransport { throw HttpTransportError.NetworkFailure }).push(change, available) }
            val durable = h.data.read("sync/push.json")
            h.files.put(fresh, "a.md")
            val restarted = h.restart()
            assertFailsWith<SyncPushError.PendingOperation> { restarted.engine(PushTransport { fail("Pending work must recover first") }).push(change, available) }
            val t = PushTransport {
                assertEquals(HttpMethod.GET, it.method)
                assertContentEquals(durable, h.data.read("sync/push.json"))
                prompt(sent, rev + 1)
            }
            assertEquals(SyncPushResult.ACKNOWLEDGED, restarted.engine(t).resume(available))
            assertEquals(rev + 1, restarted.record.rev)
            assertEquals(SyncHash.of(sent), restarted.record.canonicalHash)
            assertContentEquals(fresh, h.files.read("a.md"))
            assertEquals(1, h.files.listFiles().size)
            assertEquals(cursors, restarted.state.cursors)
            assertEquals(1, t.requests.size)
            assertIs<SyncLocalChange.Update>(restarted.candidate())
        }
    }

    @Test fun unsentCreateOrUnchangedHeadReplansWithFreshBytesAfterRecovery() = runTest {
        for (rev in listOf(0L, 3L)) {
            val base = ScanHarness.bytes()
            val h = PushHarness().seed(rev)
            h.files.put(ScanHarness.bytes("First edit"), "a.md")
            val change = h.candidate()
            assertFailsWith<SyncHTTPClientError.Transport> { h.engine(PushTransport { throw HttpTransportError.NetworkFailure }).push(change, available) }
            val fresh = ScanHarness.bytes("Repaired")
            h.files.put(fresh, "a.md")
            val t = PushTransport {
                if (it.method == HttpMethod.GET) {
                    if (rev == 0L) failure(404, ErrorResponse.Failure(FailureCode.NOT_FOUND)) else prompt(base, rev)
                } else {
                    assertEquals(rev, put(it).baseRev)
                    assertContentEquals(fresh, put(it).content.encodeToByteArray())
                    ack(rev + 1)
                }
            }
            val engine = h.restart().engine(t)
            assertEquals(SyncPushResult.REPLAN, engine.resume(available))
            assertEquals(SyncPushResult.ACKNOWLEDGED, engine.push(change, available))
            assertEquals(listOf(HttpMethod.GET, HttpMethod.PUT), t.requests.map { it.method })
        }
    }

    @Test fun inflightPrivateAndGroupEditsAcknowledgeOnlySentBytes() = runTest {
        for (group in listOf(false, true)) {
            val h = PushHarness().seed(3, groups = group, scope = if (group) SyncScopeKey.Group(v.group) else v.userScope)
            val path = if (group) "Groups/Team/a.md" else "a.md"
            val sent = ScanHarness.bytes("Sent")
            h.files.put(sent, path)
            val change = h.candidate()
            val fresh = ScanHarness.bytes("During request", extra = if (group) "favorite: true\nprivate: true\n" else "# changed\n")
            val t = PushTransport { h.files.put(fresh, path); ack(4) }
            assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(change, available))
            assertEquals(SyncHash.of(SyncLocalScanner.canonical(sent, "a.md", h.record.scope).bytes), h.record.canonicalHash)
            assertContentEquals(fresh, h.files.read(path))
            assertIs<SyncLocalChange.Update>(h.candidate())
            if (group) assertEquals(true, h.state.favorites[v.personalID])
        }
    }

    @Test fun identicalConflictHeadAcknowledgesSentBytesWithoutCopy() = runTest {
        val h = PushHarness().seed(3)
        val sent = ScanHarness.bytes("Sent")
        val fresh = ScanHarness.bytes("Newer saved bytes")
        h.files.put(sent, "a.md")
        val change = h.candidate()
        val t = PushTransport { h.files.put(fresh, "a.md"); conflict(sent, 4) }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(change, available))
        assertEquals(SyncHash.of(sent), h.record.canonicalHash)
        assertContentEquals(fresh, h.files.read("a.md"))
        assertEquals(1, h.files.listFiles().size)
    }

    @Test fun freshLocalEqualityWithWinningHeadDoesNotAcknowledgeDifferentSentBytes() = runTest {
        val h = PushHarness().seed(3)
        h.files.put(ScanHarness.bytes("Sent"), "a.md")
        val change = h.candidate()
        val server = ScanHarness.bytes("Winning head")
        val t = PushTransport { h.files.put(server, "a.md"); conflict(server, 4) }
        assertEquals(SyncPushResult.REPLAN, h.engine(t).push(change, available))
        assertEquals(SyncHash.of(server), h.record.canonicalHash)
        assertEquals(1, h.files.listFiles().size)
    }

    @Test fun privateCommentConflictPreservesExactLosingRawVersionAndCreatesOnePrivateCopy() = runTest {
        val h = PushHarness().seed(3)
        h.files.put(ScanHarness.bytes(extra = "# sent\n"), "a.md")
        val change = h.candidate()
        val losing = ScanHarness.bytes(extra = "# losing in-flight comment\n")
        val server = ScanHarness.bytes(extra = "# server comment\n")
        assertTrue(CanonicalForm.equivalentForAdoption(losing, server, CanonicalForm.Scope.USER, "a.md"))
        assertEquals(SyncPushResult.REPLAN, h.engine(PushTransport {
            h.files.put(losing, "a.md"); conflict(server, 4)
        }).push(change, available))
        assertContentEquals(server, h.files.read("a.md"))
        assertEquals(1, h.files.listFiles().count { it.relativePath.startsWith("Conflicts/") })
        assertTrue(h.data.listFiles().filter { it.relativePath.endsWith(".bin") }.any { h.data.read(it.relativePath).contentEquals(losing) })
        assertEquals(SyncPromptOrigin.ConflictOf(v.personal), h.state.prompts[PromptIdentity.Assigned(v.device)]!!.origin)
    }

    @Test fun delete404And410PreserveRecreatedBytesAndNeverTrashThem() = runTest {
        for (status in listOf(404, 410)) {
            val h = PushHarness().seed(3)
            h.files.delete("a.md")
            val change = h.candidate()
            val recreated = ScanHarness.bytes("Recreated during request")
            val t = PushTransport {
                assertEquals(HttpMethod.DELETE, it.method)
                assertTrue(it.url.endsWith("?base_rev=3"))
                h.files.put(recreated, "a.md")
                failure(status, if (status == 404) ErrorResponse.Failure(FailureCode.NOT_FOUND) else ErrorResponse.Deleted)
            }
            assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(change, available))
            assertNull(h.state.prompts[v.personalID])
            assertContentEquals(recreated, h.files.read("a.md"))
            assertTrue(h.scan.rig.libraryOperations.calls.none { it.startsWith("trash") })
        }
    }

    @Test fun staleDeleteSeesLiveIDElsewhereOrReplacementAndSendsNothing() = runTest {
        for (replacement in listOf(false, true)) {
            val h = PushHarness().seed(3)
            h.files.delete("a.md")
            val change = h.candidate()
            h.files.put(ScanHarness.bytes(id = if (replacement) v.groupPrompt else v.personal), if (replacement) "a.md" else "renamed.md")
            assertEquals(SyncPushResult.REPLAN, h.engine(PushTransport { fail("Must not DELETE") }).push(change, available))
        }
    }

    @Test fun lostDeleteRecoveryUsesGETOnlyAndConflictRestoresServerEdit() = runTest {
        for (deleted in listOf(false, true)) {
            val h = PushHarness().seed(3)
            h.files.delete("a.md")
            val change = h.candidate()
            assertFailsWith<SyncHTTPClientError.Transport> { h.engine(PushTransport { throw HttpTransportError.NetworkFailure }).push(change, available) }
            val server = ScanHarness.bytes("Server edit")
            val restarted = h.restart()
            assertEquals(if (deleted) SyncPushResult.ACKNOWLEDGED else SyncPushResult.REPLAN, restarted.engine(PushTransport {
                assertEquals(HttpMethod.GET, it.method)
                if (deleted) failure(404, ErrorResponse.Failure(FailureCode.NOT_FOUND)) else prompt(server, 4)
            }).resume(available))
            if (deleted) assertNull(restarted.state.prompts[v.personalID]) else assertContentEquals(server, h.files.read("a.md"))
        }
    }

    @Test fun moveUsesCanonicalServerBaseCommitsThenRereadsForPutAtNewRevision() = runTest {
        val base = ScanHarness.bytes(extra = "favorite: true\nprivate: true\n")
        val h = PushHarness().seed(3, base, groups = true)
        h.move(ScanHarness.bytes("First edit"))
        val change = h.candidate()
        val fresh = ScanHarness.bytes("During move", extra = "favorite: false\nprivate: true\n")
        val moved = CanonicalForm.group(base, "a.md").bytes
        val edit = CanonicalForm.group(fresh, "a.md").bytes
        val cursors = h.state.cursors
        val t = PushTransport {
            if (it.method == HttpMethod.POST) {
                val move = MovePromptRequest.codec.decode(it.body!!)
                assertEquals(3, move.baseRev)
                assertEquals(PromptScope.Group(v.group.rawValue), move.scope)
                assertContentEquals(moved, h.pending.load(h.binding)!!.intent.sentBytes)
                h.files.put(fresh, "Groups/Team/a.md")
                ack(4)
            } else {
                assertEquals(h.team(), h.record.scope)
                assertEquals(4, h.record.rev)
                assertEquals(SyncHash.of(moved), h.record.canonicalHash)
                assertEquals(4, put(it).baseRev)
                assertContentEquals(edit, put(it).content.encodeToByteArray())
                ack(5)
            }
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(change, available, baseBytes = base))
        assertEquals(listOf(HttpMethod.POST, HttpMethod.PUT), t.requests.map { it.method })
        assertContentEquals(edit, h.files.read("Groups/Team/a.md"))
        assertEquals(cursors, h.state.cursors)
        assertNull(h.state.favorites[v.personalID])
    }

    @Test fun moveOnlyCanonicalizesGroupAndLiftsFavoriteWithoutPut() = runTest {
        val base = ScanHarness.bytes(extra = "favorite: true\nprivate: false\n")
        val h = PushHarness().seed(3, base, true)
        h.move()
        val t = PushTransport { assertEquals(HttpMethod.POST, it.method); ack(4) }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(h.candidate(), available))
        assertContentEquals(CanonicalForm.group(base, "a.md").bytes, h.files.read("Groups/Team/a.md"))
        assertEquals(true, h.state.favorites[v.personalID])
        assertEquals(1, t.requests.size)
    }

    @Test fun unknownMoveBaseGetsCurrentHeadAndRejectsStaleSuppliedBase() = runTest {
        val h = PushHarness().seed(3, groups = true)
        h.move(ScanHarness.bytes("Edit"))
        val t = PushTransport {
            when (it.method) {
                HttpMethod.GET -> prompt(ScanHarness.bytes(), 3)
                HttpMethod.POST -> ack(4)
                else -> { assertEquals(4, put(it).baseRev); ack(5) }
            }
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(h.candidate(), available, baseBytes = ScanHarness.bytes("Stale")))
        assertEquals(listOf(HttpMethod.GET, HttpMethod.POST, HttpMethod.PUT), t.requests.map { it.method })
    }

    @Test fun groupToGroupTransferCommitsDestinationBeforePut() = runTest {
        val base = CanonicalForm.group(ScanHarness.bytes(), "a.md").bytes
        val h = PushHarness().seed(3, base, true, SyncScopeKey.Group(v.group))
        h.states.update(h.binding) { it.copy(groups = it.groups + (v.otherUser to SyncGroupState("Other", "Other", Role.OWNER))) }
        h.files.move("Groups/Team/a.md", "Groups/Other/a.md")
        h.files.put(ScanHarness.bytes("Destination edit"), "Groups/Other/a.md")
        val t = PushTransport {
            if (it.method == HttpMethod.POST) {
                assertEquals(PromptScope.Group(v.otherUser.rawValue), MovePromptRequest.codec.decode(it.body!!).scope)
                assertContentEquals(base, h.pending.load(h.binding)!!.intent.sentBytes)
                ack(4)
            } else {
                assertEquals(SyncScopeKey.Group(v.otherUser), h.record.scope)
                assertEquals(4, put(it).baseRev)
                ack(5)
            }
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(h.candidate(), available, baseBytes = base))
        assertEquals(listOf(HttpMethod.POST, HttpMethod.PUT), t.requests.map { it.method })
    }

    @Test fun groupToPrivateMoveDerivesBaselineInSourceScopeBeforeDestination() = runTest {
        val raw = ScanHarness.bytes(extra = "favorite: true\nprivate: true\n")
        val base = CanonicalForm.group(raw, "a.md").bytes
        val h = PushHarness().seed(3, base, true, SyncScopeKey.Group(v.group))
        h.files.move("Groups/Team/a.md", "a.md")
        h.files.put(ScanHarness.bytes("Private edit"), "a.md")
        val t = PushTransport {
            if (it.method == HttpMethod.POST) { assertContentEquals(base, h.pending.load(h.binding)!!.intent.sentBytes); ack(4) }
            else { assertEquals(SyncHash.of(base), h.record.canonicalHash); assertEquals(4, put(it).baseRev); ack(5) }
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(h.candidate(), available, baseBytes = raw))
    }

    @Test fun moveStandsWhenFollowingPutFailsAndOldCandidateUsesMovedRevisionAfterResume() = runTest {
        val h = PushHarness().seed(3, groups = true)
        h.move(ScanHarness.bytes("Edit"))
        val change = h.candidate()
        val base = ScanHarness.bytes()
        assertFailsWith<SyncHTTPClientError.ServerFailure> { h.engine(PushTransport {
            if (it.method == HttpMethod.POST) ack(4) else failure(500, ErrorResponse.Failure(FailureCode.INTERNAL_ERROR))
        }).push(change, available, baseBytes = base) }
        assertEquals(h.team(), h.record.scope)
        assertEquals(4, h.record.rev)
        assertEquals(SyncOperation.PUT, h.pending.load(h.binding)!!.intent.operation)
        val restarted = h.restart()
        val t = PushTransport {
            if (it.method == HttpMethod.GET) prompt(CanonicalForm.group(base, "a.md").bytes, 4, PromptScope.Group(v.group.rawValue))
            else { assertEquals(4, put(it).baseRev); ack(5) }
        }
        val engine = restarted.engine(t)
        assertEquals(SyncPushResult.REPLAN, engine.resume(available))
        assertEquals(SyncPushResult.ACKNOWLEDGED, engine.push(change, available, baseBytes = base))
        assertEquals(listOf(HttpMethod.GET, HttpMethod.PUT), t.requests.map { it.method })
    }

    @Test fun droppedMoveReplyRecoversMovedBaselineBeforeUploadingQueuedEdit() = runTest {
        val base = ScanHarness.bytes()
        val edit = ScanHarness.bytes("Queued edit")
        val h = PushHarness().seed(3, groups = true)
        h.move(edit)
        assertFailsWith<SyncHTTPClientError.Transport> { h.engine(PushTransport { throw HttpTransportError.NetworkFailure })
            .push(h.candidate(), available, baseBytes = base) }
        val restarted = h.restart()
        val t = PushTransport {
            if (it.method == HttpMethod.GET) prompt(CanonicalForm.group(base, "a.md").bytes, 4, PromptScope.Group(v.group.rawValue))
            else {
                assertEquals(HttpMethod.PUT, it.method)
                assertEquals(4, put(it).baseRev)
                assertContentEquals(CanonicalForm.group(edit, "a.md").bytes, put(it).content.encodeToByteArray())
                ack(5)
            }
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, restarted.engine(t).resume(available))
        assertEquals(listOf(HttpMethod.GET, HttpMethod.PUT), t.requests.map { it.method })
        assertEquals(1, h.files.listFiles().size)
    }

    @Test fun changedBaselineGetInstallsHeadWithoutSendingStaleTransfer() = runTest {
        val h = PushHarness().seed(3, groups = true)
        h.move(ScanHarness.bytes("Losing edit"))
        val server = ScanHarness.bytes("Server wins")
        val t = PushTransport { assertEquals(HttpMethod.GET, it.method); prompt(server, 4, path = "winner.md") }
        assertEquals(SyncPushResult.REPLAN, h.engine(t).push(h.candidate(), available))
        assertContentEquals(server, h.files.read("winner.md"))
        assertNull(h.files.stamp("Groups/Team/a.md"))
        assertEquals(v.userScope, h.record.scope)
        assertEquals(1, h.files.listFiles().count { it.relativePath.startsWith("Conflicts/") })
        assertEquals(1, t.requests.size)
    }

    @Test fun creatorDeniedTransferRestoresMatchingOriginalKeepsPrivateCopyAndDoesNotInferViewer() = runTest {
        val base = CanonicalForm.group(ScanHarness.bytes(), "a.md").bytes
        val h = PushHarness().seed(3, base, true, SyncScopeKey.Group(v.group))
        h.files.move("Groups/Team/a.md", "a.md")
        h.files.put(ScanHarness.bytes("Noncreator edit"), "a.md")
        val t = PushTransport {
            if (it.method == HttpMethod.POST) failure(403, ErrorResponse.Failure(FailureCode.FORBIDDEN))
            else prompt(base, 3, PromptScope.Group(v.group.rawValue))
        }
        assertEquals(SyncPushResult.REFRESH_MEMBERSHIPS, h.engine(t).push(h.candidate(), available, baseBytes = base))
        assertEquals(Role.EDITOR, h.state.groups[v.group]!!.role)
        assertEquals(SyncIssueCode.Forbidden, h.record.lastError!!.code)
        assertContentEquals(base, h.files.read("Groups/Team/a.md"))
        assertNull(h.files.stamp("a.md"))
        assertEquals(1, h.files.listFiles().count { it.relativePath.startsWith("Conflicts/") })
    }

    @Test fun deniedCreateAndUnavailableOrMismatchedOriginalRescueWithoutRetry() = runTest {
        for (rev in listOf(0L, 3L)) for (kind in listOf("mismatch", "network", "missing", "malformed")) {
            val h = PushHarness().seed(rev)
            h.files.put(ScanHarness.bytes("Keep me"), "a.md")
            val t = PushTransport {
                if (it.method == HttpMethod.PUT) failure(403, ErrorResponse.Failure(FailureCode.FORBIDDEN))
                else when (kind) {
                    "mismatch" -> prompt(ScanHarness.bytes(), 3, path = "wrong.md")
                    "network" -> throw HttpTransportError.NetworkFailure
                    "missing" -> failure(404, ErrorResponse.Failure(FailureCode.NOT_FOUND))
                    else -> prompt("invalid without id".encodeToByteArray(), 3)
                }
            }
            assertEquals(SyncPushResult.REFRESH_MEMBERSHIPS, h.engine(t).push(h.candidate(), available))
            assertNull(h.state.prompts[v.personalID])
            assertNull(h.files.stamp("a.md"))
            val copy = h.files.listFiles().single()
            assertTrue(copy.relativePath.startsWith("Conflicts/"))
            assertEquals("Keep me", PromptCodec.parseFile(h.files.read(copy.relativePath), "Copy.md").body)
            assertEquals(if (rev == 0L) 1 else 2, t.requests.size)
            assertNull(h.pending.load(h.binding))
        }
    }

    @Test fun repeated422OrNonDelete404IsSkippedAcrossRestartUntilBytesOrAccessRepair() = runTest {
        for (notFound in listOf(false, true)) for (repairAccess in listOf(false, true)) {
            val h = PushHarness().seed(3)
            h.files.put(ScanHarness.bytes("Rejected"), "a.md")
            val change = h.candidate()
            val t = PushTransport { if (notFound) failure(404, ErrorResponse.Failure(FailureCode.NOT_FOUND)) else validation() }
            assertEquals(SyncPushResult.SKIPPED, h.engine(t).push(change, available, 7))
            assertEquals(3, h.record.rev)
            val restarted = h.restart()
            val retry = PushTransport { ack(4) }
            val engine = restarted.engine(retry)
            assertEquals(SyncPushResult.SKIPPED, engine.push(change, available, 7))
            assertTrue(retry.requests.isEmpty())
            if (!repairAccess) h.files.put(ScanHarness.bytes("Repaired"), "a.md")
            assertEquals(SyncPushResult.ACKNOWLEDGED, engine.push(change, available, if (repairAccess) 8 else 7))
            assertNull(restarted.record.lastError)
        }
    }

    @Test fun put410PreservesWithFreshPrivateIdentity() = runTest {
        val h = PushHarness().seed(3)
        h.files.put(ScanHarness.bytes("Deleted remotely"), "a.md")
        assertEquals(SyncPushResult.REPLAN, h.engine(PushTransport { failure(410, ErrorResponse.Deleted) }).push(h.candidate(), available))
        assertNull(h.state.prompts[v.personalID])
        assertNotNull(h.state.prompts[PromptIdentity.Assigned(v.device)])
        assertNull(h.files.stamp("a.md"))
    }

    @Test fun pathTakenCreateUsesSentPlusFreshEqualityForAdoptionAndPreservesKeyedState() = runTest {
        for (edited in listOf(false, true)) {
            val h = PushHarness().seed()
            val change = h.candidate()
            h.scan.rig.local.usage.recordUse(v.personalID)
            val server = ScanHarness.bytes(id = v.groupPrompt)
            val t = PushTransport {
                if (edited) h.files.put(ScanHarness.bytes("Edited during request"), "a.md")
                failure(409, ErrorResponse.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 7, server.decodeToString())))
            }
            assertEquals(if (edited) SyncPushResult.REPLAN else SyncPushResult.ACKNOWLEDGED, h.engine(t).push(change, available))
            if (edited) {
                assertEquals(v.personal, PromptCodec.parseFile(h.files.read("a (2).md"), "a.md").frontMatter.id)
                assertNull(h.state.prompts[v.groupID])
            } else {
                assertContentEquals(server, h.files.read("a.md"))
                assertEquals(7, h.state.prompts[v.groupID]!!.rev)
                assertEquals(1, h.scan.rig.local.usage.useEvents(v.groupID).size)
            }
        }
    }

    @Test fun movePathTakenRenamesDestinationAndKeepsOriginalScopeAndRevision() = runTest {
        val h = PushHarness().seed(3, groups = true)
        h.move()
        h.files.put(ScanHarness.bytes(id = v.groupPrompt), "Groups/Team/a (2).md")
        val t = PushTransport { failure(409, ErrorResponse.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 7, ScanHarness.bytes(id = v.groupPrompt).decodeToString()))) }
        assertEquals(SyncPushResult.REPLAN, h.engine(t).push(h.candidate(), available))
        assertContentEquals(ScanHarness.bytes(), h.files.read("Groups/Team/a (3).md"))
        assertEquals(3, h.record.rev)
        assertEquals(v.userScope, h.record.scope)
        assertEquals(1, t.requests.size)
    }

    @Test fun markedUnacknowledgedPrivateCreateClashesIntoGroupWithoutProjectingPrivateOrigin() = runTest {
        for (origin in listOf(SyncPromptOrigin.ConflictOf(v.groupPrompt), SyncPromptOrigin.Rescued)) {
            val marker = if (origin == SyncPromptOrigin.Rescued) "x-monkeyspaw-rescued: true\n"
                else "x-monkeyspaw-conflict-of: '${v.groupPrompt.rawValue}'\n"
            val raw = ScanHarness.bytes("Marked private copy", extra = marker + "favorite: true\nprivate: true\n")
            val h = PushHarness().seed(base = raw, groups = true)
            h.states.update(h.binding) { it.copy(prompts = it.prompts + (v.personalID to h.record.copy(origin = origin))) }
            h.move()
            val change = h.candidate()
            assertEquals(v.userScope, h.record.scope)
            assertEquals(origin, h.record.origin)
            val old = h.state
            val existing = CanonicalForm.group(ScanHarness.bytes("Occupied", id = v.groupPrompt), "a.md").bytes
            val t = PushTransport {
                assertEquals(0, put(it).baseRev)
                assertEquals(PromptScope.Group(v.group.rawValue), put(it).scope)
                failure(409, ErrorResponse.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 7, existing.decodeToString())))
            }
            assertEquals(SyncPushResult.REPLAN, h.engine(t).push(change, available))
            assertEquals(h.team(), h.record.scope)
            assertEquals("a (2).md", h.record.path)
            assertEquals(0, h.record.rev)
            assertNull(h.record.canonicalHash)
            assertNull(h.record.origin)
            assertEquals(old.cursors, h.state.cursors)
            assertContentEquals(raw, h.files.read("Groups/Team/a (2).md"))
            assertNull(h.files.stamp("Groups/Team/a.md"))
            assertNull(h.pending.load(h.binding))
            assertEquals(1, t.requests.size)
            val retry = PushTransport {
                assertEquals(0, put(it).baseRev)
                assertEquals("a (2).md", put(it).path)
                assertContentEquals(CanonicalForm.group(raw, "a (2).md").bytes, put(it).content.encodeToByteArray())
                ack(1)
            }
            assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(retry).push(h.candidate(), available))
            assertEquals(1, h.record.rev)
            assertNull(h.record.origin)
            assertEquals(true, h.state.favorites[v.personalID])
        }
    }

    @Test fun inFlightCreateEditWithExhaustedClashNamesPersistsFixedError() = runTest {
        val h = PushHarness().seed()
        val change = h.candidate()
        for (number in 2..20) h.files.put(ScanHarness.bytes(id = v.groupPrompt), "a ($number).md")
        assertEquals(SyncPushResult.SKIPPED, h.engine(PushTransport {
            h.files.put(ScanHarness.bytes("New edit"), "a.md")
            failure(409, ErrorResponse.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 7, ScanHarness.bytes(id = v.groupPrompt).decodeToString())))
        }).push(change, available))
        assertEquals(SyncIssueCode.PathClash, h.record.lastError!!.code)
        assertNotNull(h.files.stamp("a.md"))
        assertNull(h.pending.load(h.binding))
    }

    @Test fun unknownWinningGroupOrOccupiedTargetRetainsPolicyHeadAndPendingIntent() = runTest {
        for (unknownGroup in listOf(false, true)) {
            val h = PushHarness().seed(3)
            h.files.put(ScanHarness.bytes("Local edit"), "a.md")
            val change = h.candidate()
            if (!unknownGroup) h.files.put(ScanHarness.bytes(id = v.groupPrompt), "winner.md")
            val before = h.files.bytesSnapshot()
            val server = if (unknownGroup) CanonicalForm.group(ScanHarness.bytes("Head"), "winner.md").bytes else ScanHarness.bytes("Head")
            val engine = h.engine(PushTransport { conflict(server, 4,
                if (unknownGroup) PromptScope.Group(v.group.rawValue) else PromptScope.User, "winner.md") })
            assertFailsWith<SyncReconciliationError.RequiresPolicy> { engine.push(change, available) }
            assertEquals("winner.md", engine.policyHead!!.path)
            assertEquals(before, h.files.bytesSnapshot())
            assertNotNull(h.pending.load(h.binding))
            assertEquals(3, h.record.rev)
        }
    }

    @Test fun durableForensicHoldAndChangedIdentityRejectCraftedCandidates() = runTest {
        val h = PushHarness().seed()
        val change = assertIs<SyncLocalChange.Create>(h.candidate())
        val source = h.mutations.read("a.md")!!
        val raw = SyncLibraryFile("raw.md", source.stamp, byteArrayOf(-1))
        val copy = h.mutations.rescue(raw, "Conflicts/raw.md", v.device)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(SyncApplyPlan(h.state, h.state, listOf(copy))))
        h.files.delete("Conflicts/raw.md")
        h.files.move("a.md", "Conflicts/raw.md")
        val current = h.mutations.read("Conflicts/raw.md")!!
        val crafted = SyncLocalChange.Create(SyncLocalPrompt(current, change.prompt.identity, change.prompt.scope,
            current.path, change.prompt.canonical, null))
        assertEquals(SyncPushResult.HELD, h.engine(PushTransport { fail("Retained raw hold must block HTTP") }).push(crafted, available))
        h.files.put(ScanHarness.bytes(id = v.groupPrompt), "a.md")
        assertEquals(SyncPushResult.REPLAN, h.engine(PushTransport { fail("Replaced identity cannot be sent") }).push(change, available))
    }

    @Test fun invalidAcknowledgementOrDeniedGetAuthFailurePreservesExactActiveRequest() = runTest {
        for (kind in listOf("staleAck", "unauthorized", "cancelled")) {
            val h = PushHarness().seed(3)
            h.files.put(ScanHarness.bytes("Edit"), "a.md")
            val change = h.candidate()
            var saved: ByteArray? = null
            val failure = runCatching { h.engine(PushTransport {
                saved = h.data.read("sync/push.json")
                if (kind == "staleAck") ack(3)
                else if (it.method == HttpMethod.PUT) failure(403, ErrorResponse.Failure(FailureCode.FORBIDDEN))
                else if (kind == "unauthorized") failure(401, ErrorResponse.Failure(FailureCode.UNAUTHORIZED))
                else throw HttpTransportError.Cancelled
            }).push(change, available) }.exceptionOrNull()
            assertNotNull(failure)
            when (kind) {
                "staleAck" -> assertEquals(SyncHTTPClientError.MalformedResponse, failure)
                "unauthorized" -> assertEquals(SyncHTTPClientError.Unauthorized, failure)
                else -> assertEquals(HttpTransportError.Cancelled, assertIs<CancellationException>(failure).cause)
            }
            assertContentEquals(saved, h.data.read("sync/push.json"))
            assertEquals(3, h.record.rev)
            assertEquals(1, h.files.listFiles().size)
        }
    }

    @Test fun holdAfterScanAndHoldDuringPendingPublicationNeverUploadAndRetainPossiblySentIntent() = runTest {
        for (duringPublication in listOf(false, true)) {
            val h = PushHarness().seed()
            val change = h.candidate()
            fun hold() { h.owner = SyncLibraryBinding(h.binding.root, h.binding.account, holds = listOf(
                SyncHeldPrompt(v.personalID, "a.md", v.accountIdentity(userID = v.otherUser), SyncHash.of(ScanHarness.bytes())))) }
            if (duringPublication) h.operations.onOperation = { if (it == "file:sync/push.json") hold() } else hold()
            assertEquals(SyncPushResult.HELD, h.engine(PushTransport { fail("Held content must never upload") }).push(change, available))
            assertContentEquals(ScanHarness.bytes(), h.files.read("a.md"))
            if (duringPublication) assertEquals(1, h.data.listFiles().count { it.relativePath.startsWith("sync/retained/push-") })
        }
    }

    @Test fun holdDuringBaselineGetAndAfterMovePreventsTransferOrFollowingPut() = runTest {
        for (afterMove in listOf(false, true)) {
            val h = PushHarness().seed(3, groups = true)
            h.move(ScanHarness.bytes("Edit"))
            val change = h.candidate()
            val t = PushTransport {
                h.owner = SyncLibraryBinding(h.binding.root, h.binding.account, holds = listOf(
                    SyncHeldPrompt(v.personalID, "Groups/Team/a.md", h.binding.account, SyncHash.of(h.files.read("Groups/Team/a.md")))))
                if (afterMove) ack(4) else prompt(ScanHarness.bytes(), 3)
            }
            assertEquals(SyncPushResult.HELD, h.engine(t).push(change, available, baseBytes = if (afterMove) ScanHarness.bytes() else null))
            assertEquals(listOf(if (afterMove) HttpMethod.POST else HttpMethod.GET), t.requests.map { it.method })
            assertEquals(if (afterMove) 4 else 3, h.record.rev)
        }
    }

    @Test fun newlyHeldPendingRequestRetainsExactBytesBeforeClearingActiveSlotWithoutHTTP() = runTest {
        val h = PushHarness().seed()
        assertFailsWith<SyncHTTPClientError.Transport> { h.engine(PushTransport { throw HttpTransportError.NetworkFailure }).push(h.candidate(), available) }
        val exact = h.data.read("sync/push.json")
        h.owner = SyncLibraryBinding(h.binding.root, h.binding.account, holds = listOf(
            SyncHeldPrompt(v.personalID, "a.md", h.binding.account, SyncHash.of(h.files.read("a.md")))))
        val restarted = h.restart()
        assertEquals(SyncPushResult.HELD, restarted.engine(PushTransport { fail("No HTTP for held request") }).resume(available))
        val retained = h.data.listFiles().single { it.relativePath.startsWith("sync/retained/push-") }
        assertContentEquals(exact, h.data.read(retained.relativePath))
        assertNull(restarted.pending.load(h.binding))
    }

    @Test fun viewerDowngradeAfterScanCannotSendCreateEditMoveOrDelete() = runTest {
        for (kind in listOf("create", "edit", "moveIn", "moveOut", "delete")) {
            val inGroup = kind != "moveIn"
            val h = PushHarness().seed(if (kind == "create") 0 else 3, groups = true,
                scope = if (inGroup) SyncScopeKey.Group(v.group) else v.userScope)
            when (kind) {
                "edit" -> h.files.put(ScanHarness.bytes("Edit"), "Groups/Team/a.md")
                "moveIn" -> h.move()
                "moveOut" -> h.files.move("Groups/Team/a.md", "a.md")
                "delete" -> h.files.delete("Groups/Team/a.md")
            }
            val change = h.candidate()
            h.states.update(h.binding) { it.copy(groups = ScanHarness.groups(Role.VIEWER)) }
            assertEquals(SyncPushResult.REPLAN, h.engine(PushTransport { fail("Known viewer $kind must never upload") }).push(change, available))
        }
    }

    @Test fun roleOrFolderChangeDuringJournalOrGetMustReplanBeforeDispatch() = runTest {
        for (viaGet in listOf(false, true)) for (folderChange in listOf(false, true)) {
            val h = PushHarness().seed(3, groups = true, scope = if (viaGet) v.userScope else SyncScopeKey.Group(v.group))
            if (viaGet) h.move(ScanHarness.bytes("Edit")) else h.files.put(ScanHarness.bytes("Edit"), "Groups/Team/a.md")
            val change = h.candidate()
            fun changeAccess() { h.states.update(h.binding) {
                it.copy(groups = mapOf(v.group to SyncGroupState("Team", if (folderChange) "Renamed" else "Team",
                    if (folderChange) Role.EDITOR else Role.VIEWER)))
            } }
            if (!viaGet) h.operations.onOperation = { if (it == "file:sync/push.json") changeAccess() }
            val t = PushTransport {
                assertEquals(HttpMethod.GET, it.method, "Access/location changed before mutation dispatch")
                changeAccess()
                prompt(ScanHarness.bytes(), 3)
            }
            assertEquals(SyncPushResult.REPLAN, h.engine(t).push(change, available))
            assertEquals(if (viaGet) 1 else 0, t.requests.size)
            assertNull(h.pending.load(h.binding))
        }
    }

    @Test fun viewerDowngradeDuringMoveReplyAcknowledgesMoveButDoesNotPut() = runTest {
        val h = PushHarness().seed(3, groups = true)
        h.move(ScanHarness.bytes("Edit"))
        val t = PushTransport {
            assertEquals(HttpMethod.POST, it.method)
            h.states.update(h.binding) { it.copy(groups = ScanHarness.groups(Role.VIEWER)) }
            ack(4)
        }
        assertEquals(SyncPushResult.REPLAN, h.engine(t).push(h.candidate(), available, baseBytes = ScanHarness.bytes()))
        assertEquals(4, h.record.rev)
        assertEquals(h.team(), h.record.scope)
        assertEquals(1, t.requests.size)
        assertNotEquals(SyncHash.of(h.files.read("Groups/Team/a.md")), h.record.canonicalHash)
    }

    @Test fun stablePutAndMoveEnvelopeBytesMatchSwiftSortedKeyEncoding() = runTest {
        val h = PushHarness().seed()
        val t = PushTransport {
            assertEquals("""{"base_rev":0,"content":"---\nid: '01ARZ3NDEKTSV4RRFFQ69G5FAY'\ntitle: Exact\n---\nBody\r\n","path":"a.md","scope":"user"}""", it.body!!.decodeToString())
            ack(1)
        }
        assertEquals(SyncPushResult.ACKNOWLEDGED, h.engine(t).push(h.candidate(), available))
        val move = PushHarness().seed(3, groups = true)
        move.move()
        assertEquals(SyncPushResult.ACKNOWLEDGED, move.engine(PushTransport {
            assertEquals("""{"base_rev":3,"group_id":"01ARZ3NDEKTSV4RRFFQ69G5FAX","path":"a.md","scope":"group"}""", it.body!!.decodeToString())
            ack(4)
        }).push(move.candidate(), available))
    }

    @Test fun journalOrBaselineGetRaceReplansInsteadOfSendingCapturedIncarnation() = runTest {
        for (viaGet in listOf(false, true)) {
            val h = PushHarness().seed(if (viaGet) 3 else 0, groups = viaGet)
            if (viaGet) h.move(ScanHarness.bytes("First edit"))
            val path = if (viaGet) "Groups/Team/a.md" else "a.md"
            val change = h.candidate()
            val fresh = ScanHarness.bytes("After capture")
            if (!viaGet) h.operations.onOperation = { if (it == "file:sync/push.json") h.files.put(fresh, path) }
            val t = PushTransport {
                assertEquals(HttpMethod.GET, it.method)
                h.files.put(fresh, path)
                prompt(ScanHarness.bytes(), 3)
            }
            assertEquals(SyncPushResult.REPLAN, h.engine(t).push(change, available))
            assertEquals(if (viaGet) 1 else 0, t.requests.size)
            assertContentEquals(fresh, h.files.read(path))
            assertNull(h.pending.load(h.binding))
        }
    }

    @Test fun acknowledgementApplyFailureReplaysSameIntentBeforeGetAndNeverAcknowledgesCursor() = runTest {
        val h = PushHarness().seed(3)
        val sent = ScanHarness.bytes("Edit")
        h.files.put(sent, "a.md")
        val change = h.candidate()
        val old = h.state
        val t = PushTransport {
            h.operations.onOperation = { name ->
                if (name == "file:sync/state.json") throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED)
            }
            ack(4)
        }
        assertFailsWith<SyncError.DurabilityUncertain> { h.engine(t).push(change, available) }
        assertNotNull(h.journal.pending)
        assertNotNull(h.data.stamp("sync/push.json"))
        assertEquals(old, h.states.snapshot.value)
        h.operations.onOperation = null
        val restarted = h.restart()
        assertEquals(SyncPushResult.ACKNOWLEDGED, restarted.engine(PushTransport {
            assertNull(restarted.journal.pending)
            assertEquals(4, restarted.record.rev)
            prompt(sent, 4)
        }).resume(available))
        assertEquals(old.cursors, restarted.state.cursors)
        assertEquals(SyncPushResult.UNCHANGED, restarted.engine(PushTransport { fail("No second HTTP") }).resume(available))
    }

    @Test fun pendingFlushFailureNeverDispatchesAndExactIntentSurvivesRestart() = runTest {
        for (point in listOf("file:sync/push.json", "directory:sync", "directory:<root>")) {
            val h = PushHarness().seed()
            val change = h.candidate()
            h.operations.onOperation = { if (it == point) throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED) }
            assertFailsWith<SyncError.DurabilityUncertain> { h.engine(PushTransport { fail("Flush must precede HTTP") }).push(change, available) }
            val exact = h.data.read("sync/push.json")
            assertFailsWith<SyncError.DurabilityUncertain> { h.pending.load(h.binding) }
            h.operations.onOperation = null
            val restarted = h.restart()
            assertContentEquals(exact, syncDocumentBytes(SyncPendingOperationJson.codec.encode(restarted.pending.load(h.binding)!!)))
            assertEquals(SyncPushResult.REPLAN, restarted.engine(PushTransport { failure(404, ErrorResponse.Failure(FailureCode.NOT_FOUND)) }).resume(available))
            assertNull(restarted.pending.load(h.binding))
        }
    }

    @Test fun sameEngineRefusesConcurrentCallAndPermitRetirementRejectsLateAcknowledgement(): Unit = runBlocking {
        val h = PushHarness().seed()
        val change = h.candidate()
        val started = CompletableDeferred<Unit>()
        val proceed = CompletableDeferred<Unit>()
        val permit = SyncWorkPermit(h.binding, 1)
        val engine = h.engine(PushTransport { started.complete(Unit); proceed.await(); ack(1) }, permit)
        val work = async { runCatching { engine.push(change, available) } }
        started.await()
        assertFailsWith<SyncPushError.Busy> { engine.resume(available) }
        // Another thread must finish an ordinary save while HTTP remains suspended.
        withContext(Dispatchers.Default) {
            val library = h.scan.rig.local.library
            val loaded = library.loadForEditing("a.md")
            library.save(PromptCodec.parseFile(ScanHarness.bytes("Saved during HTTP"), "a.md"), "a.md", loaded.entry.stamp)
        }
        permit.revoke()
        proceed.complete(Unit)
        assertIs<CancellationException>(work.await().exceptionOrNull())
        assertEquals(0, h.record.rev)
        assertNotNull(h.pending.load(h.binding))
    }

    @Test fun unavailableRootAndDuplicateLiveIdentityFailClosed() = runTest {
        val h = PushHarness().seed()
        val change = h.candidate()
        val engine = h.engine(PushTransport { fail("No HTTP") })
        assertFailsWith<SyncReconciliationError.UnavailableLibrary> { engine.push(change, SyncReconciliationSnapshot.Availability.UNAVAILABLE) }
        h.files.put(ScanHarness.bytes(), "duplicate.md")
        assertFailsWith<SyncReconciliationError.InvalidLocalSnapshot> { engine.push(change, available) }
    }

    private fun put(request: HttpRequest): PutPromptRequest = PutPromptRequest.codec.decode(request.body!!)
    private fun ack(rev: Long, seq: Long = 999) = HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(rev, seq)))
    private fun prompt(bytes: ByteArray, rev: Long, scope: PromptScope = PromptScope.User, path: String = "a.md") =
        HttpResponse(200, body = Prompt.codec.encode(Prompt(v.personal.rawValue, rev, scope, path, bytes.decodeToString())))
    private fun conflict(bytes: ByteArray, rev: Long, scope: PromptScope = PromptScope.User, path: String = "a.md") =
        failure(409, ErrorResponse.Conflict(ConflictHead(rev, scope, path, bytes.decodeToString())))
    private fun failure(status: Int, error: ErrorResponse) = HttpResponse(status, body = ErrorResponse.codec.encode(error))
    private fun validation() = failure(422, ErrorResponse.Validation(listOf(Issue("metadata.invalid_type", Severity.ERROR))))
}
