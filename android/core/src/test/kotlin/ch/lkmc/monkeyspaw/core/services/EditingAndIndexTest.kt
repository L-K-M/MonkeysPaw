package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import java.time.Instant
import kotlin.test.*

class EditingAndIndexTest {
    @Test fun createLoadEditRenameMoveAndRestoreKeepUnknownMetadataBodyAndIdentity() {
        val h = ServiceHarness()
        val body = "  {{x}}\r\n\r\n"
        val created = assertIs<EditResult.Saved>(h.editing.create("---\ntitle: Created\nunknown: {z: 2, a: 1}\n---\n$body", "folder/a.md")).commit.entry
        val loaded = assertIs<PromptLoadResult.Loaded>(h.editing.load(created.relativePath)).prompt
        assertEquals(created.stamp, loaded.entry.stamp)
        assertEquals(h.prompts.text(created.relativePath), loaded.source)
        val changed = assertIs<EditResult.Saved>(h.editing.save(loaded.source!! + "Edited\r\n", created.relativePath, created.stamp)).commit.entry
        assertEquals(created.identity, changed.identity)
        assertTrue(changed.document.source.contains("unknown:\n  z: 2\n  a: 1\n"))
        val renamed = assertIs<EditResult.Saved>(h.editing.rename(changed.relativePath, "new.md", changed.stamp)).commit.entry
        val moved = assertIs<EditResult.Saved>(h.editing.move(renamed.relativePath, "", renamed.stamp)).commit.entry
        assertEquals("new.md", moved.relativePath)
        assertEquals(changed.document.source, moved.document.source)
        assertEquals(created.identity, moved.identity)
        val history = h.editing.history(moved.identity, "new.md")
        assertEquals(1, history.size)
        assertEquals(body, history.single().document.body)
        val restored = assertIs<EditResult.Saved>(h.editing.restore(history.single().revision, moved.relativePath, moved.stamp)).commit.entry
        assertEquals(body, restored.document.body)
        assertEquals(created.identity, restored.identity)
        assertEquals(restored.stamp, h.index.snapshot().prompts.single().entry.stamp)
        assertEquals(2, h.history.revisions(created.identity).size)
        assertEquals(0, h.clipboard.reads)
    }

    @Test fun editorReadsOriginalBytesDefensivelyAndKeepsMalformedYAMLRepairable() {
        val h = ServiceHarness()
        h.put("---\ntitle: [broken\n---\nOriginal")
        val loaded = assertIs<PromptLoadResult.Loaded>(h.editing.load("a.md")).prompt
        assertNull(loaded.readOnlyReason)
        assertNotNull(loaded.source)
        val copy = loaded.sourceBytes
        copy.fill(0)
        assertEquals("---\ntitle: [broken\n---\nOriginal", loaded.sourceBytes.decodeToString())
        val saved = assertIs<EditResult.Saved>(h.editing.save("Corrected", "a.md", loaded.entry.stamp)).commit.entry
        val revision = h.history.revisions(saved.identity).single()
        assertEquals("---\ntitle: [broken\n---\nOriginal", h.history.read(revision).decodeToString())
        assertIs<EditResult.ForensicRestoreBlocked>(h.editing.restore(revision, "a.md", saved.stamp))
        assertEquals(saved.stamp, h.library.load("a.md").stamp)
    }

    @Test fun sourceBytesAndFutureFormatsLoadReadOnlyAndCannotBeOverwrittenThroughEditor() {
        for ((bytes, reason) in listOf(
            byteArrayOf(-1, -2) to SourceReadOnlyReason.INVALID_UTF8,
            ByteArray(ch.lkmc.monkeyspaw.core.domain.Limits.maxPromptBytes + 1) { 120 } to SourceReadOnlyReason.SOURCE_TOO_LARGE,
            "---\nformat: 2\n---\nFuture".encodeToByteArray() to SourceReadOnlyReason.FUTURE_FORMAT)) {
            val h = ServiceHarness()
            h.prompts.put(bytes, "a.md")
            val loaded = assertIs<PromptLoadResult.Loaded>(h.editing.load("a.md")).prompt
            assertEquals(reason, loaded.readOnlyReason)
            assertContentEquals(bytes, loaded.sourceBytes)
            if (reason != SourceReadOnlyReason.FUTURE_FORMAT) assertNull(loaded.source)
            val outcomes = listOf(h.editing.save("Older format", "a.md", loaded.entry.stamp),
                h.editing.rename("a.md", "b.md", loaded.entry.stamp), h.editing.delete("a.md", loaded.entry.stamp))
            assertTrue(outcomes.all { it == EditResult.ReadOnly(reason) })
            assertContentEquals(bytes, h.prompts.read("a.md"))
            assertTrue(h.state.bytesSnapshot().isEmpty())
        }
    }

    @Test fun invalidDraftsRemainLocalAndReturnIssuesBeforeAnyIO() {
        val h = ServiceHarness()
        val invalid = h.editing.create("{{broken", "a.md")
        assertIs<EditResult.Invalid>(invalid)
        assertEquals(0, h.prompts.accesses)
        assertEquals(0, h.state.accesses)
        assertIs<EditResult.ReadOnly>(h.editing.create("---\nformat: 2\n---\nBody", "a.md"))
        assertTrue(h.prompts.bytesSnapshot().isEmpty())
    }

    @Test fun deletionAndRecreationProduceDifferentStampedOutcomes() {
        val h = ServiceHarness()
        val opened = h.put("Original")
        h.prompts.delete("a.md")
        assertEquals(EditResult.Missing, h.editing.save("Mine", "a.md", opened.stamp))
        assertEquals(EditResult.Missing, h.editing.delete("a.md", opened.stamp))
        h.prompts.put("Original", "a.md")
        val currentStamp = h.prompts.stamp("a.md")!!
        assertEquals(EditResult.Conflict(currentStamp), h.editing.save("Mine", "a.md", opened.stamp))
        assertEquals(EditResult.Conflict(currentStamp), h.editing.rename("a.md", "b.md", opened.stamp))
        assertEquals(EditResult.Conflict(currentStamp), h.editing.delete("a.md", opened.stamp))
        assertTrue(h.state.bytesSnapshot().isEmpty())
        assertTrue(h.entropy.requests.isEmpty())
    }

    @Test fun explicitUnstampedSaveCanReplaceOrRecreate() {
        val h = ServiceHarness()
        h.put("Original")
        h.prompts.delete("a.md")
        val recreated = assertIs<EditResult.Saved>(h.editing.save("Mine", "a.md", null)).commit.entry
        h.prompts.put("External", "a.md")
        val saved = assertIs<EditResult.Saved>(h.editing.save("Overwrite", "a.md", null)).commit.entry
        assertEquals("Overwrite", saved.document.body)
        assertNotEquals(recreated.stamp, saved.stamp)
    }

    @Test fun editorDeletionDuringStagingReportsMissingAndReversesState() {
        val h = ServiceHarness()
        val opened = h.put("Original")
        h.values.record(opened.identity, mapOf("field" to "kept"))
        val before = h.state.bytesSnapshot()
        h.state.onCreate = { h.prompts.delete("a.md") }
        assertEquals(EditResult.Missing, h.editing.save("Mine", "a.md", opened.stamp))
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun occupiedDestinationsAndStateMigrationConflictsStayDistinct() {
        val h = ServiceHarness()
        val opened = h.put("Original")
        h.put("Destination", "b.md")
        assertEquals(EditResult.DestinationOccupied, h.editing.create("Mine", "b.md"))
        assertEquals(EditResult.DestinationOccupied, h.editing.rename("a.md", "b.md", opened.stamp))
        h.prompts.delete("b.md")
        h.values.record(opened.identity, mapOf("field" to "source"))
        h.values.record(PromptIdentity.at("b.md"), mapOf("field" to "destination"))
        assertEquals(EditResult.Failed(LibraryError.KeyedStateConflict), h.editing.rename("a.md", "b.md", opened.stamp))
        assertEquals("Original", h.prompts.text("a.md"))
    }

    @Test fun localRenameKeepsByteExactBasenameAndMigratesStateWithoutAssigningID() {
        val h = ServiceHarness()
        val opened = h.put("Original", "folder/\u0301a.md")
        h.values.record(opened.identity, mapOf("field" to "kept"))
        val moved = assertIs<EditResult.Saved>(h.editing.move(opened.relativePath, "destination", opened.stamp)).commit.entry
        assertEquals("destination/\u0301a.md", moved.relativePath)
        assertNull(moved.document.frontMatter.id)
        assertEquals(mapOf("field" to "kept"), h.values.rememberedValues(moved.identity))
        assertTrue(h.entropy.requests.isEmpty())
        val version = h.index.snapshot().version
        assertIs<EditResult.Saved>(h.editing.rename(moved.relativePath, "\u0301a.md", moved.stamp))
        assertEquals(version, h.index.snapshot().version)
    }

    @Test fun failuresPreserveDraftAndDiskAndHistoryMaintenanceCarriesTheCommittedStamp() {
        val h = ServiceHarness()
        val opened = h.put("Original")
        h.index.rebuild()
        val before = h.index.snapshot().version
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
        assertEquals(EditResult.Failed(StoreError.IOFailure), h.editing.save("Draft remains caller owned", "a.md", opened.stamp))
        assertEquals(opened.stamp, h.library.load("a.md").stamp)
        assertEquals(before, h.index.snapshot().version)
        h.prompts.fault = null
        var saved = assertIs<EditResult.Saved>(h.editing.save("First", "a.md", opened.stamp)).commit.entry
        repeat(49) { saved = h.library.save(h.draft(it.toString()), "a.md").entry }
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.DELETE) StoreError.IOFailure else null }
        val outcome = assertIs<EditResult.Saved>(h.editing.save("Committed", "a.md", saved.stamp)).commit
        assertTrue(outcome.historyMaintenanceFailed)
        assertEquals(outcome.entry.stamp, h.library.load("a.md").stamp)
        assertEquals("Committed", h.index.snapshot().prompts.single().entry.document.body)
    }

    @Test fun missingStateFileDuringMigrationIsNotMisreportedAsDeletedPrompt() {
        val h = ServiceHarness()
        val opened = h.put("Original")
        h.history.snapshot("Older".encodeToByteArray(), opened.identity, Instant.EPOCH)
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.MOVE) StoreError.NotFound else null }
        assertEquals(EditResult.Failed(StoreError.NotFound), h.editing.rename("a.md", "b.md", opened.stamp))
        assertEquals(opened.stamp, h.library.load("a.md").stamp)
    }

    @Test fun committedMoveRebindsToDestinationEvenIfItIsReplacedOrUnreadable() {
        for (missing in listOf(true, false)) {
            val h = ServiceHarness()
            val opened = h.put("Original")
            h.index.rebuild()
            h.prompts.onRead = { path -> if (path == "b.md") {
                h.prompts.onRead = null
                if (missing) h.prompts.delete(path) else h.prompts.put("External destination", path)
            } }
            val result = assertIs<EditResult.Relocated>(h.editing.rename("a.md", "b.md", opened.stamp))
            assertEquals("b.md", result.baseline.relativePath)
            assertNull(h.prompts.stamp("a.md"))
            if (missing) {
                assertEquals(PromptLoadResult.Missing, result.current)
                assertTrue(h.index.snapshot().prompts.isEmpty())
            } else {
                assertEquals("External destination", assertIs<PromptLoadResult.Loaded>(result.current).prompt.source)
                assertEquals("External destination", h.index.snapshot().prompts.single().entry.document.body)
            }
        }
    }

    @Test fun completeIndexRetainsInvalidEntriesAndByteDistinctTwinsAndSearchesFromMemory() {
        val h = ServiceHarness()
        h.put("---\ntitle: Twin\ntags: [code]\n---\nBody", "é.md")
        h.put("---\ntitle: Twin\n---\nBody", "e\u0301.md")
        h.put("---\ntitle: [bad\n---\nBody", "bad.md")
        h.put("---\nformat: 2\n---\nFuture", "future.md")
        val snapshot = h.index.rebuild()
        assertEquals(listOf("bad.md", "e\u0301.md", "future.md", "é.md"), snapshot.prompts.map { it.entry.relativePath })
        val accesses = h.prompts.accesses + h.state.accesses
        assertEquals(listOf("e\u0301.md", "é.md"), h.index.search("Twin").map { it.entry.relativePath })
        assertEquals(listOf("é.md"), h.index.search("#code").map { it.entry.relativePath })
        assertEquals(accesses, h.prompts.accesses + h.state.accesses)
        assertEquals(2, snapshot.prompts.count { !it.entry.document.canRender })
    }

    @Test fun failedRebuildKeepsAllEntriesUsageAndVersionFromLastCompletePublication() {
        val h = ServiceHarness()
        val first = h.put("One", "a.md")
        h.put("Two", "b.md")
        h.index.rebuild()
        h.index.recordUse(first.identity)
        val old = h.index.snapshot()
        h.put("External content", "a.md")
        h.state.put("{\"events\":[999],\"version\":1}", "usage/${first.identity.storageKey}")
        h.state.put("future usage", "usage/${PromptIdentity.at("b.md").storageKey}")
        assertFailsWith<LibraryError.OperationFailed> { h.index.rebuild() }
        val retained = h.index.snapshot()
        assertEquals(old.version, retained.version)
        assertEquals(listOf("One", "Two"), retained.prompts.map { it.entry.document.body })
        assertEquals(listOf(h.clock.date), retained.prompts.first().useEvents)
        assertEquals(listOf("a.md"), h.index.search("One").map { it.entry.relativePath })
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.READ) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.index.rebuild() }
        assertEquals(old.version, h.index.snapshot().version)
    }

    @Test fun indexPublishesAfterPromptCommitAndUsageWriteFailureKeepsRankingUnchanged() {
        val h = ServiceHarness()
        val first = h.put("Alpha", "a.md")
        h.put("Beta", "b.md")
        h.index.rebuild()
        val oldVersion = h.index.snapshot().version
        h.prompts.onWrite = {
            assertEquals(oldVersion, h.index.snapshot().version)
            assertEquals("Alpha", h.index.snapshot().prompts.first().entry.document.body)
        }
        val saved = h.library.save(h.draft("Updated"), "a.md", first.stamp).entry
        assertEquals(saved.stamp, h.index.snapshot().prompts.first().entry.stamp)
        h.index.recordUse(PromptIdentity.at("b.md"))
        val ranking = h.index.search("").map { it.entry.relativePath to it.score }
        val version = h.index.snapshot().version
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.index.recordUse(saved.identity) }
        assertEquals(version, h.index.snapshot().version)
        assertEquals(ranking, h.index.search("").map { it.entry.relativePath to it.score })
    }

    @Test fun favoriteUsesItsHeldStampAndOnlyPublishesAfterItsMetadataSaveCommits() {
        val h = ServiceHarness()
        val opened = h.put("---\nunknown: kept\n---\nBody\r\n")
        h.index.rebuild()
        val saved = h.library.toggleFavorite(opened).entry
        assertTrue(saved.document.frontMatter.favorite)
        assertEquals("Body\r\n", saved.document.body)
        assertTrue(saved.document.source.contains("unknown: kept\n"))
        assertTrue(h.index.snapshot().prompts.single().entry.document.frontMatter.favorite)
        h.prompts.put("External", "a.md")
        assertFailsWith<LibraryError.Conflict> { h.library.toggleFavorite(saved) }
        assertEquals("External", h.prompts.text("a.md"))
    }

    @Test fun publishedSnapshotsCannotMutateTheCachedEventsOrMembership() {
        val h = ServiceHarness()
        val entry = h.put("Body")
        h.index.rebuild()
        h.index.recordUse(entry.identity)
        val snapshot = h.index.snapshot()
        assertFailsWith<UnsupportedOperationException> { (snapshot.prompts as MutableList).clear() }
        assertFailsWith<UnsupportedOperationException> { (snapshot.prompts.single().useEvents as MutableList).clear() }
        assertEquals(1, h.index.snapshot().prompts.size)
        assertEquals(listOf(h.clock.date), h.index.snapshot().prompts.single().useEvents)
    }
}
