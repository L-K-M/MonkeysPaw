package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.test.*

class SyncReviewClaimsTest {
    private val v = SyncTestValues
    private fun source(body: String) = "---\nid: '${v.personal.rawValue}'\n---\n$body"
    private fun workers() = Executors.newFixedThreadPool(2) { work -> Thread(work).apply { isDaemon = true } }

    @Test fun usageObserverReleasesItsStoreBeforeConcurrentSaveNeedsTheCache() {
        val h = ServiceHarness()
        val entry = h.put(source("old"))
        h.index.rebuild()
        val writing = CountDownLatch(1)
        val saving = CountDownLatch(1)
        val observing = CountDownLatch(1)
        val publish = h.usage.onRecord
        h.usage.onRecord = { identity, events -> observing.countDown(); publish(identity, events) }
        h.state.onWrite = { path -> if (path.startsWith("usage/")) {
            writing.countDown()
            check(saving.await(5, TimeUnit.SECONDS))
        } }
        h.prompts.onRead = {
            saving.countDown()
            check(observing.await(5, TimeUnit.SECONDS))
        }
        val workers = workers()
        val at = Instant.ofEpochSecond(10)
        try {
            val record = workers.submit<List<Instant>> { h.usage.recordUse(entry.identity, at) }
            assertTrue(writing.await(5, TimeUnit.SECONDS))
            val save = workers.submit<LibrarySaveResult> { h.library.save(h.draft(source("new")), "a.md", entry.stamp) }
            save.get(5, TimeUnit.SECONDS)
            assertEquals(listOf(at), record.get(5, TimeUnit.SECONDS))
            assertEquals(listOf(at), h.index.snapshot().prompts.single().useEvents)
            h.usage.recordUse(entry.identity, at)
            assertEquals(listOf(at, at), h.index.snapshot().prompts.single().useEvents)
        } finally {
            saving.countDown()
            observing.countDown()
            workers.shutdownNow()
        }
    }

    @Test fun delayedUsageObserverPublishesLatestCacheWithoutAppendingOrRollingItBack() {
        val h = ServiceHarness()
        val entry = h.put(source("body"))
        h.index.rebuild()
        val firstObserver = CountDownLatch(1)
        val release = CountDownLatch(1)
        val publish = h.usage.onRecord
        h.usage.onRecord = { identity, events ->
            if (events.size == 1) {
                firstObserver.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
            publish(identity, events)
        }
        val workers = workers()
        val first = Instant.ofEpochSecond(10)
        val second = Instant.ofEpochSecond(20)
        try {
            val record = workers.submit<List<Instant>> { h.usage.recordUse(entry.identity, first) }
            assertTrue(firstObserver.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(first, second), workers.submit<List<Instant>> {
                h.usage.recordUse(entry.identity, second)
            }.get(5, TimeUnit.SECONDS))
            assertEquals(listOf(first, second), h.index.snapshot().prompts.single().useEvents)
            release.countDown()
            assertEquals(listOf(first), record.get(5, TimeUnit.SECONDS))
            assertEquals(listOf(first, second), h.index.snapshot().prompts.single().useEvents)
            assertEquals(listOf(first, second), h.usage.useEvents(entry.identity))
        } finally { release.countDown(); workers.shutdownNow() }
    }

    @Test fun editorHistoryWaitsForTheWholeMoveWhileValuesKeepTheirOwnBoundary() {
        val h = ServiceHarness()
        val old = h.put("idless")
        val revision = h.history.snapshot("previous".encodeToByteArray(), old.identity, h.clock.date)
        h.usage.recordUse(old.identity)
        h.values.record(old.identity, mapOf("field" to "before"))
        val migratingUsage = CountDownLatch(1)
        val readingHistory = CountDownLatch(1)
        val release = CountDownLatch(1)
        h.state.onMove = { path, _ -> if (path.startsWith("usage/")) {
            migratingUsage.countDown()
            check(release.await(5, TimeUnit.SECONDS))
        } }
        val workers = workers()
        try {
            val move = workers.submit<LibraryMoveResult> { h.library.move("a.md", "b.md", old.stamp) }
            assertTrue(migratingUsage.await(5, TimeUnit.SECONDS))
            val history = workers.submit<List<PromptHistorySnapshot>> {
                readingHistory.countDown()
                h.editing.history(old.identity, "a.md")
            }
            assertTrue(readingHistory.await(5, TimeUnit.SECONDS))
            assertFailsWith<TimeoutException> { history.get(200, TimeUnit.MILLISECONDS) }
            h.values.record(old.identity, mapOf("field" to "during move"))
            release.countDown()
            val target = (move.get(5, TimeUnit.SECONDS) as LibraryMoveResult.Moved).entry.identity
            assertTrue(history.get(5, TimeUnit.SECONDS).isEmpty())
            val movedHistory = h.editing.history(target, "b.md").single()
            assertEquals(revision.copy(identity = target), movedHistory.revision)
            assertContentEquals("previous".encodeToByteArray(), movedHistory.sourceBytes)
            assertEquals(mapOf("field" to "during move"), h.values.rememberedValues(target))
            assertTrue(h.values.rememberedValues(old.identity).isEmpty())
            assertEquals(1, h.usage.useEvents(target).size)
        } finally { release.countDown(); workers.shutdownNow() }
    }

    @Test fun canReplanPropagatesUncertainReadsAndOnlyDecidesFromStableEvidence() {
        for (published in listOf(false, true)) {
            val h = SyncMutationHarness()
            val old = h.put("idless")
            h.local.values.record(old.identity, mapOf("field" to "remembered"))
            val edit = h.mutations.publication(source("new").encodeToByteArray(), old.path, old,
                SyncIdentityTransition(old.identity, v.personalID), kind = SyncLibraryEdit.Kind.ADOPT)
            val migrations = h.mutations.prepareMigrations(edit)
            val keyed = h.local.state.bytesSnapshot()
            h.local.prompts.onRead = { path ->
                h.local.prompts.onRead = null
                if (published) h.local.prompts.put(edit.bytes!!, path) else h.local.prompts.delete(path)
            }
            assertFailsWith<LibraryError.Conflict> { h.mutations.canReplan(edit, migrations, false) }
            assertEquals(keyed, h.local.state.bytesSnapshot())
            assertEquals(!published, h.mutations.canReplan(edit, migrations, false))
            h.mutations.migrate(migrations.single(), SyncFlushes())
            assertFalse(h.mutations.canReplan(edit, migrations, false))
            assertTrue(h.mutations.canReplan(edit, migrations, true))
        }
    }

    @Test fun forgetAllStillResetsUnreadableValuesOfflineAfterSyncRecoverySettles() {
        for (owned in listOf(false, true)) {
            val h = ServiceHarness()
            h.state.put("corrupt values", "values.json")
            val before = h.state.bytesSnapshot()
            val owner = UUID.randomUUID()
            if (owned) h.library.beginSyncApply(owner, v.state())
            h.library.blockSyncApplyForRecovery()
            h.state.onRead = { fail("Forget all must not read rejected values") }
            val accesses = h.state.accesses
            assertFailsWith<LibraryError.RecoveryRequired> { h.fill.forgetAllValues() }
            assertEquals(accesses, h.state.accesses)
            assertEquals(before, h.state.bytesSnapshot())
            // The journal owns validation/durability; these exercise its Y2 gate completion seams.
            h.library.finishEmptySyncRecovery()
            if (owned) {
                assertFailsWith<LibraryError.RecoveryRequired> { h.fill.forgetAllValues() }
                assertEquals(before, h.state.bytesSnapshot())
                h.library.resumeSyncApply(owner, v.state())
                h.library.endSyncApply(owner)
            }
            h.fill.forgetAllValues()
            h.state.onRead = null
            assertEquals("{\"values\":{},\"version\":1}", h.state.text("values.json"))
            assertTrue(h.state.isPrivate("values.json"))
            h.values.record(v.personalID, mapOf("field" to "after recovery"))
            assertEquals(mapOf("field" to "after recovery"), h.values.rememberedValues(v.personalID))
        }
    }
}
