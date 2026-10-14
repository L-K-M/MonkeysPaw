package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlin.test.*

class SyncPersistenceTest {
    private val path = "sync/state.json"
    private val v = SyncTestValues

    @Test fun atomicWriteAndDeleteFailuresRetainOldCacheAndAllowRetry() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncStateStore(files, flushes)
        val state = v.state()
        store.update(state.binding) { state }
        val bytes = files.read(path)
        val before = flushes.calls.size
        files.fault = { operation, _ -> if (operation in setOf(MemoryStore.Operation.PRIVATE_WRITE, MemoryStore.Operation.DELETE)) StoreError.IOFailure else null }
        assertEquals(SyncError.WriteFailed(StoreError.IOFailure), assertFailsWith<SyncError> {
            store.update(state.binding) { it.copy(databaseID = null) }
        })
        assertEquals(SyncError.WriteFailed(StoreError.IOFailure), assertFailsWith<SyncError> { store.clear() })
        assertEquals(state, store.snapshot.value)
        assertNull(store.snapshot.error)
        assertContentEquals(bytes, files.read(path))
        assertEquals(before, flushes.calls.size)
        files.fault = null
        store.update(state.binding) { it.copy(databaseID = null) }
        assertNull(SyncStateStore(files, flushes).load(state.binding)!!.databaseID)
    }

    @Test fun eachPublicationFlushFailurePreservesCacheAndLatchesUntilExplicitRecovery() {
        for (offset in 1..3) {
            val files = MemoryStore()
            val flushes = SyncFlushes()
            val store = SyncStateStore(files, flushes)
            val state = v.state()
            val next = state.copy(cursors = mapOf(v.userScope to "next"))
            store.update(state.binding) { state }
            flushes.failAt = flushes.calls.size + offset
            assertEquals(SyncError.DurabilityUncertain, assertFailsWith<SyncError> { store.update(state.binding) { next } })
            assertEquals(state, store.snapshot.value)
            assertEquals(SyncError.DurabilityUncertain, store.snapshot.error)
            assertEquals(SyncError.DurabilityUncertain, assertFailsWith<SyncError> { store.load(state.binding) })
            assertEquals(SyncError.DurabilityUncertain, assertFailsWith<SyncError> { store.update(state.binding) { it } })
            val before = flushes.calls.size
            flushes.failAt = null
            assertEquals(next, store.recover(state.binding))
            assertEquals(before + 3, flushes.calls.size)
            assertEquals(next, store.snapshot.value)
            assertNull(store.snapshot.error)
        }
    }

    @Test fun clearRetryFlushesAbsentFileAfterBothDeletionFlushFailuresAndUnacknowledgedFirstWrite() {
        for (acknowledged in listOf(false, true)) for (offset in 1..2) {
            val files = MemoryStore()
            val flushes = SyncFlushes()
            val store = SyncStateStore(files, flushes)
            val state = v.state()
            if (acknowledged) store.update(state.binding) { state }
            else {
                flushes.failAt = 1
                assertFailsWith<SyncError.DurabilityUncertain> { store.update(state.binding) { state } }
            }
            flushes.failAt = flushes.calls.size + offset
            assertFailsWith<SyncError.DurabilityUncertain> { store.clear() }
            assertNull(files.stamp(path))
            assertEquals(if (acknowledged) state else null, store.snapshot.value)
            flushes.failAt = flushes.calls.size + 1
            assertFailsWith<SyncError.DurabilityUncertain> { store.clear() }
            assertEquals(SyncError.DurabilityUncertain, store.snapshot.error)
            val before = flushes.calls.size
            flushes.failAt = null
            store.clear()
            assertEquals(before + 2, flushes.calls.size)
            assertEquals(listOf("directory:sync", "directory:<root>"), flushes.calls.takeLast(2))
            assertNull(store.snapshot.value)
            assertNull(store.snapshot.error)
            assertNull(store.load(state.binding))
            store.clear()
            assertEquals(before + 2, flushes.calls.size)
        }
    }

    @Test fun freshClearIsIdempotentWithoutDirectoriesOrFlush() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncStateStore(files, flushes)
        repeat(2) { store.clear() }
        assertTrue(files.listFiles().isEmpty())
        assertTrue(flushes.calls.isEmpty())
    }

    @Test fun recoveryReadMissingCorruptValidationAndFlushErrorsRetainDurabilityLatch() {
        for (acknowledged in listOf(false, true)) {
            val files = MemoryStore()
            val flushes = SyncFlushes()
            val store = SyncStateStore(files, flushes)
            val state = v.state()
            if (acknowledged) store.update(state.binding) { state }
            flushes.failAt = flushes.calls.size + 1
            assertFailsWith<SyncError.DurabilityUncertain> { store.update(state.binding) { state } }
            val published = files.read(path)
            val before = flushes.calls.size
            files.onRead = { throw IllegalStateException("driver-secret-sentinel") }
            assertEquals(SyncError.ReadFailed(StoreError.IOFailure), assertFailsWith<SyncError> { store.recover(state.binding) })
            files.onRead = null
            files.delete(path)
            repeat(2) {
                assertEquals(SyncError.ReadFailed(StoreError.NotFound), assertFailsWith<SyncError> { store.recover(state.binding) })
                assertEquals(SyncError.DurabilityUncertain, store.snapshot.error)
            }
            files.put("{bad", path)
            assertEquals(SyncError.CorruptFile, assertFailsWith<SyncError> { store.recover(state.binding) })
            assertEquals(SyncError.DurabilityUncertain, store.snapshot.error)
            files.put(published, path)
            assertFailsWith<SyncError.BindingMismatch> { store.recover(v.binding("/other")) }
            assertFailsWith<SyncError.InvalidState> { store.recover(state.binding) { throw SyncError.InvalidState } }
            assertEquals(before, flushes.calls.size)
            assertEquals(if (acknowledged) state else null, store.snapshot.value)
            flushes.failAt = before + 2
            assertFailsWith<SyncError.DurabilityUncertain> { store.recover(state.binding) }
            flushes.failAt = null
            assertEquals(state, store.recover(state.binding))
            assertNull(store.snapshot.error)
        }
    }

    @Test fun explicitRecoverReflushesAnUncertainDeletion() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncStateStore(files, flushes)
        val state = v.state()
        store.update(state.binding) { state }
        flushes.failAt = flushes.calls.size + 1
        assertFailsWith<SyncError.DurabilityUncertain> { store.clear() }
        val before = flushes.calls.size
        flushes.failAt = null
        assertNull(store.recover(state.binding))
        assertEquals(before + 2, flushes.calls.size)
        assertNull(store.snapshot.error)
    }

    @Test fun surroundingTransactionBlockRetainsPriorSnapshotAndRequiresPublication() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncStateStore(files, flushes)
        val state = v.state()
        store.update(state.binding) { state }
        store.blockForRecovery(null)
        assertNull(store.snapshot.value)
        assertFailsWith<SyncError.DurabilityUncertain> { store.load(state.binding) }
        val before = flushes.calls.size
        assertEquals(state, store.recover(state.binding))
        assertEquals(before + 3, flushes.calls.size)
    }

    @Test fun externalRemovalCorruptionAndUnreadabilityFailClosedAndResetPreservesCanary() {
        for (failure in 0..2) {
            val files = MemoryStore()
            val store = SyncStateStore(files, SyncFlushes())
            val state = v.state()
            store.update(state.binding) { state }
            files.put("keep", "canary.md")
            val expected = when (failure) {
                0 -> { files.delete(path); SyncError.ReadFailed(StoreError.NotFound) }
                1 -> { files.put("{\"version\":99}", path); SyncError.FutureVersion(99) }
                else -> { files.onRead = { if (it == path) throw StoreError.IOFailure }; SyncError.ReadFailed(StoreError.IOFailure) }
            }
            assertEquals(expected, assertFailsWith<SyncError> { store.update(state.binding) { it } })
            assertEquals(expected, store.snapshot.error)
            assertNull(store.snapshot.value)
            files.onRead = null
            assertEquals(expected, assertFailsWith<SyncError> { store.load(state.binding) })
            store.reset(state.binding)
            assertEquals(SyncState(state.binding), store.load(state.binding))
            assertEquals("keep", files.text("canary.md"))
        }
    }
}
