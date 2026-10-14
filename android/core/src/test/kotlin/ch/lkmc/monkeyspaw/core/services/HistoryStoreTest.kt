package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.StoreError
import java.time.Instant
import kotlin.test.*

class HistoryStoreTest {
    private val identity = PromptIdentity.at("a.md")

    @Test fun invalidRevisionNamesCannotAccessTheStoreOrEscapeTheIdentityDirectory() {
        val h = ServiceHarness()
        val filenames = listOf("", "/", "..", "/19700101T000001.234Z-000000.md", "../19700101T000001.234Z-000000.md",
            "nested/19700101T000001.234Z-000000.md", "19700101T000001.234Z-00000.md", "19700101T000001.234Z-0000000.md",
            "19701301T000001.234Z-000000.md", "19700132T000001.234Z-000000.md", "19700101T000001.234Z-00000x.md",
            "19700101T000001.234Z-000000.txt", "not-a-revision.md", "19700101T240000.000Z-000000.md")
        for (filename in filenames) {
            val revision = HistoryRevision(identity, filename, h.clock.date)
            assertFailsWith<LibraryError.RevisionNotFound> { h.history.read(revision) }
            assertFailsWith<LibraryError.RevisionNotFound> { h.history.remove(revision) }
        }
        assertEquals(0, h.state.accesses)
    }

    @Test fun readUsesTheFilenameTimestampAndNeverListsFiles() {
        val h = ServiceHarness()
        val bytes = "Revision\r\n".encodeToByteArray()
        val revision = h.history.snapshot(bytes, identity, h.clock.date)
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.LIST) StoreError.IOFailure else null }
        assertContentEquals(bytes, h.history.read(revision.copy(timestamp = Instant.EPOCH)))
        h.history.remove(revision)
        assertFailsWith<LibraryError.RevisionNotFound> { h.history.read(revision) }
        assertFailsWith<LibraryError.RevisionNotFound> { h.history.remove(revision) }
    }

    @Test fun retentionIgnoresUnexpectedFilesAndDeletionKeepsSidecarsIfRevisionSurvives() {
        for (stepMillis in listOf(0L, 1L)) retentionKeepsTheNewestRevisions(stepMillis)
    }

    private fun retentionKeepsTheNewestRevisions(stepMillis: Long) {
        val h = ServiceHarness()
        val directory = "history/${identity.storageKey}"
        h.state.put("Settings", "settings.json")
        h.state.put("Unexpected", "$directory/not-a-revision.md")
        h.state.put("Bad date", "$directory/19701301T000001.234Z-000000.md")
        val created = (0 until 51).map {
            val revision = h.history.snapshot("Revision $it".encodeToByteArray(), identity, h.clock.date)
            h.clock.date = h.clock.date.plusMillis(stepMillis)
            revision
        }
        h.history.prune(identity)
        assertEquals(50, h.history.revisions(identity).size)
        assertEquals(created.drop(1).asReversed(), h.history.revisions(identity))
        assertFailsWith<LibraryError.RevisionNotFound> { h.history.read(created.first()) }
        assertEquals("Revision 50", h.history.read(created.last()).decodeToString())
        assertEquals("Settings", h.state.text("settings.json"))
        assertEquals("Unexpected", h.state.text("$directory/not-a-revision.md"))
        val revision = h.history.revisions(identity).first()
        val path = h.statePath(revision)
        h.state.put("Unknown attribution", "$path.json")
        h.state.fault = { op, target -> if (op == MemoryStore.Operation.DELETE && target == path) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.history.remove(revision) }
        assertEquals("Unknown attribution", h.state.text("$path.json"))
        assertTrue(h.history.read(revision).isNotEmpty())
    }

    @Test fun collisionExhaustionAndTimestampBoundsFailBeforeWriting() {
        val h = ServiceHarness()
        val directory = "history/${identity.storageKey}"
        h.state.put("Last", "$directory/19700101T000001.234Z-999999.md")
        assertFailsWith<LibraryError.HistoryCollisionLimitReached> { h.history.snapshot(byteArrayOf(), identity, h.clock.date) }
        val accesses = h.state.accesses
        for (at in listOf(Instant.ofEpochSecond(-1), Instant.ofEpochSecond(Limits.historyMaxUnixSeconds))) {
            assertFailsWith<LibraryError.InvalidTimestamp> { h.history.snapshot(byteArrayOf(), identity, at) }
        }
        assertEquals(accesses, h.state.accesses)
        assertEquals("Last", h.state.text("$directory/19700101T000001.234Z-999999.md"))
    }

    @Test fun racedSnapshotNeverReplacesAnOccupiedRevision() {
        val h = ServiceHarness()
        h.state.onCreate = { h.state.put("Raced bytes", it) }
        assertFailsWith<LibraryError.HistoryCollisionLimitReached> { h.history.snapshot("Mine".encodeToByteArray(), identity, h.clock.date) }
        assertEquals("Raced bytes", h.state.text("history/${identity.storageKey}/19700101T000001.234Z-000000.md"))
    }

    @Test fun historyMigrationIncludesUnknownFilesAndSupportsExactReversal() {
        val h = ServiceHarness()
        val destination = PromptIdentity.at("b.md")
        assertEquals(KeyMigration.UNCHANGED, h.history.migrateKey(identity, destination))
        val revision = h.history.snapshot("Revision".encodeToByteArray(), identity, h.clock.date)
        h.state.put("opaque sidecar", "history/${identity.storageKey}/nested/unknown.json")
        val original = h.state.bytesSnapshot()
        assertEquals(KeyMigration.UNCHANGED, h.history.migrateKey(identity, identity))
        assertEquals(KeyMigration.MIGRATED, h.history.migrateKey(identity, destination))
        assertTrue(h.history.revisions(identity).isEmpty())
        assertEquals("Revision", h.history.read(revision.copy(identity = destination)).decodeToString())
        assertEquals("opaque sidecar", h.state.text("history/${destination.storageKey}/nested/unknown.json"))
        assertEquals(KeyMigration.MIGRATED, h.history.migrateKey(destination, identity))
        assertEquals(original, h.state.bytesSnapshot())
    }

    @Test fun failedHistoryRollbackReportsRecoveryRequiredWithoutPretendingStateWasUnchanged() {
        val h = ServiceHarness()
        val destination = PromptIdentity.at("b.md")
        repeat(2) { h.history.snapshot("Revision $it".encodeToByteArray(), identity, h.clock.date) }
        var moves = 0
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.MOVE && ++moves >= 2) StoreError.IOFailure else null }
        assertFailsWith<LibraryError.RecoveryRequired> { h.history.migrateKey(identity, destination) }
        h.state.fault = null
        assertEquals(1, h.history.revisions(identity).size)
        assertEquals(1, h.history.revisions(destination).size)
    }
}
