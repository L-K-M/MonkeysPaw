package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

class StateStoresTest {
    private val identity = PromptIdentity.at("a.md")
    private val destination = PromptIdentity.at("b.md")

    @Test fun localPathsRejectUnicodeControlAndFormatCharactersWithoutNormalizingValidPaths() {
        for (character in listOf("\u0000", "\u0085", "\u00ad", "\u200b", "\u200d", "\ufeff", "\udb40\udc01")) {
            assertFailsWith<StoreError.InvalidPath> { StorePath.validate("a${character}b.md") }
        }
        StorePath.validate("é.md")
        StorePath.validate("e\u0301.md")
        StorePath.validate("folder/\u0301a.md")
        assertNotEquals(PromptIdentity.at("é.md"), PromptIdentity.at("e\u0301.md"))
    }

    @Test fun identityUsesTheRawUTF8PathAndRejectsUntrustedStorageKeys() {
        assertEquals("fecccc97532467adbf93017b357c8b17e0c75527df76a143de5cfecc2613f615", identity.storageKey)
        assertEquals("f46adaba550604fac4e08f07a1d3017ff3983291f4a9e00a7cc7b2f2d3280a36", PromptIdentity.at("e\u0301.md").storageKey)
        for (hash in listOf("../private/path", "0".repeat(63), "A".repeat(64), "g".repeat(64))) {
            val h = ServiceHarness()
            val bad = PromptIdentity.Local(hash)
            assertFailsWith<LibraryError.InvalidIdentity> { h.values.rememberedValues(bad) }
            assertFailsWith<LibraryError.InvalidIdentity> { h.values.record(bad, mapOf("field" to "value")) }
            assertFailsWith<LibraryError.InvalidIdentity> { h.values.remove(bad) }
            assertFailsWith<LibraryError.InvalidIdentity> { h.usage.recordUse(bad) }
            assertFailsWith<LibraryError.InvalidIdentity> { h.history.revisions(bad) }
            assertEquals(0, h.state.accesses)
            assertEquals("<prompt identity>", bad.toString())
        }
        assertEquals("<file stamp>", FileStamp("private inode").toString())
    }

    @Test fun privateValuesRoundTripMergeAndRetainArbitraryEmptyFields() {
        val h = ServiceHarness()
        h.values.record(identity, mapOf("z" to "last", "a" to "first"))
        assertEquals("{\"values\":{\"${identity.storageKey}\":{\"a\":\"first\",\"z\":\"last\"}},\"version\":1}", h.state.text("values.json"))
        h.values.record(destination, mapOf("other" to "entry"))
        h.values.record(identity, mapOf("a" to "changed", "" to "", "a\"b\n☃" to "\"quoted\"\n\\\u0000{{raw}}", "👋" to "你好"))
        val reopened = ServiceHarness(state = h.state)
        assertEquals(mapOf("z" to "last", "a" to "changed", "" to "", "a\"b\n☃" to "\"quoted\"\n\\\u0000{{raw}}", "👋" to "你好"), reopened.values.rememberedValues(identity))
        assertEquals(mapOf("other" to "entry"), reopened.values.rememberedValues(destination))
        assertTrue(h.state.isPrivate("values.json"))
    }

    @Test fun emptyValuesAndAbsentRemovalDoNotWriteOrResetState() {
        val h = ServiceHarness()
        h.values.record(identity, emptyMap())
        assertEquals(0, h.state.accesses)
        h.values.remove(identity)
        assertTrue(h.state.bytesSnapshot().isEmpty())
        h.state.put("private corrupt text", "values.json")
        val before = h.state.accesses
        h.values.record(identity, emptyMap())
        assertEquals(before, h.state.accesses)
        assertEquals("private corrupt text", h.state.text("values.json"))
        h.values.removeAll()
        h.values.record(destination, mapOf("field" to "kept"))
        val stamp = h.state.stamp("values.json")
        h.values.remove(identity)
        assertEquals(stamp, h.state.stamp("values.json"))
    }

    @Test fun forgetOneRemovesStaleFieldsPreservesOtherPromptsAndKeepsAnEmptyVersionedFile() {
        val h = ServiceHarness()
        h.values.record(identity, mapOf("current" to "forgotten", "stale" to "old", "empty" to ""))
        h.values.record(destination, mapOf("field" to "kept"))
        h.values.remove(identity)
        assertTrue(h.values.rememberedValues(identity).isEmpty())
        assertEquals(mapOf("field" to "kept"), h.values.rememberedValues(destination))
        h.values.remove(destination)
        assertEquals("{\"values\":{},\"version\":1}", h.state.text("values.json"))
        assertTrue(h.state.isPrivate("values.json"))
    }

    @Test fun valuesMigrationMovesTheWholeMapIsReversibleAndRefusesEvenEmptyDestinationMaps() {
        val h = ServiceHarness()
        assertEquals(KeyMigration.UNCHANGED, h.values.migrateKey(identity, destination))
        assertTrue(h.state.bytesSnapshot().isEmpty())
        h.values.record(identity, mapOf("one" to "1", "empty" to ""))
        val original = h.state.read("values.json")
        assertEquals(KeyMigration.UNCHANGED, h.values.migrateKey(identity, identity))
        assertContentEquals(original, h.state.read("values.json"))
        assertEquals(KeyMigration.MIGRATED, h.values.migrateKey(identity, destination))
        assertEquals(mapOf("one" to "1", "empty" to ""), h.values.rememberedValues(destination))
        assertEquals(KeyMigration.MIGRATED, h.values.migrateKey(destination, identity))
        assertContentEquals(original, h.state.read("values.json"))
        h.state.put("{\"values\":{\"${identity.storageKey}\":{\"one\":\"1\"},\"${destination.storageKey}\":{}},\"version\":1}", "values.json")
        val both = h.state.read("values.json")
        assertFailsWith<LibraryError.KeyedStateConflict> { h.values.migrateKey(identity, destination) }
        assertContentEquals(both, h.state.read("values.json"))
    }

    @Test fun corruptFutureWrongTypedAndOverCapValuesFailClosedUntilExplicitForgetAll() {
        val invalid = listOf("private corrupt text".encodeToByteArray(), "{\"values\":{},\"version\":2}".encodeToByteArray(),
            "{\"values\":{\"key\":{\"field\":7}},\"version\":1}".encodeToByteArray(),
            "{\"values\":{},\"version\":true}".encodeToByteArray(), "{\"values\":{},\"version\":\"1\"}".encodeToByteArray(),
            byteArrayOf(-1), ByteArray(Limits.valuesFileCapBytes + 1) { 32 })
        for (bytes in invalid) {
            val h = ServiceHarness()
            h.state.put(bytes, "values.json")
            val operations = listOf<() -> Any>({ h.values.rememberedValues(identity) },
                { h.values.record(identity, mapOf("field" to "new")) }, { h.values.remove(identity) },
                { h.values.migrateKey(identity, destination) })
            for (operation in operations) assertFailsWith<LibraryError.OperationFailed>(block = operation)
            assertContentEquals(bytes, h.state.read("values.json"))
            h.state.onRead = { fail("Forget all must not read rejected state") }
            h.values.removeAll()
            h.state.onRead = null
            assertEquals("{\"values\":{},\"version\":1}", h.state.text("values.json"))
            h.values.record(identity, mapOf("field" to "after recovery"))
            assertEquals(mapOf("field" to "after recovery"), h.values.rememberedValues(identity))
        }
    }

    @Test fun failedValueWritesForRecordMigrationAndForgetPreserveExactPreviousState() {
        val h = ServiceHarness()
        h.values.record(identity, mapOf("field" to "kept"))
        val before = h.state.read("values.json")
        val stamp = h.state.stamp("values.json")
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.PRIVATE_WRITE) StoreError.IOFailure else null }
        val operations = listOf<() -> Any>({ h.values.record(identity, mapOf("field" to "new")) },
            { h.values.migrateKey(identity, destination) }, { h.values.remove(identity) }, { h.values.removeAll() })
        for (operation in operations) assertFailsWith<StoreError.IOFailure>(block = operation)
        assertContentEquals(before, h.state.read("values.json"))
        assertEquals(stamp, h.state.stamp("values.json"))
        h.state.fault = null
        h.values.removeAll()
        assertTrue(h.values.rememberedValues(identity).isEmpty())
    }

    @Test fun valuesCapIncludesJSONOverheadAndFailureDoesNotTruncateOrPrune() {
        val h = ServiceHarness()
        h.values.record(identity, mapOf("field" to "old"))
        val overhead = h.state.read("values.json").size - 3
        val maximum = "x".repeat(Limits.valuesFileCapBytes - overhead)
        h.values.record(identity, mapOf("field" to maximum))
        val capped = h.state.read("values.json")
        assertEquals(Limits.valuesFileCapBytes, capped.size)
        assertFailsWith<LibraryError.OperationFailed> { h.values.record(identity, mapOf("field" to maximum + "x")) }
        assertContentEquals(capped, h.state.read("values.json"))
        assertEquals(maximum, h.values.rememberedValues(identity)["field"])
    }

    @Test fun forgetDoesNotResurrectRemovedMapsDuringFailedOrSuccessfulMoves() {
        val h = ServiceHarness()
        h.put("{{field}}")
        h.values.record(identity, mapOf("field" to "kept", "stale" to "also kept"))
        h.values.record(destination, mapOf("field" to "forgotten"))
        h.values.remove(destination)
        val before = h.state.read("values.json")
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.MOVE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.move("a.md", "b.md") }
        assertContentEquals(before, h.state.read("values.json"))
        assertTrue(h.values.rememberedValues(destination).isEmpty())
        h.values.remove(identity)
        val afterForget = h.state.read("values.json")
        assertFailsWith<StoreError.IOFailure> { h.library.move("a.md", "b.md") }
        h.prompts.fault = null
        h.library.move("a.md", "b.md")
        assertContentEquals(afterForget, h.state.read("values.json"))
        assertTrue(h.values.rememberedValues(destination).isEmpty())
    }

    @Test fun usageRoundTripsSortedVersionedJSONAndCachesOnlySuccessfulWrites() {
        val h = ServiceHarness()
        h.clock.date = Instant.ofEpochMilli(1250)
        assertTrue(h.usage.useEvents(identity).isEmpty())
        h.usage.recordUse(identity)
        assertEquals(listOf(h.clock.date, Instant.ofEpochMilli(2500)), h.usage.recordUse(identity, Instant.ofEpochMilli(2500)))
        assertEquals("{\"events\":[1.25,2.5],\"version\":1}", h.state.text("usage/${identity.storageKey}"))
        val reopened = ServiceHarness(state = h.state)
        assertEquals(listOf(h.clock.date, Instant.ofEpochMilli(2500)), reopened.usage.useEvents(identity))
        assertEquals(listOf(h.clock.date, Instant.ofEpochMilli(2500)), h.usage.cachedEvents(identity))
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.usage.recordUse(identity) }
        assertEquals(listOf(h.clock.date, Instant.ofEpochMilli(2500)), h.usage.cachedEvents(identity))
    }

    @Test fun usageKeepsLast1024InRecordingOrderIncludingDuplicatesAndEarlierEvents() {
        val h = ServiceHarness()
        val initial = (0 until Limits.usageEventCap).map { Instant.ofEpochSecond(it.toLong()) }
        h.state.put("{\"events\":[${(0 until Limits.usageEventCap).joinToString(",")}],\"version\":1}", "usage/${identity.storageKey}")
        h.usage.recordUse(identity, Instant.EPOCH)
        val newest = Instant.ofEpochSecond(Limits.usageEventCap.toLong())
        val retained = h.usage.recordUse(identity, newest)
        assertEquals(initial.drop(2) + Instant.EPOCH + newest, retained)
        assertEquals(1024, retained.size)
        assertEquals(retained, h.usage.useEvents(identity))
    }

    @Test fun corruptFutureWrongTypedNonfiniteAndOverCapUsageNeverResetsOrReplaces() {
        val bad = listOf("private invalid bytes", "{\"version\":2,\"events\":[1]}", "{\"version\":true,\"events\":[1]}",
            "{\"version\":1,\"events\":[\"NaN\"]}", "{\"version\":1,\"events\":[1e999]}",
            "{\"version\":1,\"events\":[false]}", "{\"version\":1,\"events\":[${(0..1024).joinToString(",")}]}" )
        for (source in bad) {
            val h = ServiceHarness()
            h.state.put(source, "usage/${identity.storageKey}")
            assertFailsWith<LibraryError.OperationFailed> { h.usage.useEvents(identity) }
            assertFailsWith<LibraryError.OperationFailed> { h.usage.recordUse(identity) }
            assertEquals(source, h.state.text("usage/${identity.storageKey}"))
        }
    }

    @Test fun usageMigrationMovesRawBytesIsReversibleAndRefusesMalformedDestination() {
        val h = ServiceHarness()
        assertEquals(KeyMigration.UNCHANGED, h.usage.migrateKey(identity, destination))
        val source = " { \"version\" : 1, \"events\" : [1.25] } \n"
        h.state.put(source, "usage/${identity.storageKey}")
        h.usage.useEvents(identity)
        assertEquals(KeyMigration.UNCHANGED, h.usage.migrateKey(identity, identity))
        assertEquals(KeyMigration.MIGRATED, h.usage.migrateKey(identity, destination))
        assertEquals(source, h.state.text("usage/${destination.storageKey}"))
        assertEquals(listOf(Instant.ofEpochMilli(1250)), h.usage.cachedEvents(destination))
        assertNull(h.usage.cachedEvents(identity))
        assertEquals(KeyMigration.MIGRATED, h.usage.migrateKey(destination, identity))
        assertEquals(source, h.state.text("usage/${identity.storageKey}"))
        h.state.put("malformed occupied state", "usage/${destination.storageKey}")
        val before = h.state.bytesSnapshot()
        assertFailsWith<LibraryError.KeyedStateConflict> { h.usage.migrateKey(identity, destination) }
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun usageAndHistoryRacedDestinationsAreKeyedConflictsAndNeverPromptCollisions() {
        val h = ServiceHarness()
        h.usage.recordUse(identity)
        h.state.onMove = { _, target -> h.state.put("Raced destination", target) }
        assertFailsWith<LibraryError.KeyedStateConflict> { h.usage.migrateKey(identity, destination) }
        assertEquals("Raced destination", h.state.text("usage/${destination.storageKey}"))
        h.state.onMove = null
        val revision = h.history.snapshot("Older".encodeToByteArray(), identity, h.clock.date)
        h.state.onMove = { _, target -> h.state.put("Raced history", target) }
        assertFailsWith<LibraryError.KeyedStateConflict> { h.history.migrateKey(identity, destination) }
        assertEquals("Older", h.history.read(revision).decodeToString())
    }

    @Test fun unknownPortErrorsAreSanitizedAndTypedErrorsSurvive() {
        val h = ServiceHarness()
        for (error in listOf(StoreError.IOFailure, StoreError.OutsideRoot, StoreError.NotRegularFile)) {
            h.state.fault = { _, _ -> error }
            assertSame(error, assertFails { h.values.rememberedValues(identity) })
            assertSame(error, assertFails { h.usage.useEvents(identity) })
        }
        h.state.fault = { _, _ -> IllegalStateException("private/path and field content") }
        val error = assertFailsWith<LibraryError.OperationFailed> { h.values.rememberedValues(identity) }
        assertNull(error.cause)
        assertFalse(error.toString().contains("private"))
    }

    @Test fun usageListenerCannotMutateCachedOrReturnedEvents() {
        val h = ServiceHarness()
        val first = Instant.ofEpochSecond(1)
        val second = Instant.ofEpochSecond(2)
        h.usage.recordUse(identity, first)
        h.usage.onRecord = { _, events -> (events as MutableList).clear() }
        assertEquals(listOf(first, second), h.usage.recordUse(identity, second))
        assertEquals(listOf(first, second), h.usage.cachedEvents(identity))
        assertEquals(listOf(first, second), h.usage.useEvents(identity))
    }

    @Test fun moveFakeChecksTheSourceFirstAndRefusesAnOccupiedSelfMove() {
        val store = MemoryStore()
        store.put("Destination", "b.md")
        val before = store.bytesSnapshot()
        assertFailsWith<StoreError.NotFound> { store.move("missing.md", "b.md") }
        assertEquals(before, store.bytesSnapshot())
        assertFailsWith<StoreError.AlreadyExists> { store.move("b.md", "b.md") }
        assertEquals(before, store.bytesSnapshot())
    }

    @Test fun interruptedMutationRestoresTheFlagAndReleasesTheLock() {
        val boundary = MutationBoundary()
        try {
            assertFailsWith<InterruptedException> {
                boundary.run {
                    Thread.currentThread().interrupt()
                    Thread.sleep(1)
                }
            }
            assertTrue(Thread.currentThread().isInterrupted)
        } finally { Thread.interrupted() }
        val pool = Executors.newSingleThreadExecutor()
        try { assertEquals(42, pool.submit<Int> { boundary.run { 42 } }.get(5, TimeUnit.SECONDS)) }
        finally { pool.shutdownNow() }
    }

    @Test fun concurrentReadMergeWritesRetainEveryFieldAndUsageEvent() {
        val h = ServiceHarness()
        val pool = Executors.newFixedThreadPool(6)
        try {
            val futures = (0 until 40).map { number -> pool.submit {
                h.values.record(identity, mapOf("field$number" to number.toString()))
                h.usage.recordUse(identity, Instant.ofEpochSecond(number.toLong()))
            } }
            futures.forEach { it.get(10, TimeUnit.SECONDS) }
            assertEquals(40, h.values.rememberedValues(identity).size)
            assertEquals((0 until 40).toSet(), h.usage.useEvents(identity).map { it.epochSecond.toInt() }.toSet())
        } finally { pool.shutdownNow() }
    }

    @Test fun oneBoundarySerializesStateAccessWithMigrationAndPromptPublication() {
        val h = ServiceHarness()
        val old = h.put("{{field}}")
        h.values.record(old.identity, mapOf("field" to "old"))
        val staged = CountDownLatch(1)
        val release = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondFinished = CountDownLatch(1)
        h.state.onWrite = { path -> if (path == "values.json") {
            staged.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
        } }
        val pool = Executors.newFixedThreadPool(2)
        try {
            val save = pool.submit<LibrarySaveResult> { h.library.assignIdentity("a.md") }
            assertTrue(staged.await(5, TimeUnit.SECONDS))
            val read = pool.submit<Map<String, String>> {
                secondStarted.countDown()
                val result = h.values.rememberedValues(old.identity)
                secondFinished.countDown()
                result
            }
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
            assertFalse(secondFinished.await(100, TimeUnit.MILLISECONDS))
            release.countDown()
            val saved = save.get(5, TimeUnit.SECONDS).entry
            assertTrue(read.get(5, TimeUnit.SECONDS).isEmpty())
            assertEquals(mapOf("field" to "old"), h.values.rememberedValues(saved.identity))
        } finally {
            release.countDown()
            pool.shutdownNow()
        }
    }
}
