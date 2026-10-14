package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.*
import kotlin.test.*

class SyncKeyedMigrationTest {
    private val v = SyncTestValues

    @Test fun everyOrdinaryLibraryReadAndMutationRefusesTheRecoveryGateBeforeIO() {
        val h = ServiceHarness()
        val entry = h.put("body")
        val revision = h.history.snapshot("old".encodeToByteArray(), entry.identity, h.clock.date)
        val id = UUID.randomUUID()
        h.library.beginSyncApply(id, SyncState(v.binding()))
        val accesses = h.prompts.accesses + h.state.accesses
        val commands: List<() -> Any?> = listOf(
            { h.library.entries() }, { h.library.load("a.md") }, { h.library.loadForEditing("a.md") },
            { h.library.save(h.draft("body"), "a.md") }, { h.library.create(h.draft("body"), "new.md") },
            { h.library.assignIdentity("a.md") }, { h.library.toggleFavorite(entry) },
            { h.library.move("a.md", "b.md") }, { h.library.delete("a.md") },
            { h.library.restore(revision, "a.md") }, { h.history.revisions(entry.identity) }, { h.history.read(revision) },
        )
        commands.forEach { assertFailsWith<LibraryError.RecoveryRequired> { it() } }
        assertEquals(accesses, h.prompts.accesses + h.state.accesses)
        assertEquals(LibraryError.RecoveryRequired, (h.editing.load("a.md") as PromptLoadResult.Failed).error)
        assertEquals("body", h.library.withSyncLock { it.read("a.md").decodeToString() })
        h.library.endSyncApply(UUID.randomUUID())
        assertFailsWith<LibraryError.RecoveryRequired> { h.library.load("a.md") }
        h.library.endSyncApply(id)
        assertEquals(entry.stamp, h.library.load("a.md").stamp)
        assertEquals(entry.identity, h.library.load("a.md").identity)
    }

    @Test fun keyedWritesRemovalsAndOrdinaryMigrationsCannotBypassRecovery() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        val to = v.personalID
        val revision = h.history.snapshot("old".encodeToByteArray(), from, h.clock.date)
        h.values.record(from, mapOf("name" to "remembered"))
        h.usage.recordUse(from)
        h.library.blockSyncApplyForRecovery()
        val snapshot = h.state.bytesSnapshot()
        val accesses = h.state.accesses
        val writes: List<() -> Any?> = listOf(
            { h.values.record(from, mapOf("name" to "new")) }, { h.values.remove(from) }, { h.values.removeAll() },
            { h.values.migrateKey(from, to) }, { h.values.migrateKey(from, from) },
            { h.usage.recordUse(from) }, { h.usage.migrateKey(from, to) }, { h.usage.migrateKey(from, from) },
            { h.history.snapshot(byteArrayOf(1), from, h.clock.date) }, { h.history.remove(revision) },
            { h.history.prune(from) }, { h.history.migrateKey(from, to) },
        )
        writes.forEach { assertFailsWith<LibraryError.RecoveryRequired> { it() } }
        h.values.record(from, emptyMap()) // No mutation, including no IO, preserves the existing empty-input contract.
        assertEquals(accesses, h.state.accesses)
        assertEquals(snapshot, h.state.bytesSnapshot())
        h.library.finishEmptySyncRecovery()
        h.values.removeAll()
        assertTrue(h.values.rememberedValues(from).isEmpty())
    }

    @Test fun blockedOwnersRetainIntendedStateUntilValidatedRecoveryResumes() {
        val h = ServiceHarness()
        val first = UUID.randomUUID()
        val next = UUID.randomUUID()
        val state = v.state()
        h.library.beginSyncApply(first, state)
        h.library.blockSyncApplyForRecovery()
        assertTrue(h.library.hasUnreadableSyncJournal)
        assertEquals(SyncRecoveryGate.Permit(first, state), h.library.pendingSyncApplyPermit)
        assertFailsWith<LibraryError.RecoveryRequired> { h.library.beginSyncApply(first, state) }
        assertFailsWith<LibraryError.RecoveryRequired> { h.library.replaceSyncApply(first, next, state) }
        h.library.endSyncApply(first)
        h.library.finishEmptySyncRecovery()
        assertTrue(h.library.hasUnreadableSyncJournal)
        assertEquals(first, h.library.pendingSyncApplyPermit?.id)
        h.library.resumeSyncApply(next, state)
        assertFalse(h.library.hasUnreadableSyncJournal)
        assertFailsWith<LibraryError.RecoveryRequired> { h.library.entries() }
        h.library.endSyncApply(first)
        assertEquals(next, h.library.pendingSyncApplyPermit?.id)
        h.library.endSyncApply(next)
        assertTrue(h.library.entries().isEmpty())
    }

    @Test fun bindingAnotherGraphGateDoesNotBypassAnExistingOwnersGate() {
        val h = ServiceHarness()
        val first = SyncRecoveryGate()
        val second = SyncRecoveryGate()
        h.values.sync.bindSyncWriteGate(first)
        h.values.sync.bindSyncWriteGate(first)
        h.values.sync.bindSyncWriteGate(second)
        first.blockForRecovery()
        assertFailsWith<LibraryError.RecoveryRequired> { h.values.record(v.personalID, mapOf("field" to "value")) }
        second.finishEmptyRecovery()
        assertFailsWith<LibraryError.RecoveryRequired> { h.values.removeAll() }
        first.finishEmptyRecovery()
        h.values.record(v.personalID, mapOf("field" to "value"))
        assertEquals(mapOf("field" to "value"), h.values.rememberedValues(v.personalID))
    }

    @Test fun inFlightKeyedWriteFinishesBeforePreparationWithoutHoldingLibraryLock() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        val writing = CountDownLatch(1)
        val release = CountDownLatch(1)
        h.state.onWrite = { path -> if (path == "values.json") {
            writing.countDown()
            check(release.await(5, TimeUnit.SECONDS))
        } }
        val workers = Executors.newFixedThreadPool(2)
        try {
            val write = workers.submit { h.values.record(from, mapOf("field" to "in-flight")) }
            assertTrue(writing.await(5, TimeUnit.SECONDS))
            // This completes while the keyed writer is blocked. A shared IO lock would deadlock here.
            h.library.beginSyncApply(UUID.randomUUID(), SyncState(v.binding()))
            val preparation = workers.submit<List<SyncKeyedMigration>> { h.values.sync.prepareSyncMigration(from, v.personalID) }
            release.countDown()
            write.get(5, TimeUnit.SECONDS)
            val change = preparation.get(5, TimeUnit.SECONDS).single().change as SyncKeyedMigration.Change.Values
            assertEquals(mapOf("field" to "in-flight"), change.fields)
            assertFailsWith<LibraryError.RecoveryRequired> { h.values.record(from, mapOf("field" to "late")) }
        } finally { release.countDown(); workers.shutdownNow() }
    }

    @Test fun historyPreflightPreservesNestedUnknownFilesAndRejectsOccupiedTargets() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        val prefix = "history/${from.storageKey}"
        val target = "history/${v.personalID.storageKey}"
        h.state.put("unknown", "$prefix/nested/opaque.bin")
        h.state.put("sidecar", "$prefix/revision.md.json")
        h.state.put("occupant", target)
        assertFailsWith<LibraryError.KeyedStateConflict> { h.history.sync.prepareSyncMigration(from, v.personalID) }
        assertEquals("occupant", h.state.text(target))
        h.state.delete(target)
        val moves = h.history.sync.prepareSyncMigration(from, v.personalID)
        assertEquals(2, moves.size)
        val flushes = SyncFlushes()
        moves.forEach { h.history.sync.applySyncMigration(it, flushes) }
        val writes = h.state.writes.size
        val flushCount = flushes.calls.size
        moves.forEach { h.history.sync.applySyncMigration(it, flushes) }
        assertEquals(writes, h.state.writes.size)
        assertTrue(flushes.calls.size > flushCount)
        assertEquals("unknown", h.state.text("$target/nested/opaque.bin"))
        assertEquals("sidecar", h.state.text("$target/revision.md.json"))
        assertNull(h.state.stamp("$prefix/nested/opaque.bin"))
        assertTrue(h.state.isPrivate("$target/nested/opaque.bin"))
    }

    @Test fun historyPreflightDetectsIncarnationChangesAndOversizedBytes() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        val path = "history/${from.storageKey}/revision.md"
        h.state.put("old", path)
        h.state.onRead = { if (it == path) { h.state.onRead = null; h.state.put("new", path) } }
        assertFailsWith<LibraryError.Conflict> { h.history.sync.prepareSyncMigration(from, v.personalID) }
        h.state.put(ByteArray(Limits.syncRecordMaxBytes + 1), path)
        assertFailsWith<SyncError.InvalidState> { h.history.sync.prepareSyncMigration(from, v.personalID) }
        assertNull(h.state.stamp("history/${v.personalID.storageKey}/revision.md"))
    }

    @Test fun historyAdoptionRebindsOnlyLiveHeadProvenanceAndLeavesRevisionsExact() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        val original = "old bytes".encodeToByteArray()
        val replacement = "exact server bytes".encodeToByteArray()
        fun record(hash: String) = StateJson.objectOf(mapOf(
            "version" to JsonPrimitive(1), "contentSHA256" to JsonPrimitive(hash), "origin" to JsonPrimitive("llm"),
            "timestamp" to JsonPrimitive("2026-10-14T01:02:03.000Z"), "providerHost" to JsonPrimitive("example.test"),
            "model" to JsonPrimitive("model"), "usage" to JsonNull,
        )).toString()
        val head = "history/${from.storageKey}/head.json"
        h.state.put(record(SyncHash.of(original).rawValue), head)
        h.state.put(record(SyncHash.of(original).rawValue), "history/${from.storageKey}/revision.md.json")
        val moves = h.history.sync.prepareSyncMigration(from, v.personalID, replacement, original)
        val headMove = (moves.first { (it.change as SyncKeyedMigration.Change.File).move.source == head }.change as SyncKeyedMigration.Change.File).move
        assertEquals(SyncHash.of(replacement).rawValue, StateJson.text(StateJson.read(headMove.destinationBytes).getValue("contentSHA256")))
        val revisionMove = (moves.first { (it.change as SyncKeyedMigration.Change.File).move.source != head }.change as SyncKeyedMigration.Change.File).move
        assertContentEquals(revisionMove.bytes, revisionMove.destinationBytes)
        h.state.put(record(SyncHash.of("stale".encodeToByteArray()).rawValue), head)
        val stale = (h.history.sync.prepareSyncMigration(from, v.personalID, replacement, original)
            .first { (it.change as SyncKeyedMigration.Change.File).move.source == head }.change as SyncKeyedMigration.Change.File).move
        assertContentEquals(stale.bytes, stale.destinationBytes)
    }

    @Test fun usagePreparationValidatesBothIdentityAndCapturedEventsBeforeAnyPublication() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        val path = "usage/${from.storageKey}"
        for (bad in listOf("not JSON", "{\"version\":2,\"events\":[]}", "{\"version\":1,\"events\":[\"nan\"]}")) {
            h.state.put(bad, path)
            assertFailsWith<LibraryError.OperationFailed> { h.usage.sync.prepareSyncMigration(from, v.personalID) }
        }
        h.usage.recordUse(v.personalID)
        h.state.put("{\"version\":1,\"events\":[]}", path)
        assertFailsWith<LibraryError.KeyedStateConflict> { h.usage.sync.prepareSyncMigration(from, v.personalID) }
        assertTrue(h.usage.sync.prepareSyncMigration(from, from).isEmpty())
    }

    @Test fun usageReplayReflushesWithoutDuplicateWritesAndPublishesCacheOnlyAfterDurability() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        h.usage.recordUse(from)
        val migration = h.usage.sync.prepareSyncMigration(from, v.personalID).single()
        val move = (migration.change as SyncKeyedMigration.Change.File).move
        val flushes = SyncFlushes().also { it.failAt = 1 }
        assertFailsWith<StoreError.IOFailure> { h.usage.sync.applySyncMigration(migration, flushes) }
        assertNull(h.usage.cachedEvents(v.personalID))
        assertContentEquals(move.bytes, h.state.read(move.source))
        assertContentEquals(move.destinationBytes, h.state.read(move.destination))
        flushes.failAt = null
        h.usage.sync.applySyncMigration(migration, flushes)
        val writes = h.state.writes.size
        val flushCount = flushes.calls.size
        h.usage.sync.applySyncMigration(migration, flushes)
        assertEquals(writes, h.state.writes.size)
        assertTrue(flushes.calls.size > flushCount)
        assertContentEquals(move.destinationBytes, h.state.read(move.destination))
        assertNull(h.state.stamp(move.source))
        assertNull(h.usage.cachedEvents(from))
        assertEquals(listOf(h.clock.date), h.usage.cachedEvents(v.personalID))
    }

    @Test fun valuesReplayPreservesUnrelatedIdentitiesAndOwnsCapturedMaps() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        h.values.record(from, mapOf("field" to ""))
        val migration = h.values.sync.prepareSyncMigration(from, v.personalID).single()
        h.values.record(v.groupID, mapOf("unrelated" to "keep"))
        val flushes = SyncFlushes().also { it.failAt = 1 }
        assertFailsWith<StoreError.IOFailure> { h.values.sync.applySyncMigration(migration, flushes) }
        flushes.failAt = null
        val writes = h.state.writes.size
        h.values.sync.applySyncMigration(migration, flushes)
        h.values.sync.applySyncMigration(migration, flushes)
        assertEquals(writes, h.state.writes.size)
        assertEquals(mapOf("field" to ""), h.values.rememberedValues(v.personalID))
        assertEquals(mapOf("unrelated" to "keep"), h.values.rememberedValues(v.groupID))
        assertTrue(h.values.rememberedValues(from).isEmpty())
        val fields = mutableMapOf("field" to "value")
        val saved = SyncKeyedMigration.Change.Values(from.storageKey, v.personalID.storageKey, fields)
        fields.clear()
        assertEquals(mapOf("field" to "value"), saved.fields)
        assertFailsWith<UnsupportedOperationException> { (saved.fields as MutableMap).clear() }
    }

    @Test fun changedKeyedSourcesOrDestinationsRefuseReplayWithoutDiscardingData() {
        val h = ServiceHarness()
        val from = PromptIdentity.at("a.md")
        h.values.record(from, mapOf("field" to "old"))
        val migration = h.values.sync.prepareSyncMigration(from, v.personalID).single()
        assertTrue(h.values.sync.isSyncMigrationUnstarted(migration))
        h.values.record(from, mapOf("field" to "changed"))
        assertFalse(h.values.sync.isSyncMigrationUnstarted(migration))
        assertFailsWith<LibraryError.KeyedStateConflict> { h.values.sync.applySyncMigration(migration, SyncFlushes()) }
        assertEquals(mapOf("field" to "changed"), h.values.rememberedValues(from))
        h.values.record(v.personalID, mapOf("field" to "occupant"))
        assertFailsWith<LibraryError.KeyedStateConflict> { h.values.sync.applySyncMigration(migration, SyncFlushes()) }
        assertEquals(mapOf("field" to "occupant"), h.values.rememberedValues(v.personalID))
    }

    @Test fun malformedOrForeignMigrationsFailBeforeStoreIO() {
        val h = ServiceHarness()
        val bytes = "{\"version\":1,\"events\":[]}".encodeToByteArray()
        val from = v.personalID.storageKey
        val to = v.groupID.storageKey
        val bad = listOf(
            SyncKeyedMigration(SyncKeyedStoreKind.USAGE, SyncKeyedMigration.Change.File(SyncKeyedFileMove("usage/$from", "usage/$to", "bad".encodeToByteArray()))),
            SyncKeyedMigration(SyncKeyedStoreKind.USAGE, SyncKeyedMigration.Change.File(SyncKeyedFileMove("usage/$from", "usage/$to", bytes, "bad".encodeToByteArray()))),
            SyncKeyedMigration(SyncKeyedStoreKind.HISTORY, SyncKeyedMigration.Change.File(SyncKeyedFileMove("history/$from/old", "history/$to/new", bytes))),
            SyncKeyedMigration(SyncKeyedStoreKind.HISTORY, SyncKeyedMigration.Change.File(SyncKeyedFileMove("history/$from/old", "history/$to/old", bytes, hash = v.hash))),
            SyncKeyedMigration(SyncKeyedStoreKind.HISTORY, SyncKeyedMigration.Change.File(SyncKeyedFileMove("../outside", "history/$to/old", bytes))),
            SyncKeyedMigration(SyncKeyedStoreKind.VALUES, SyncKeyedMigration.Change.Values(from, from, emptyMap())),
            SyncKeyedMigration(SyncKeyedStoreKind.USAGE, SyncKeyedMigration.Change.Values(from, to, emptyMap())),
        )
        val accesses = h.state.accesses
        for (migration in bad) for (store in h.library.syncKeyedStores()) {
            assertFailsWith<SyncError.InvalidState> { store.applySyncMigration(migration, SyncFlushes()) }
            assertFailsWith<SyncError.InvalidState> { store.isSyncMigrationUnstarted(migration) }
        }
        assertEquals(accesses, h.state.accesses)
    }

    @Test fun everyDurableFileMoveBoundaryReplaysTwiceWithoutLosingTheOnlyCopy() {
        fun rig(): Pair<MemoryStore, SyncKeyedFileMove> {
            val files = MemoryStore()
            val move = SyncKeyedFileMove("history/${v.personalID.storageKey}/nested/old", "history/${v.groupID.storageKey}/nested/old", byteArrayOf(-1, 0, 42))
            files.put(move.bytes, move.source)
            return files to move
        }
        val (initial, move) = rig()
        val successful = SyncFlushes()
        move.apply(initial, successful)
        for (cut in 1..successful.calls.size) {
            val (files, intent) = rig()
            val flushes = SyncFlushes().also { it.failAt = cut }
            assertFailsWith<StoreError.IOFailure> { intent.apply(files, flushes) }
            val retained = SyncDurability.readIfPresent(intent.source, files) ?: files.read(intent.destination)
            assertContentEquals(intent.bytes, retained)
            flushes.failAt = null
            intent.apply(files, flushes)
            intent.apply(files, flushes)
            assertContentEquals(intent.destinationBytes, files.read(intent.destination))
            assertNull(files.stamp(intent.source))
        }
        for (operation in listOf(MemoryStore.Operation.PRIVATE_WRITE, MemoryStore.Operation.DELETE)) {
            val (files, intent) = rig()
            files.fault = { current, _ -> if (current == operation) StoreError.IOFailure else null }
            assertFailsWith<StoreError.IOFailure> { intent.apply(files, SyncFlushes()) }
            assertContentEquals(intent.bytes, files.read(intent.source))
            files.fault = null
            intent.apply(files, SyncFlushes())
            intent.apply(files, SyncFlushes())
            assertContentEquals(intent.destinationBytes, files.read(intent.destination))
        }
    }

    @Test fun savedFileMoveBytesCannotBeChangedThroughInputOrReturnedArrays() {
        val original = byteArrayOf(-1, 0, 1)
        val replacement = byteArrayOf(2, 3, 4)
        val expected = original.copyOf()
        val expectedReplacement = replacement.copyOf()
        val move = SyncKeyedFileMove("history/${v.personalID.storageKey}/file", "history/${v.groupID.storageKey}/file", original, replacement)
        original.fill(0)
        replacement.fill(0)
        move.bytes.fill(0)
        move.destinationBytes.fill(0)
        move.validate()
        assertContentEquals(expected, move.bytes)
        assertContentEquals(expectedReplacement, move.destinationBytes)
        assertEquals(SyncHash.of(expected), move.hash)
        assertEquals(SyncHash.of(expectedReplacement), move.destinationHash)
    }

    @Test fun aChangedSourceDuringCopyOrAnOccupiedDestinationIsNeverDiscarded() {
        val files = MemoryStore()
        val move = SyncKeyedFileMove("history/${v.personalID.storageKey}/file", "history/${v.groupID.storageKey}/file", "old".encodeToByteArray())
        files.put(move.bytes, move.source)
        files.put("occupant", move.destination)
        val writes = files.writes.size
        assertFailsWith<LibraryError.KeyedStateConflict> { move.apply(files, SyncFlushes()) }
        assertEquals(writes, files.writes.size)
        assertEquals("occupant", files.text(move.destination))
        files.delete(move.destination)
        files.onWrite = { if (it == move.destination) files.put("changed source", move.source) }
        assertFailsWith<LibraryError.KeyedStateConflict> { move.apply(files, SyncFlushes()) }
        assertEquals("changed source", files.text(move.source))
        assertContentEquals(move.destinationBytes, files.read(move.destination))
        assertFalse(move.isUnstarted(files))
    }
}
