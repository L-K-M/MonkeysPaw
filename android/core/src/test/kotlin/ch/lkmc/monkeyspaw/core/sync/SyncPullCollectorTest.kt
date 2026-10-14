package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.sync.SyncScopeKey
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.MemoryStore
import ch.lkmc.monkeyspaw.core.services.SyncFlushes
import ch.lkmc.monkeyspaw.core.services.SyncStateStore
import ch.lkmc.monkeyspaw.core.services.SyncTestValues
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class SyncPullCollectorTest {
    @Test fun splitMoveRetainsSourceScopesAndExactOpaqueCursors() = runTest {
        val transport = script(
            response(personal(head = 10, cursor = "advanced user", items = listOf(FeedItem.MoveOut(10, prompt.rawValue))),
                team(head = 11, cursor = originalGroup, more = true)),
            response(team(head = 11, cursor = "finished group", items = listOf(upsert(11))),
                personal(head = 10, cursor = "advanced user")))
        val files = MemoryStore()
        collector(transport, files).collect(initial).use { pull ->
            assertEquals(listOf(SyncCollectedItem(userScope, FeedItem.MoveOut(10, prompt.rawValue)),
                SyncCollectedItem(groupScope, upsert(11))), items(pull, Mode.DELTA))
            assertEquals(mapOf(userKey to "advanced user", groupKey to originalGroup), transport.requests[1].cursors)
            assertEquals("finished group", pull.cursors[groupScope])
            assertTrue(items(pull, Mode.SNAPSHOT).isEmpty())
            assertEquals(2, staged(files).size)
            assertTrue(staged(files).all(files::isPrivate))
            assertEquals("server bytes\r\n雪\u0000", assertIs<FeedItem.Upsert>(items(pull, Mode.DELTA)[1].item).prompt.content)
        }
        assertTrue(staged(files).isEmpty())
    }

    @Test fun completeSnapshotsStaySeparateFromTailDeltas() = runTest {
        val transport = script(
            response(personal(Mode.SNAPSHOT, 20, "user snapshot done", items = listOf(upsert(20))),
                team(Mode.SNAPSHOT, 21, "manifest / + = Ω", true, items = listOf(upsert(21, shared)))),
            response(personal(head = 23, cursor = "user tail done", items = listOf(upsert(22, rev = 2))),
                team(Mode.SNAPSHOT, 21, "group snapshot done", items = listOf(upsert(21, another)))))
        collector(transport).collect(PullRequest(null, emptyMap())).use { pull ->
            assertEquals(listOf(20L, 21L, 21L), items(pull, Mode.SNAPSHOT).map { it.seq })
            assertEquals(listOf(SyncCollectedItem(userScope, upsert(22, rev = 2))), items(pull, Mode.DELTA))
            assertEquals(20, pull.scopes[userScope]?.snapshotHead)
            assertEquals(23, pull.scopes[userScope]?.head)
            assertEquals(21, pull.scopes[groupScope]?.snapshotHead)
            assertEquals(database, transport.requests[1].databaseID)
            assertEquals("manifest / + = Ω", transport.requests[1].cursors[groupKey])
        }
    }

    @Test fun emptyZeroHeadAndFairlySkippedScopesDoNotBlockOtherPages() = runTest {
        val empty = script(
            response(personal(Mode.SNAPSHOT, 0, "0"), team(Mode.SNAPSHOT, 7, "manifest", true, items = listOf(upsert(7, shared)))),
            response(personal(Mode.SNAPSHOT, 0, "0"), team(Mode.SNAPSHOT, 7, "done", items = listOf(upsert(7, another)))))
        collector(empty).collect(PullRequest(database, mapOf(userKey to "0", groupKey to "0"))).use { pull ->
            assertEquals(0, pull.scopes[userScope]?.snapshotHead)
            assertEquals(2, items(pull, Mode.SNAPSHOT).size)
        }
        val fair = script(
            response(personal(head = 10, cursor = "u10", more = true, items = listOf(upsert(10))),
                team(Mode.SNAPSHOT, 11, originalGroup, true)),
            response(personal(head = 12, cursor = "u12", items = listOf(upsert(12, rev = 2))),
                team(Mode.SNAPSHOT, 11, "g11", items = listOf(upsert(11)))))
        collector(fair).collect(initial).use { pull ->
            assertEquals(1, items(pull, Mode.SNAPSHOT).size)
            assertEquals(listOf(10L, 12L), items(pull, Mode.DELTA).map { it.seq })
        }
    }

    @Test fun latestRenameAndRoleMetadataWinAndRemovalDropsEarlierItems() = runTest {
        for (remove in listOf(false, true)) {
            val pages = mutableListOf(
                response(personal(head = 10, cursor = "u10", more = true, items = listOf(upsert(10))),
                    team(Mode.SNAPSHOT, 11, "g11", name = "Old", items = listOf(upsert(11)))),
                response(personal(head = 12, cursor = "u12", more = remove, items = listOf(upsert(12, rev = 2))),
                    team(head = 13, cursor = "g13", name = "Renamed", role = Role.VIEWER, items = listOf(upsert(13, rev = 2)))))
            if (remove) pages.add(response(personal(head = 14, cursor = "u14"), removed = listOf(groupKey)))
            collector(script(*pages.toTypedArray())).collect(initial).use { pull ->
                if (remove) {
                    assertEquals(setOf(groupScope), pull.removed)
                    assertNull(pull.cursors[groupScope])
                    assertNull(pull.scopes[groupScope])
                    for (mode in Mode.entries) assertTrue(items(pull, mode).none { it.scope == groupScope })
                } else {
                    assertEquals(ScopeIdentity.Group(group.rawValue, "Renamed", Role.VIEWER), pull.scopes[groupScope]?.identity)
                    assertEquals(1, items(pull, Mode.SNAPSHOT).size)
                    assertEquals(listOf(13L), items(pull, Mode.DELTA).filter { it.scope == groupScope }.map { it.seq })
                }
            }
        }
    }

    @Test fun removedThenRejoinedScopeKeepsOnlyItsFreshSnapshot() = runTest {
        val transport = script(
            response(personal(head = 10, cursor = "u10", more = true), team(Mode.SNAPSHOT, 11, "g11", items = listOf(upsert(11, shared)))),
            response(personal(head = 12, cursor = "u12", more = true), removed = listOf(groupKey)),
            response(personal(head = 14, cursor = "u14"), team(Mode.SNAPSHOT, 13, "g13", items = listOf(upsert(13, another)))))
        collector(transport).collect(initial).use { pull ->
            assertEquals(listOf(SyncCollectedItem(groupScope, upsert(13, another))), items(pull, Mode.SNAPSHOT))
            assertTrue(pull.removed.isEmpty())
            assertNull(transport.requests[2].cursors[groupKey])
        }
    }

    @Test fun newSnapshotSupersedesCompletedSnapshotOrDeltaSegments() = runTest {
        for (firstMode in Mode.entries) {
            val transport = script(
                response(personal(head = 10, cursor = "u10", more = true), team(firstMode, 11, "g11", items = listOf(upsert(11, shared)))),
                response(personal(head = 12, cursor = "u12", more = true), team(Mode.SNAPSHOT, 13, "new manifest", true, items = listOf(upsert(13)))),
                response(personal(head = 14, cursor = "u14"), team(Mode.SNAPSHOT, 13, "g13", items = listOf(upsert(13, another)))))
            collector(transport).collect(initial).use { pull ->
                assertEquals(listOf(upsert(13), upsert(13, another)), items(pull, Mode.SNAPSHOT).map { it.item })
                assertTrue(items(pull, Mode.DELTA).isEmpty())
                assertEquals(13, pull.scopes[groupScope]?.snapshotHead)
            }
        }
    }

    @Test fun databaseChangeDiscardsDetectingResponseAndStartsFreshManifests() = runTest {
        val files = MemoryStore()
        val transport = script(oldPage,
            response(personal(Mode.SNAPSHOT, 2, "ignored", items = listOf(upsert(2))), team(Mode.SNAPSHOT, 0, "0"), databaseID = restored),
            response(personal(Mode.SNAPSHOT, 3, "new database done", items = listOf(upsert(3))), databaseID = restored))
        collector(transport, files).collect(initial).use { pull ->
            assertEquals(restored, pull.databaseID.toString())
            assertEquals(listOf(3L), items(pull, Mode.SNAPSHOT).map { it.seq })
            assertEquals(PullRequest(null, emptyMap()), transport.requests[2])
            assertEquals(setOf(groupScope), pull.removed)
            assertEquals(1, staged(files).size)
        }
    }

    @Test fun firstResponseDatabaseMismatchIsAcceptedAsRestoreWithoutRestart() = runTest {
        val transport = script(response(personal(Mode.SNAPSHOT, 2, "new u", items = listOf(upsert(2))),
            team(Mode.SNAPSHOT, 0, "0"), databaseID = restored))
        collector(transport).collect(initial).use { pull ->
            assertEquals(restored, pull.databaseID.toString())
            assertEquals(1, transport.requests.size)
            assertEquals(2, pull.scopes[userScope]?.snapshotHead)
        }
    }

    @Test fun expiryRewindsAllDiscardedDeltasAndResetsOnlyNamedOriginalCursors() = runTest {
        val files = MemoryStore()
        val transport = ScriptTransport(listOf(http(oldPage), expired,
            http(response(personal(head = 10, cursor = "u10", items = listOf(upsert(10))),
                team(Mode.SNAPSHOT, 12, "g12", items = listOf(upsert(12, another)))))))
        val mutable = initial.cursors.toMutableMap()
        transport.onSend = { index, _ -> if (index == 0) mutable.clear() }
        collector(transport, files).collect(PullRequest(database, mutable)).use { pull ->
            assertEquals(PullRequest(database, mapOf(userKey to originalUser)), transport.requests[2])
            assertEquals(listOf(10L), items(pull, Mode.DELTA).map { it.seq })
            assertEquals(listOf(12L), items(pull, Mode.SNAPSHOT).map { it.seq })
            assertEquals(1, staged(files).size)
        }
    }

    @Test fun expiryAndDatabaseChangesShareOneRestartInBothOrders() = runTest {
        val newer = response(personal(Mode.SNAPSHOT, 5, "new manifest", true), team(Mode.SNAPSHOT, 0, "0"), databaseID = restored)
        val changedAgain = response(personal(Mode.SNAPSHOT, 6, "another manifest", true), team(Mode.SNAPSHOT, 0, "0"))
        val cases = listOf(
            listOf(http(oldPage), expired, http(oldPage), expired) to SyncPullCollectorError.Reason.SNAPSHOT_EXPIRED,
            listOf(http(oldPage), http(newer), http(newer), http(changedAgain)) to SyncPullCollectorError.Reason.DATABASE_CHANGED,
            listOf(http(oldPage), expired, http(oldPage), http(newer)) to SyncPullCollectorError.Reason.DATABASE_CHANGED,
            listOf(http(oldPage), http(newer), http(newer),
                HttpResponse(409, body = ErrorResponse.codec.encode(ErrorResponse.SnapshotExpired(listOf(userKey))))) to
                SyncPullCollectorError.Reason.SNAPSHOT_EXPIRED)
        for ((pages, reason) in cases) {
            val files = MemoryStore()
            noProgress(reason) { collector(ScriptTransport(pages), files).collect(initial) }
            assertTrue(staged(files).isEmpty())
        }
    }

    @Test fun expiryCannotResetAnUnrequestedScope() = runTest {
        val transport = ScriptTransport(listOf(HttpResponse(409,
            body = ErrorResponse.codec.encode(ErrorResponse.SnapshotExpired(listOf(groupKey))))))
        assertFailsWith<SyncPullCollectorError.InvalidResponse> {
            collector(transport).collect(PullRequest(null, emptyMap()))
        }
        assertEquals(1, transport.requests.size)
    }

    @Test fun invalidPathsAndForeignAuthenticatedScopesFailBeforeStaging() = runTest {
        for (path in listOf("../evil.md", "/evil.md", "Groups/evil.md", ".hidden/evil.md", "a\\b.md", "a.md\u0000", "Cafe\u0301.md")) {
            val files = MemoryStore()
            val transport = script(response(personal(head = 10, cursor = "u10", items = listOf(upsert(10, path = path))),
                team(head = 0, cursor = originalGroup)))
            assertFailsWith<SyncPullCollectorError.InvalidResponse> { collector(transport, files).collect(initial) }
            assertTrue(files.writes.isEmpty())
        }
        val foreign = SyncScope(ScopeIdentity.User(SyncTestValues.otherUser.rawValue), Mode.SNAPSHOT, 1, "1", false, listOf(upsert(1)))
        assertFailsWith<SyncPullCollectorError.InvalidResponse> {
            collector(script(response(foreign))).collect(PullRequest(null, emptyMap()))
        }
    }

    @Test fun malformedAndForeignInitialRequestsNeverDispatch() = runTest {
        val transport = ScriptTransport(emptyList())
        for (request in listOf(PullRequest("bad uuid", emptyMap()), PullRequest(database, mapOf("bad key" to "opaque")),
            PullRequest(database, mapOf(userKey to "")), PullRequest(database, mapOf(userKey to "\uD800")),
            PullRequest(database, mapOf(SyncScopeKey.User(SyncTestValues.otherUser).rawValue to "opaque")))) {
            assertFailsWith<SyncPullCollectorError.InvalidRequest> { collector(transport).collect(request) }
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun malformedWireIDsMetadataAndItemBudgetsFailAfterCleaningEarlierPages() = runTest {
        val invalid = listOf(
            response(personal(head = 10, cursor = "u11", items = listOf(FeedItem.Upsert(10, FeedPrompt("bad", 1, "a.md", "body")))), team(head = 0, cursor = originalGroup)),
            response(personal(head = 10, cursor = "u11", items = listOf(FeedItem.Delete(10, "bad"))), team(head = 0, cursor = originalGroup)),
            response(personal(head = 10, cursor = "u11", items = listOf(FeedItem.MoveOut(10, "bad"))), team(head = 0, cursor = originalGroup)),
            response(personal(head = 10, cursor = "u11", items = listOf(upsert(10, rev = 0))), team(head = 0, cursor = originalGroup)),
            response(personal(Mode.SNAPSHOT, 10, "u11", items = listOf(FeedItem.Delete(10, prompt.rawValue))), team(head = 0, cursor = originalGroup)),
            response(personal(head = 9, cursor = "u11", items = listOf(upsert(10))), team(head = 0, cursor = originalGroup)),
            response(personal(head = 10, cursor = "u11", items = List(101) { upsert(10) }), team(head = 10, cursor = "g10", items = List(100) { upsert(10) })),
            response(personal(head = 10, cursor = "u11"), personal(head = 10, cursor = "u11")),
            response(personal(head = 10, cursor = "u11"), removed = listOf("group:bad")))
        val good = response(personal(head = 10, cursor = "u10", more = true, items = listOf(upsert(10))), team(head = 0, cursor = originalGroup))
        val brokenBodies = invalid.map { WireJson.canonical(PullResponse.codec.encodeValue(it)) } +
            listOf(http(good).body.decodeToString().replace("\"role\":\"editor\"", "\"role\":\"invalid\"").toByteArray(),
                http(good).body.decodeToString().replace("\"group_id\":\"${group.rawValue}\"", "\"group_id\":\"${user.rawValue}\"").toByteArray())
        for (body in brokenBodies) {
            val files = MemoryStore()
            val transport = ScriptTransport(listOf(http(good), HttpResponse(200, body = body)))
            assertFailsWith<SyncHTTPClientError.MalformedResponse> { collector(transport, files).collect(initial) }
            assertTrue(staged(files).isEmpty())
        }
    }

    @Test fun missingRequestedScopesUserRemovalAndUnrequestedDeltasAreRejected() = runTest {
        val cases = listOf(
            response(personal(head = 10, cursor = "u10")) to initial,
            response(personal(head = 10, cursor = "u10"), removed = listOf(SyncScopeKey.User(SyncTestValues.otherUser).rawValue)) to initial,
            response(personal(head = 10, cursor = "u10")) to PullRequest(database, emptyMap()),
            response(personal(head = 10, cursor = "u10"), team(Mode.SNAPSHOT, 0, "0"), databaseID = restored) to initial)
        for ((page, request) in cases) {
            val files = MemoryStore()
            assertFailsWith<SyncPullCollectorError.InvalidResponse> { collector(script(page), files).collect(request) }
            assertTrue(files.writes.isEmpty())
        }
    }

    @Test fun stalledWholeContinuationFailsButOpaqueCursorSpellingRemainsExact() = runTest {
        val page = response(personal(head = 10, cursor = "next", more = true), team(head = 0, cursor = originalGroup))
        val files = MemoryStore()
        noProgress(SyncPullCollectorError.Reason.STALLED_CONTINUATION) { collector(script(page, page), files).collect(initial) }
        assertTrue(staged(files).isEmpty())
        val opaque = script(
            response(personal(Mode.SNAPSHOT, 10, "opaque-é", true, listOf(upsert(10))), team(head = 0, cursor = originalGroup)),
            response(personal(Mode.SNAPSHOT, 10, "opaque-e\u0301", true, listOf(upsert(10, shared))), team(head = 0, cursor = originalGroup)),
            response(personal(Mode.SNAPSHOT, 10, "done", items = listOf(upsert(10, another))), team(head = 0, cursor = originalGroup)))
        collector(opaque).collect(initial).use { pull ->
            assertEquals(3, items(pull, Mode.SNAPSHOT).size)
            assertContentEquals("opaque-e\u0301".toByteArray(), opaque.requests[2].cursors.getValue(userKey).toByteArray())
        }
    }

    @Test fun completionCanProgressWhileAnotherScopeKeepsTheSameCursor() = runTest {
        val page = response(personal(head = 10, cursor = "u10", more = true), team(Mode.SNAPSHOT, 11, "manifest", true))
        val transport = script(page, response(personal(head = 10, cursor = "u10", more = true), team(Mode.SNAPSHOT, 11, "manifest")),
            response(personal(head = 10, cursor = "u10"), team(head = 11, cursor = "manifest")))
        collector(transport).collect(initial).use { assertEquals(3, transport.requests.size) }
    }

    @Test fun incompleteSnapshotCannotChangeHeadSwitchModeOrRepeatIDs() = runTest {
        val first = personal(Mode.SNAPSHOT, 10, "manifest", true, listOf(upsert(10)))
        for (next in listOf(personal(head = 11, cursor = "done", items = listOf(upsert(11))),
            personal(Mode.SNAPSHOT, 11, "done", items = listOf(upsert(11))),
            personal(Mode.SNAPSHOT, 10, "done", items = listOf(upsert(10))))) {
            val files = MemoryStore()
            assertFailsWith<SyncPullCollectorError.InvalidResponse> {
                collector(script(response(first, team(head = 0, cursor = originalGroup)),
                    response(next, team(head = 0, cursor = originalGroup))), files).collect(initial)
            }
            assertTrue(staged(files).isEmpty())
        }
        assertFailsWith<SyncPullCollectorError.InvalidResponse> {
            collector(script(response(personal(Mode.SNAPSHOT, 10, "done", items = listOf(upsert(10, another), upsert(10))),
                team(Mode.SNAPSHOT, 0, "0")))).collect(PullRequest(null, emptyMap()))
        }
    }

    @Test fun deltasMustAdvanceWithinAndAcrossPagesAndFollowSnapshotHead() = runTest {
        val pairs = listOf(
            personal(head = 10, cursor = "u10", more = true, items = listOf(upsert(10))) to
                personal(head = 11, cursor = "u11", items = listOf(upsert(10))),
            personal(Mode.SNAPSHOT, 10, "u10", items = listOf(upsert(10))) to
                personal(head = 11, cursor = "u11", items = listOf(upsert(10))),
            personal(head = 10, cursor = "u10", more = true, items = listOf(upsert(10), upsert(9))) to
                personal(head = 11, cursor = "u11"),
            personal(head = 10, cursor = originalUser, more = true, items = listOf(upsert(10))) to
                personal(head = 11, cursor = "u11"))
        for ((first, next) in pairs) {
            val files = MemoryStore()
            assertFailsWith<SyncPullCollectorError.InvalidResponse> {
                collector(script(response(first, team(Mode.SNAPSHOT, 5, "manifest", true)),
                    response(next, team(Mode.SNAPSHOT, 5, "g5"))), files).collect(initial)
            }
            assertTrue(staged(files).isEmpty())
        }
    }

    @Test fun fiveMinuteBudgetIncludesStagingAndTheSharedRestart() = runTest {
        assertEquals(60_000_000_000L, Limits.syncRequestTimeoutNanos)
        assertEquals(300_000_000_000L, Limits.syncCollectionBudgetNanos)
        assertEquals(1, Limits.syncCollectionRestartLimit)
        var now = 0L
        val files = MemoryStore().apply { onWrite = { now += 151_000_000_000L } }
        val transport = ScriptTransport(listOf(http(oldPage), expired,
            http(response(personal(head = 10, cursor = "u10"), team(Mode.SNAPSHOT, 11, "done")))))
        noProgress(SyncPullCollectorError.Reason.COLLECTION_DEADLINE) {
            collector(transport, files, MonotonicClock { now }).collect(initial)
        }
        assertEquals(3, transport.requests.size)
        assertTrue(staged(files).isEmpty())
    }

    @Test fun suppliedDeadlinesOnlyShortenBudgetAndPreserveNanoTimeWrap() = runTest {
        for (now in listOf(123L, Long.MAX_VALUE - 100L)) {
            val clock = MonotonicClock { now }
            val transport = script(response(personal(head = 10, cursor = "u10"), team(head = 0, cursor = originalGroup)),
                response(personal(head = 10, cursor = "u10"), team(head = 0, cursor = originalGroup)))
            for (budget in listOf(5_000_000_000L, 600_000_000_000L)) {
                collector(transport, clock = clock).collect(initial, now + budget).use {
                    assertEquals(minOf(budget, 60_000_000_000L), transport.rawRequests.last().deadlineNanos - now)
                }
            }
            for (deadline in listOf(now, now - 1L)) {
                noProgress(SyncPullCollectorError.Reason.COLLECTION_DEADLINE) { collector(transport, clock = clock).collect(initial, deadline) }
            }
            assertEquals(2, transport.requests.size)
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun inFlightDeadlineCancelsTransportAndCleansIncompletePages() = runTest {
        val files = MemoryStore()
        var requests = 0
        var released = false
        val transport = HttpTransport {
            if (requests++ == 0) http(oldPage)
            else try { awaitCancellation() } finally { released = true }
        }
        noProgress(SyncPullCollectorError.Reason.COLLECTION_DEADLINE) {
            collector(transport, files, MonotonicClock { testScheduler.currentTime * 1_000_000L }).collect(initial, 20_000_000L)
        }
        assertTrue(released)
        assertEquals(20, testScheduler.currentTime)
        assertTrue(staged(files).isEmpty())
    }

    @Test fun cancellationAfterAnEarlierPageCleansOnlyItsOwnedStage() = runTest {
        val files = MemoryStore().apply { put("canary", "sync/pull-other.json") }
        var requests = 0
        var failure: SyncHTTPClientError? = null
        var released = false
        val task = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                collector(HttpTransport {
                    if (requests++ == 0) http(oldPage)
                    else try { awaitCancellation() } finally { released = true }
                }, files).collect(initial)
            } catch (error: SyncHTTPClientError) { failure = error }
        }
        assertEquals(2, requests)
        assertEquals(2, staged(files).size)
        task.cancelAndJoin()
        assertTrue(released)
        assertEquals(HttpTransportError.Cancelled, assertIs<SyncHTTPClientError.Transport>(failure).error)
        assertEquals(listOf("sync/pull-other.json"), staged(files))
    }

    @Test fun libraryStateAndCommittedCursorBytesStayUntouchedThroughCompletion() = runTest {
        val files = MemoryStore()
        val library = MemoryStore().apply { put("local bytes", "local.md") }
        val flushes = SyncFlushes()
        val states = SyncStateStore(files, flushes)
        val state = SyncTestValues.state()
        states.update(state.binding) { state }
        files.put("other", "other.json")
        files.put("journal", "sync/apply.json")
        val originalBytes = files.read("sync/state.json")
        val originalStamp = files.stamp("sync/state.json")
        val flushCount = flushes.calls.size
        val libraryAccesses = library.accesses
        val writes = mutableListOf<String>()
        files.onWrite = { writes.add(it) }
        val transport = script(oldPage, response(personal(head = 12, cursor = "u12", items = listOf(upsert(12, rev = 2))),
            team(Mode.SNAPSHOT, 11, "g11", items = listOf(upsert(11, another)))))
        transport.onSend = { index, request ->
            assertContentEquals(originalBytes, files.read("sync/state.json"))
            assertEquals(originalStamp, files.stamp("sync/state.json"))
            assertEquals("other", files.text("other.json"))
            assertEquals("journal", files.text("sync/apply.json"))
            assertEquals(libraryAccesses, library.accesses)
            assertEquals(60_000_000_000L, request.deadlineNanos)
            assertEquals(index, staged(files).size)
        }
        collector(transport, files).collect(initial).use { pull ->
            assertEquals(state, states.load(state.binding))
            assertContentEquals(originalBytes, files.read("sync/state.json"))
            assertEquals(2, items(pull, Mode.DELTA).size)
            assertTrue(writes.all { it.startsWith("sync/pull-") })
        }
        assertContentEquals(originalBytes, files.read("sync/state.json"))
        assertEquals(originalStamp, files.stamp("sync/state.json"))
        assertEquals(flushCount, flushes.calls.size)
        assertEquals(libraryAccesses, library.accesses)
        assertEquals("journal", files.text("sync/apply.json"))
    }

    @Test fun failedPublicationCleansEvenTheFileLeftByItsDriver() = runTest {
        val files = MemoryStore().apply { put("canary", "sync/pull-other.json") }
        val broken = object : StateStore by files {
            override fun writePrivate(bytes: ByteArray, path: String) {
                files.writePrivate(bytes, path)
                throw StoreError.IOFailure
            }
        }
        val error = assertFailsWith<SyncPullCollectorError.StagingFailed> {
            collector(script(response(personal(head = 10, cursor = "u10"), team(head = 0, cursor = originalGroup))), broken).collect(initial)
        }
        assertEquals(StoreError.IOFailure, error.error)
        assertEquals(listOf("sync/pull-other.json"), staged(files))
    }

    @Test fun scopedHandleCleanupAlsoRunsWhenItsConsumerThrows() = runTest {
        val files = MemoryStore().apply { put("canary", "sync/pull-other.json") }
        assertFailsWith<IllegalStateException> {
            collector(script(response(personal(head = 10, cursor = "u10", items = listOf(upsert(10))),
                team(head = 0, cursor = originalGroup))), files).collect(initial).use { pull ->
                pull.forEachPage(Mode.DELTA) { throw IllegalStateException("consumer failed") }
            }
        }
        assertEquals(listOf("sync/pull-other.json"), staged(files))
    }

    @Test fun closeIsIdempotentAndCleanupFailureIsReportedAndRetryable() = runTest {
        val files = MemoryStore()
        val page = response(personal(head = 10, cursor = "u10"), team(Mode.SNAPSHOT, 11, "g11"))
        val pull = collector(script(oldPage, page), files).collect(initial)
        val paths = staged(files)
        files.fault = { operation, path -> if (operation == MemoryStore.Operation.DELETE && path == paths.first()) StoreError.IOFailure else null }
        assertEquals(StoreError.IOFailure, assertFailsWith<SyncPullCollectorError.StagingFailed> { pull.close() }.error)
        assertEquals(listOf(paths.first()), staged(files))
        files.fault = null
        pull.close()
        pull.close()
        assertTrue(staged(files).isEmpty())
        assertFailsWith<SyncPullCollectorError.InvalidResponse> { pull.forEachPage(Mode.DELTA) {} }
    }

    @Test fun transportAndAuthenticationFailuresPreserveTheirTypesAndCleanStaging() = runTest {
        val responses = listOf(
            HttpResponse(401, body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.UNAUTHORIZED))),
            HttpResponse(500, body = "untrusted body".toByteArray()))
        for (reply in responses) {
            val files = MemoryStore()
            val error = assertFailsWith<SyncHTTPClientError> {
                collector(ScriptTransport(listOf(http(oldPage), reply)), files).collect(initial)
            }
            if (reply.statusCode == 401) assertEquals(SyncHTTPClientError.Unauthorized, error)
            else assertEquals(500, assertIs<SyncHTTPClientError.ServerFailure>(error).statusCode)
            assertTrue(staged(files).isEmpty())
        }
        val files = MemoryStore()
        val transport = ScriptTransport(listOf(http(oldPage)))
        val error = assertFailsWith<SyncHTTPClientError.Transport> { collector(transport, files).collect(initial) }
        assertEquals(HttpTransportError.NetworkFailure, error.error)
        assertTrue(staged(files).isEmpty())
    }

    @Test fun concurrentCollectionsOwnDisjointStages() = runTest {
        val files = MemoryStore().apply { put("canary", "sync/pull-other.json") }
        val page = response(personal(head = 10, cursor = "u10"), team(head = 0, cursor = originalGroup))
        val first = collector(script(page), files).collect(initial)
        collector(script(page), files).collect(initial).use { second ->
            assertEquals(3, staged(files).size)
            first.close()
            assertEquals(2, staged(files).size)
            assertEquals(2, pages(second, Mode.DELTA).size)
        }
        assertEquals(listOf("sync/pull-other.json"), staged(files))
    }

    @Test fun stagedReadsAreCappedAndRejectMalformedOrForeignDatabaseBytes() = runTest {
        val page = response(personal(head = 10, cursor = "u10", items = listOf(upsert(10))), team(head = 0, cursor = originalGroup))
        val bytes = PullResponse.codec.encode(page)
        val bad = listOf("{}".toByteArray(), PullResponse.codec.encode(page.copy(databaseID = restored)), ByteArray(Limits.syncResponseCap + 1))
        for (replacement in bad) {
            val files = MemoryStore()
            collector(script(page), files).collect(initial).use { pull ->
                files.put(replacement, staged(files).single())
                assertFailsWith<SyncPullCollectorError.InvalidResponse> { items(pull, Mode.DELTA) }
            }
        }
        val files = MemoryStore()
        collector(script(page), files).collect(initial).use { pull ->
            val atCap = ByteArray(16 * 1024 * 1024) { 32 }
            bytes.copyInto(atCap)
            files.put(atCap, staged(files).single())
            assertEquals(listOf(SyncCollectedItem(userScope, upsert(10))), items(pull, Mode.DELTA))
            files.fault = { operation, _ -> if (operation == MemoryStore.Operation.READ) IllegalStateException("private diagnostic") else null }
            val error = assertFailsWith<SyncPullCollectorError.StagingFailed> { items(pull, Mode.DELTA) }
            assertEquals(StoreError.IOFailure, error.error)
            assertNull(error.cause)
            assertTrue(error.suppressed.isEmpty())
            assertFalse(error.toString().contains("private diagnostic"))
            files.fault = null
        }
    }

    @Test fun completeResultsOwnTheirCollectionsAndRedactDiagnostics() = runTest {
        collector(script(response(personal(head = 10, cursor = "private cursor", items = listOf(upsert(10))),
            team(head = 0, cursor = originalGroup)))).collect(initial).use { pull ->
            assertFailsWith<UnsupportedOperationException> { (pull.scopes as MutableMap).clear() }
            assertFailsWith<UnsupportedOperationException> { (pull.removed as MutableSet).add(groupScope) }
            assertFailsWith<UnsupportedOperationException> { (pull.cursors as MutableMap).clear() }
            val page = pages(pull, Mode.DELTA).first()
            assertFailsWith<UnsupportedOperationException> { (page.items as MutableList).clear() }
            for (value in listOf(pull, pull.scopes.getValue(userScope), page, page.items.first(),
                SyncPullCollectorError.InvalidRequest, SyncPullCollectorError.NoProgress(SyncPullCollectorError.Reason.COLLECTION_DEADLINE))) {
                assertFalse(value.toString().contains("private cursor"))
                assertFalse(value.toString().contains("server bytes"))
            }
        }
    }

    private fun collector(transport: HttpTransport, files: StateStore = MemoryStore(), clock: MonotonicClock = MonotonicClock { 0L }): SyncPullCollector {
        val server = SyncServerURL("https://example.test/paw")
        val client = SyncHTTPClient(server, transport, SyncCredential(server, SecretValue("a".repeat(42) + "A")), clock)
        return SyncPullCollector(client, files, user, clock)
    }

    private fun personal(mode: Mode = Mode.DELTA, head: Long, cursor: String, more: Boolean = false, items: List<FeedItem> = emptyList()) =
        SyncScope(ScopeIdentity.User(user.rawValue), mode, head, cursor, more, items)

    private fun team(mode: Mode = Mode.DELTA, head: Long, cursor: String, more: Boolean = false, name: String = "Team",
                     role: Role = Role.EDITOR, items: List<FeedItem> = emptyList()) =
        SyncScope(ScopeIdentity.Group(group.rawValue, name, role), mode, head, cursor, more, items)

    private fun upsert(seq: Long, id: ULID = prompt, path: String = "a.md", rev: Long = 1): FeedItem =
        FeedItem.Upsert(seq, FeedPrompt(id.rawValue, rev, path, "server bytes\r\n雪\u0000"))

    private fun response(vararg scopes: SyncScope, removed: List<String> = emptyList(), databaseID: String = database) =
        PullResponse(databaseID, scopes.toList(), removed)

    private fun http(response: PullResponse) = HttpResponse(200, body = PullResponse.codec.encode(response))
    private fun script(vararg pages: PullResponse) = ScriptTransport(pages.map(::http))
    private fun pages(pull: SyncCollectedPull, mode: Mode) = mutableListOf<SyncCollectedPage>().also { result -> pull.forEachPage(mode) { result.add(it) } }
    private fun items(pull: SyncCollectedPull, mode: Mode) = pages(pull, mode).flatMap { it.items }
    private fun staged(files: MemoryStore) = files.listFiles().map { it.relativePath }.filter { it.startsWith("sync/pull-") }

    private suspend fun noProgress(reason: SyncPullCollectorError.Reason, body: suspend () -> Unit) {
        assertEquals(reason, assertFailsWith<SyncPullCollectorError.NoProgress> { body() }.reason)
    }

    private class ScriptTransport(private val responses: List<HttpResponse>) : HttpTransport {
        val rawRequests = mutableListOf<HttpRequest>()
        val requests: List<PullRequest> get() = rawRequests.map { PullRequest.codec.decode(it.body!!) }
        var onSend: ((Int, HttpRequest) -> Unit)? = null
        override suspend fun send(request: HttpRequest): HttpResponse {
            val index = rawRequests.size
            rawRequests.add(request)
            onSend?.invoke(index, request)
            return responses.getOrNull(index) ?: throw HttpTransportError.NetworkFailure
        }
    }

    private val user = SyncTestValues.user
    private val group = SyncTestValues.group
    private val prompt = SyncTestValues.personal
    private val shared = SyncTestValues.groupPrompt
    private val another = SyncTestValues.device
    private val database = SyncTestValues.uuid.toString()
    private val restored = "22222222-2222-4222-8222-222222222222"
    private val userScope = SyncScopeKey.User(user)
    private val groupScope = SyncScopeKey.Group(group)
    private val userKey = userScope.rawValue
    private val groupKey = groupScope.rawValue
    private val originalUser = "original user / Ω +=\u0000"
    private val originalGroup = "original group"
    private val initial get() = PullRequest(database, mapOf(userKey to originalUser, groupKey to originalGroup))
    private val oldPage get() = response(personal(head = 10, cursor = "u10", more = true, items = listOf(upsert(10))),
        team(Mode.SNAPSHOT, 11, "manifest", true, items = listOf(upsert(11, shared))))
    private val expired get() = HttpResponse(409, body = ErrorResponse.codec.encode(ErrorResponse.SnapshotExpired(listOf(groupKey))))
}
