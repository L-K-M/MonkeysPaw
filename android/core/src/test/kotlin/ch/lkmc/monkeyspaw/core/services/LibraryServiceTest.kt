package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.ULIDGenerationError
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import kotlin.test.*

class LibraryServiceTest {
    @Test fun enumerationIsByteOrderedAndUsesOnlyLocalIgnoreRules() {
        val h = ServiceHarness()
        val included = listOf("a.md", "z.md", ".visible.md", "readme.md", "notes/README.md",
            "nested/folder/a.md", "Groups/team/a.md", "Conflicts/a.md", "é.md", "e\u0301.md")
        val ignored = listOf("README.md", ".git/a.md", "folder/.hidden/a.md", "_drafts/a.md",
            "folder/_private/a.md", "_file.md", "nested/_file.md", "a.MD", "a.txt")
        (included + ignored).forEach { h.prompts.put("Body", it) }
        assertEquals(listOf(".visible.md", "Conflicts/a.md", "Groups/team/a.md", "a.md", "e\u0301.md",
            "nested/folder/a.md", "notes/README.md", "readme.md", "z.md", "é.md"), h.library.entries().map { it.relativePath })
        assertTrue(h.entropy.requests.isEmpty())
        assertTrue(h.state.bytesSnapshot().isEmpty())
        assertNotEquals(PromptIdentity.at("é.md"), PromptIdentity.at("e\u0301.md"))
        assertEquals("nested/folder", h.library.load("nested/folder/a.md").folder)
    }

    @Test fun invalidAndFutureFilesStayVisibleWithoutGeneratingIDs() {
        val h = ServiceHarness()
        h.prompts.put("---\ntitle: [broken\n---\nBody", "bad.md")
        h.prompts.put(byteArrayOf(-1, -2), "bytes.md")
        h.prompts.put(ByteArray(Limits.maxPromptBytes + 1) { 120 }, "large.md")
        h.prompts.put("---\nformat: 999999999999999999999999\n---\nFuture", "future.md")
        val entries = h.library.entries()
        assertEquals(listOf("bad.md", "bytes.md", "future.md", "large.md"), entries.map { it.relativePath })
        assertEquals(listOf(PromptIssueCode.INVALID_YAML, PromptIssueCode.INVALID_UTF8,
            PromptIssueCode.UNSUPPORTED_FORMAT, PromptIssueCode.SOURCE_TOO_LARGE), entries.map { it.issues.first().code })
        assertTrue(entries.none { it.document.canRender })
        assertTrue(h.entropy.requests.isEmpty())
    }

    @Test fun firstSaveAssignsFreshIDAndPreservesCanonicalMetadataAndBodyBytes() {
        val h = ServiceHarness()
        val body = "  👋 {{x}}\r\n\r\nlast line\r\n\r\n"
        val document = h.draft("---\nextra_z: {second: 2, first: 1}\nfavorite: true\nextra_a: value\ntitle: Saved\ntags: [code]\n---\n" + body)
        val saved = h.library.create(document, "nested/New.md").entry
        val expected = ULID.generate(h.clock.date, h.entropy.value)
        assertEquals(PromptIdentity.Assigned(expected), saved.identity)
        assertEquals(listOf(10), h.entropy.requests)
        assertEquals(body, saved.document.body)
        val written = h.prompts.text("nested/New.md")
        assertTrue(written.startsWith("---\nid: ${expected.rawValue}\n"))
        val positions = listOf("id:", "title:", "tags:", "favorite:", "extra_z:", "extra_a:").map(written::indexOf)
        assertEquals(positions.sorted(), positions)
        assertTrue(written.contains("extra_z:\n  second: 2\n  first: 1\n"))
        assertTrue(h.history.revisions(saved.identity).isEmpty())
        h.entropy.value[0] = 42
        val other = h.library.create(document, "other.md").entry
        assertNotEquals(saved.identity, other.identity)
    }

    @Test fun plainFileGainsOnlyAnIDHeaderAndSnapshotsTheExactPriorBytes() {
        val h = ServiceHarness()
        val body = "  plain body\r\n\n"
        val old = h.put(body, "Plain.md")
        val saved = h.library.save(old.document, old.relativePath, old.stamp).entry
        val expected = ULID.generate(h.clock.date, h.entropy.value)
        assertEquals("---\nid: ${expected.rawValue}\n---\n$body", h.prompts.text("Plain.md"))
        assertEquals(listOf(10), h.entropy.requests)
        val revision = h.history.revisions(saved.identity).single()
        assertEquals("19700101T000001.234Z-000000.md", revision.filename)
        assertContentEquals(body.encodeToByteArray(), h.history.read(revision))
        assertTrue(h.history.revisions(old.identity).isEmpty())
    }

    @Test fun existingIDsSurviveOmissionCaseNormalizationResaveAndMove() {
        val h = ServiceHarness()
        val id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        val old = h.put("---\nid: ${id.lowercase()}\n---\nBody")
        assertEquals(old.stamp, h.library.assignIdentity("a.md", old.stamp).entry.stamp)
        assertTrue(h.history.revisions(old.identity).isEmpty())
        val saved = h.library.save(h.draft("Edited"), "a.md", old.stamp).entry
        assertEquals(old.identity, saved.identity)
        assertTrue(h.prompts.text("a.md").contains("id: $id\n"))
        val moved = assertIs<LibraryMoveResult.Moved>(h.library.move("a.md", "assigned.md", saved.stamp)).entry
        assertEquals(old.identity, moved.identity)
        assertEquals(1, h.history.revisions(moved.identity).size)
        assertTrue(h.entropy.requests.isEmpty())
        assertFailsWith<LibraryError.IdentityMismatch> {
            h.library.save(h.draft("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAW\n---\nOther"), "assigned.md")
        }
    }

    @Test fun createKeepsASuppliedIdentity() {
        val h = ServiceHarness()
        val id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        val created = h.library.create(h.draft("---\nid: $id\n---\nBody"), "a.md").entry
        assertEquals(id, created.document.frontMatter.id?.rawValue)
        assertTrue(h.entropy.requests.isEmpty())
    }

    @Test fun assignmentAndLocalMovesMigrateAllStateThenAssignedMovesKeepTheKey() {
        val h = ServiceHarness()
        val old = h.put("{{field}}")
        h.values.record(old.identity, mapOf("field" to "", "stale" to "kept"))
        h.usage.recordUse(old.identity, Instant.ofEpochMilli(1250))
        h.history.snapshot("Older\r\n".encodeToByteArray(), old.identity, Instant.EPOCH)
        h.index.rebuild()
        val moved = assertIs<LibraryMoveResult.Moved>(h.library.move("a.md", "folder/new.md", old.stamp)).entry
        assertEquals(PromptIdentity.at("folder/new.md"), moved.identity)
        assertNull(moved.document.frontMatter.id)
        assertEquals("new", moved.document.frontMatter.title)
        assertTrue(h.values.rememberedValues(old.identity).isEmpty())
        assertEquals(mapOf("field" to "", "stale" to "kept"), h.values.rememberedValues(moved.identity))
        assertEquals(listOf(Instant.ofEpochMilli(1250)), h.usage.useEvents(moved.identity))
        assertEquals(1, h.history.revisions(moved.identity).size)
        assertTrue(h.history.revisions(old.identity).isEmpty())
        val assigned = h.library.assignIdentity("folder/new.md", moved.stamp).entry
        assertEquals(2, h.history.revisions(assigned.identity).size)
        assertEquals(listOf(Instant.ofEpochMilli(1250)), h.index.snapshot().prompts.single().useEvents)
        val state = h.state.bytesSnapshot()
        val final = assertIs<LibraryMoveResult.Moved>(h.library.move("folder/new.md", "last.md", assigned.stamp)).entry
        assertEquals(assigned.identity, final.identity)
        assertEquals(state, h.state.bytesSnapshot())
    }

    @Test fun failedSaveReversesEveryMigrationAndRemovesItsStagedSnapshot() {
        val h = populatedLocalState()
        val before = h.state.bytesSnapshot()
        val old = h.library.load("a.md")
        h.index.rebuild()
        val cached = h.index.snapshot()
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.assignIdentity("a.md", old.stamp) }
        assertEquals(before, h.state.bytesSnapshot())
        assertEquals(old.stamp, h.library.load("a.md").stamp)
        assertEquals(cached.version, h.index.snapshot().version)
        assertEquals(old.identity, h.index.snapshot().prompts.single().entry.identity)
        assertEquals(listOf(h.clock.date), h.usage.useEvents(old.identity))
    }

    @Test fun failedMoveReversesAllStateAndKeepsSourceAndCache() {
        val h = populatedLocalState()
        h.index.rebuild()
        val before = h.state.bytesSnapshot()
        val version = h.index.snapshot().version
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.MOVE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.move("a.md", "b.md") }
        assertEquals(before, h.state.bytesSnapshot())
        assertEquals("{{field}}", h.prompts.text("a.md"))
        assertNull(h.prompts.stamp("b.md"))
        assertEquals(version, h.index.snapshot().version)
    }

    @Test fun conflictsInEachStateStorePreserveBothKeysAndReverseEarlierStores() {
        for (occupied in listOf("history", "usage", "values")) {
            val h = populatedLocalState()
            val destination = PromptIdentity.at("b.md")
            when (occupied) {
                "history" -> h.state.put("opaque", "history/${destination.storageKey}/unrecognized-file")
                "usage" -> h.state.put("malformed occupied usage", "usage/${destination.storageKey}")
                "values" -> h.values.record(destination, emptyMap<String, String>() + ("occupied" to "keep"))
            }
            val state = h.state.bytesSnapshot()
            assertFailsWith<LibraryError.KeyedStateConflict> { h.library.move("a.md", "b.md") }
            assertEquals(state, h.state.bytesSnapshot(), occupied)
            assertEquals("{{field}}", h.prompts.text("a.md"))
            assertNull(h.prompts.stamp("b.md"))
        }
    }

    @Test fun laterStateWriteOrSnapshotFailurePreventsPromptPublication() {
        for (failed in listOf(MemoryStore.Operation.PRIVATE_WRITE, MemoryStore.Operation.CREATE)) {
            val h = populatedLocalState()
            val before = h.state.bytesSnapshot()
            var failedOnce = false
            h.state.fault = { op, _ ->
                if (op == failed && !failedOnce) { failedOnce = true; StoreError.IOFailure } else null
            }
            assertFailsWith<StoreError.IOFailure> { h.library.assignIdentity("a.md") }
            assertEquals(before, h.state.bytesSnapshot())
            assertEquals("{{field}}", h.prompts.text("a.md"))
        }
    }

    @Test fun partialHistoryMigrationRollsBackAllCompletedFiles() {
        val h = populatedLocalState()
        val identity = PromptIdentity.at("a.md")
        h.history.snapshot("Second".encodeToByteArray(), identity, h.clock.date)
        h.state.put("unknown sidecar", "history/${identity.storageKey}/head.json")
        val before = h.state.bytesSnapshot()
        var moves = 0
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.MOVE && ++moves == 2) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.move("a.md", "b.md") }
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun failedRollbackOrSnapshotCleanupReportsRecoveryRequired() {
        for (cleanup in listOf(true, false)) {
            val h = populatedLocalState()
            h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
            h.state.fault = { op, path ->
                if (cleanup && op == MemoryStore.Operation.DELETE || !cleanup && op == MemoryStore.Operation.MOVE &&
                    path.startsWith("usage/") && path != "usage/${PromptIdentity.at("a.md").storageKey}") StoreError.IOFailure else null
            }
            assertFailsWith<LibraryError.RecoveryRequired> { h.library.assignIdentity("a.md") }
            assertEquals("{{field}}", h.prompts.text("a.md"))
        }
    }

    @Test fun createNeverReadsReplacesOrSnapshotsAnyOccupiedPrompt() {
        for (source in listOf("Body".encodeToByteArray(), "---\ntitle: [broken\n---\nBody".encodeToByteArray(),
            byteArrayOf(-1), "---\nformat: 999\n---\nFuture".encodeToByteArray())) {
            val h = ServiceHarness()
            h.prompts.put(source, "a.md")
            val stamp = h.prompts.stamp("a.md")
            h.prompts.onRead = { fail("Occupied prompt must not be read by create") }
            assertFailsWith<LibraryError.DestinationOccupied> { h.library.create(h.draft("Replacement"), "a.md") }
            assertEquals(stamp, h.prompts.stamp("a.md"))
            assertEquals(source.toList(), h.prompts.bytesSnapshot()["a.md"])
            assertTrue(h.state.bytesSnapshot().isEmpty())
        }
    }

    @Test fun racedCreateAndMoveDestinationsSurviveAndReverseAllState() {
        for (create in listOf(true, false)) {
            val h = populatedLocalState()
            val path = if (create) "a.md" else "b.md"
            if (create) h.prompts.delete("a.md")
            val before = h.state.bytesSnapshot()
            if (create) h.prompts.onCreate = { h.prompts.put("External\r\n", it) }
            else h.prompts.onMove = { _, destination -> h.prompts.put("External\r\n", destination) }
            assertFailsWith<LibraryError.DestinationOccupied> {
                if (create) h.library.create(h.draft("New"), path) else h.library.move("a.md", path)
            }
            assertEquals("External\r\n", h.prompts.text(path))
            assertEquals(before, h.state.bytesSnapshot())
        }
    }

    @Test fun staleAndRecreatedStampsRejectEveryMutationBeforeStateWork() {
        for (assigned in listOf(true, false)) {
            val h = ServiceHarness()
            val source = if (assigned) "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal" else "Original"
            val old = h.put(source)
            h.prompts.delete("a.md")
            h.prompts.put(source, "a.md")
            val stamp = h.prompts.stamp("a.md")
            assertNotEquals(old.stamp, stamp)
            assertFailsWith<LibraryError.Conflict> { h.library.assignIdentity("a.md", old.stamp) }
            assertFailsWith<LibraryError.Conflict> { h.library.save(h.draft("Mine"), "a.md", old.stamp) }
            assertFailsWith<LibraryError.Conflict> { h.library.move("a.md", "b.md", old.stamp) }
            assertFailsWith<LibraryError.Conflict> { h.library.delete("a.md", old.stamp) }
            assertEquals(stamp, h.prompts.stamp("a.md"))
            assertTrue(h.entropy.requests.isEmpty())
            assertTrue(h.state.bytesSnapshot().isEmpty())
        }
    }

    @Test fun editsAndDeletionDuringStagingTriggerRollback() {
        for (delete in listOf(true, false)) {
            val h = populatedLocalState()
            val old = h.library.load("a.md")
            val before = h.state.bytesSnapshot()
            h.state.onCreate = {
                if (delete) h.prompts.delete("a.md") else h.prompts.put("External", "a.md")
            }
            assertFailsWith<LibraryError.Conflict> { h.library.save(h.draft("Mine"), "a.md", old.stamp) }
            assertEquals(before, h.state.bytesSnapshot())
            if (delete) assertNull(h.prompts.stamp("a.md")) else assertEquals("External", h.prompts.text("a.md"))
        }
    }

    @Test fun futureDraftAndExistingFutureFileAreProtected() {
        val h = ServiceHarness()
        val future = "---\nformat: 99999999999999999999999\n---\nFuture"
        assertFailsWith<PromptWriteError.UnsupportedFormat> { h.library.create(h.draft(future), "a.md") }
        val old = h.put(future)
        assertFailsWith<PromptWriteError.UnsupportedFormat> { h.library.save(h.draft("Old format"), "a.md", old.stamp) }
        assertEquals(old.stamp, h.library.load("a.md").stamp)
        assertEquals(future, h.prompts.text("a.md"))
        assertTrue(h.entropy.requests.isEmpty())
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun correctedDraftCanSnapshotInvalidOriginalBytesForForensics() {
        val h = ServiceHarness()
        val invalid = byteArrayOf(-1, -2)
        h.prompts.put(invalid, "a.md")
        val entry = h.library.save(h.draft("Corrected"), "a.md").entry
        val revision = h.history.revisions(entry.identity).single()
        assertContentEquals(invalid, h.history.read(revision))
        assertFailsWith<PromptWriteError.InvalidPrompt> { h.library.restore(revision, "a.md", entry.stamp) }
        assertEquals(entry.stamp, h.library.load("a.md").stamp)
    }

    @Test fun historyCapsAtFiftyAndRestoreSnapshotsTheCurrentFile() {
        val h = ServiceHarness()
        val first = h.library.create(h.draft("0"), "a.md").entry
        for (number in 1..55) h.library.save(h.draft(number.toString()), "a.md")
        val revisions = h.history.revisions(first.identity)
        assertEquals(50, revisions.size)
        assertEquals("19700101T000001.234Z-000054.md", revisions.first().filename)
        assertEquals("19700101T000001.234Z-000005.md", revisions.last().filename)
        assertEquals("54", PromptCodec.parseFile(h.history.read(revisions.first()), "a.md").body)
        assertEquals("5", PromptCodec.parseFile(h.history.read(revisions.last()), "a.md").body)
        val restored = h.library.restore(revisions.last(), "a.md").entry
        assertEquals(first.identity, restored.identity)
        assertEquals("5", restored.document.body)
        val after = h.history.revisions(first.identity)
        assertEquals(50, after.size)
        assertEquals("55", PromptCodec.parseFile(h.history.read(after.first()), "a.md").body)
    }

    @Test fun retentionFailureReturnsCommittedEntryAndPublishesIt() {
        val h = ServiceHarness()
        val first = h.library.create(h.draft("0"), "a.md").entry
        repeat(50) { h.library.save(h.draft(it.toString()), "a.md") }
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.DELETE) StoreError.IOFailure else null }
        val result = h.library.save(h.draft("Saved"), "a.md")
        assertTrue(result.historyMaintenanceFailed)
        assertEquals("Saved", result.entry.document.body)
        assertEquals(result.entry.stamp, h.library.load("a.md").stamp)
        assertEquals(result.entry.stamp, h.index.snapshot().prompts.single().entry.stamp)
        assertEquals(51, h.history.revisions(first.identity).size)
    }

    @Test fun retentionCannotReplaceTheCapturedCommittedEntryWithAnExternalVersion() {
        val h = ServiceHarness()
        val first = h.library.create(h.draft("0"), "a.md").entry
        repeat(50) { h.library.save(h.draft(it.toString()), "a.md") }
        h.state.onDelete = {
            h.prompts.put("---\nid: ${first.document.frontMatter.id!!.rawValue}\n---\nExternal", "a.md")
            throw StoreError.IOFailure
        }
        val result = h.library.save(h.draft("Saved"), "a.md")
        assertTrue(result.historyMaintenanceFailed)
        assertEquals("Saved", result.entry.document.body)
        assertNotEquals(result.entry.stamp, h.library.load("a.md").stamp)
        assertEquals("Saved", h.index.snapshot().prompts.single().entry.document.body)
        h.index.rebuild()
        assertEquals("External", h.index.snapshot().prompts.single().entry.document.body)
    }

    @Test fun deletedAssignedPromptRestoresPreIDBytesUnderTheSameIdentity() {
        val h = ServiceHarness()
        h.put("  Original\r\n\n")
        val first = h.library.assignIdentity("a.md").entry
        val revisions = h.history.revisions(first.identity)
        h.library.delete("a.md", first.stamp)
        assertTrue(h.index.snapshot().prompts.isEmpty())
        val restored = h.library.restore(revisions.single(), "b.md").entry
        assertEquals(first.identity, restored.identity)
        assertEquals("  Original\r\n\n", restored.document.body)
        assertEquals(revisions, h.history.revisions(first.identity))
    }

    @Test fun restoreRefusesOtherIdentitiesAndAnAssignedIdentityStillLiveElsewhere() {
        val h = ServiceHarness()
        h.put("Original")
        val first = h.library.assignIdentity("a.md").entry
        val revision = h.history.revisions(first.identity).single()
        assertFailsWith<LibraryError.IdentityMismatch> { h.library.restore(revision, "b.md") }
        h.put("Unrelated", "b.md")
        assertFailsWith<LibraryError.IdentityMismatch> { h.library.restore(revision, "b.md") }
        assertEquals("Unrelated", h.prompts.text("b.md"))
        h.library.move("a.md", "é.md", first.stamp)
        assertFailsWith<LibraryError.IdentityMismatch> { h.library.restore(revision, "e\u0301.md") }
    }

    @Test fun localRestoreIsBoundToItsRawPathAndFirstSaveMigratesItsHistory() {
        val h = ServiceHarness()
        val old = h.put("Current")
        val revision = h.history.snapshot("Before identity\r\n".encodeToByteArray(), old.identity, h.clock.date)
        assertFailsWith<LibraryError.IdentityMismatch> { h.library.restore(revision, "b.md") }
        val restored = h.library.restore(revision, "a.md", old.stamp).entry
        assertNotNull(restored.document.frontMatter.id)
        assertEquals("Before identity\r\n", restored.document.body)
        assertEquals(2, h.history.revisions(restored.identity).size)
        assertTrue(h.history.revisions(old.identity).isEmpty())
    }

    @Test fun failedResurrectionPreservesAssignedHistoryAndDoesNotPublish() {
        val h = ServiceHarness()
        h.put("Original")
        val first = h.library.assignIdentity("a.md").entry
        val revisions = h.history.revisions(first.identity)
        h.library.delete("a.md")
        val before = h.state.bytesSnapshot()
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.restore(revisions.single(), "a.md") }
        assertEquals(before, h.state.bytesSnapshot())
        assertNull(h.prompts.stamp("a.md"))
        assertTrue(h.index.snapshot().prompts.isEmpty())
    }

    @Test fun invalidPathsRejectMutationsBeforeEntropyOrStateIO() {
        val h = ServiceHarness()
        h.put("Original")
        val accesses = h.prompts.accesses
        val invalid = listOf("", "/a.md", "../a.md", "./a.md", "a//b.md", "a/../b.md", "a/./b.md",
            "a\\b.md", "a\u0000.md", "a\n.md", "README.md", "_a.md", "_dir/a.md", ".git/a.md", "a.MD", "a.txt", "é".repeat(511) + ".md")
        for (path in invalid) {
            assertFails { h.library.save(h.draft("Body"), path) }
            assertFails { h.library.create(h.draft("Body"), path) }
            assertFails { h.library.delete(path) }
            assertFails { h.library.move("a.md", path) }
            assertEquals(accesses, h.prompts.accesses)
        }
        assertTrue(h.entropy.requests.isEmpty())
        assertTrue(h.state.bytesSnapshot().isEmpty())
        assertEquals(listOf("a.md"), h.prompts.listFiles().map { it.relativePath })
    }

    @Test fun identityHeaderSizeAndGeneratorFailuresDoNotStageState() {
        val h = ServiceHarness()
        assertFailsWith<PromptWriteError.SourceTooLarge> { h.library.create(h.draft("x".repeat(Limits.maxPromptBytes)), "a.md") }
        h.clock.date = Instant.ofEpochSecond(-1)
        assertFailsWith<ULIDGenerationError.InvalidTimestamp> { h.library.create(h.draft("Body"), "a.md") }
        h.clock.date = Instant.EPOCH
        h.entropy.value = byteArrayOf(1)
        assertFailsWith<ULIDGenerationError.InvalidEntropyLength> { h.library.create(h.draft("Body"), "a.md") }
        h.entropy.error = IllegalStateException("private provider body")
        val sanitized = assertFailsWith<LibraryError.OperationFailed> { h.library.create(h.draft("Body"), "a.md") }
        assertFalse(sanitized.toString().contains("private"))
        assertNull(sanitized.cause)
        assertTrue(h.state.bytesSnapshot().isEmpty())
        assertTrue(h.prompts.bytesSnapshot().isEmpty())
    }

    @Test fun postCommitReadFailureRequiresReloadAndDoesNotReverseTheCommittedMigration() {
        val h = populatedLocalState()
        var published = false
        h.prompts.onWrite = { published = true }
        h.prompts.fault = { op, _ -> if (published && op == MemoryStore.Operation.READ) StoreError.IOFailure else null }
        assertFailsWith<LibraryError.CommitUnverified> { h.library.assignIdentity("a.md") }
        h.prompts.fault = null
        val saved = h.library.load("a.md")
        assertIs<PromptIdentity.Assigned>(saved.identity)
        assertEquals(mapOf("field" to "remembered"), h.values.rememberedValues(saved.identity))
        assertTrue(h.values.rememberedValues(PromptIdentity.at("a.md")).isEmpty())
        assertEquals(2, h.history.revisions(saved.identity).size)
    }

    private fun populatedLocalState(): ServiceHarness {
        val h = ServiceHarness()
        val old = h.put("{{field}}")
        h.values.record(old.identity, mapOf("field" to "remembered"))
        h.usage.recordUse(old.identity)
        h.history.snapshot("Older".encodeToByteArray(), old.identity, Instant.EPOCH)
        return h
    }
}
