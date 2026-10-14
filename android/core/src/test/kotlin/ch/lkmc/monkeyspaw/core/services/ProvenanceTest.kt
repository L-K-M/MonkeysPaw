package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantTokenUsage
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.serialization.json.*
import java.security.MessageDigest
import java.time.Instant
import kotlin.test.*

class ProvenanceTest {
    private val metadata = origin(1234)

    private fun origin(millis: Long) = PromptProvenance(Instant.ofEpochMilli(millis), "example.com", "model-1",
        AssistantTokenUsage(11, 7))
    private fun head(identity: PromptIdentity) = "history/${identity.storageKey}/head.json"
    private fun sidecar(h: ServiceHarness, revision: HistoryRevision) = h.statePath(revision) + ".json"
    private fun save(h: ServiceHarness, source: String, provenance: PromptProvenance? = null): LibrarySaveResult =
        h.library.save(h.draft(source), "a.md", h.prompts.stamp("a.md"), provenance)
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun record(h: ServiceHarness, path: String) = Json.parseToJsonElement(h.state.text(path)).jsonObject
    private fun change(h: ServiceHarness, path: String, key: String, value: JsonElement) =
        h.state.put(JsonObject(record(h, path) + (key to value)).toString(), path)

    @Test fun manualSaveClearsAnUnavailableLegacyHeadAfterCommitting() {
        val h = ServiceHarness()
        val generated = h.library.create(h.draft("Generated"), "a.md").entry
        val path = "history/${generated.identity.storageKey}/head.json"
        h.state.put("Corrupt JSON", path)

        val saved = h.library.save(h.draft("Manual"), "a.md", generated.stamp)

        assertEquals("Manual", saved.entry.document.body)
        assertEquals(saved.entry.stamp, h.prompts.stamp("a.md"))
        assertNull(h.state.stamp(path))
        assertTrue(saved.provenanceMaintenanceFailed)
        assertFalse(saved.historyMaintenanceFailed)
    }

    @Test fun newHeadIsVersionedUTCPrivateContentBoundAndHasNoFakePriorRevision() {
        val h = ServiceHarness()
        val generated = h.library.create(h.draft("Generated\r\n"), "a.md", metadata).entry
        val path = head(generated.identity)
        assertEquals(metadata, h.library.provenance("a.md"))
        assertTrue(h.history.revisions(generated.identity).isEmpty())
        assertTrue(h.state.isPrivate(path))
        val expected = """{"contentSHA256":"${hash(h.prompts.read("a.md"))}","model":"model-1","origin":"llm","providerHost":"example.com","timestamp":"1970-01-01T00:00:01.234Z","usage":{"inputTokens":11,"outputTokens":7},"version":1}"""
        assertContentEquals(expected.encodeToByteArray(), h.state.read(path))
        assertEquals(setOf(path), h.state.bytesSnapshot().keys)
        h.prompts.put(generated.document.source + "External", "a.md")
        assertNull(h.library.provenance("a.md"))
    }

    @Test fun serializerPreservesUnicodeEscapingOptionalUsageAndMillisecondUTC() {
        val h = ServiceHarness()
        val attribution = metadata.copy(timestamp = Instant.parse("2026-10-14T12:13:14.567890123Z"),
            providerHost = "例.example", model = "model/\"e\u0301👋\n\\", usage = null)
        val entry = save(h, "Body", attribution).entry
        val path = head(entry.identity)
        assertEquals(attribution.copy(timestamp = Instant.parse("2026-10-14T12:13:14.567Z")), h.library.provenance("a.md"))
        assertFalse("usage" in record(h, path))
        assertTrue(h.state.text(path).contains("model\\/"))
        change(h, path, "usage", JsonNull)
        assertNull(h.library.provenance("a.md")?.usage)
        change(h, path, "usage", JsonObject(mapOf("inputTokens" to JsonPrimitive(Long.MAX_VALUE), "outputTokens" to JsonPrimitive(0))))
        assertEquals(AssistantTokenUsage(Long.MAX_VALUE, 0), h.library.provenance("a.md")?.usage)
        change(h, path, "version", JsonPrimitive(1.0))
        change(h, path, "extension", JsonObject(mapOf("future" to JsonPrimitive(1.25))))
        assertNotNull(h.library.provenance("a.md"))
    }

    @Test fun manualSaveArchivesOriginAndRestoreRecoversItWithoutChangingBodyOrIdentity() {
        val h = ServiceHarness()
        val first = save(h, "Generated\r\n", metadata).entry
        val manual = save(h, "Manual").entry
        assertEquals(first.identity, manual.identity)
        assertNull(h.library.provenance("a.md"))
        val revision = h.history.revisions(manual.identity).single()
        assertContentEquals(first.document.source.encodeToByteArray(), h.history.read(revision))
        assertEquals(metadata, h.library.provenance(revision))
        assertEquals(metadata, h.editing.history(manual.identity, "a.md").single().provenance)
        val restored = assertIs<EditResult.Saved>(h.editing.restore(revision, "a.md", manual.stamp)).commit
        assertFalse(restored.provenanceMaintenanceFailed)
        assertEquals(first.identity, restored.entry.identity)
        assertEquals("Generated\r\n", restored.entry.document.body)
        assertEquals(metadata, h.library.provenance("a.md"))
        assertNull(h.library.provenance(h.history.revisions(first.identity).first()))
    }

    @Test fun historyOmitsCorruptMetadataButRestoreCommitsWithWarningAndIOStillFails() {
        val h = ServiceHarness()
        var entry = save(h, "First", origin(1000)).entry
        for ((offset, source) in listOf("Second", "Third", "Current").withIndex()) {
            entry = save(h, source, origin((offset + 2) * 1000L)).entry
        }
        val revisions = h.history.revisions(entry.identity)
        val corrupt = revisions[1]
        val path = sidecar(h, corrupt)
        h.state.put("Corrupt JSON", path)
        val before = h.state.bytesSnapshot()
        val snapshots = h.editing.history(entry.identity, "a.md")
        assertEquals(revisions, snapshots.map { it.revision })
        assertEquals(listOf("Third", "Second", "First"), snapshots.map { it.document.body })
        assertEquals(listOf(origin(3000), null, origin(1000)), snapshots.map { it.provenance })
        assertFailsWith<LibraryError.InvalidProvenance> { h.library.provenance(corrupt) }
        assertEquals(before, h.state.bytesSnapshot())
        val restored = assertIs<EditResult.Saved>(h.editing.restore(corrupt, "a.md", entry.stamp)).commit
        assertTrue(restored.provenanceMaintenanceFailed)
        assertFalse(restored.historyMaintenanceFailed)
        assertEquals("Second", restored.entry.document.body)
        assertEquals(restored.entry.stamp, h.prompts.stamp("a.md"))
        assertNull(h.library.provenance("a.md"))
        assertEquals("Corrupt JSON", h.state.text(path))

        for (unreadable in listOf(path, h.statePath(corrupt))) {
            h.state.fault = { operation, target ->
                if (operation == MemoryStore.Operation.READ && target == unreadable) StoreError.IOFailure else null
            }
            assertFailsWith<StoreError.IOFailure> { h.editing.history(entry.identity, "a.md") }
            assertFailsWith<StoreError.IOFailure> { h.library.restore(corrupt, "a.md", restored.entry.stamp) }
            assertIs<StoreError.IOFailure>(assertIs<EditResult.Failed>(h.editing.restore(corrupt, "a.md", restored.entry.stamp)).error)
            assertEquals(restored.entry.stamp, h.prompts.stamp("a.md"))
        }
    }

    @Test fun staleHeadAndRevisionHashesNeverAttributeChangedBytes() {
        val h = ServiceHarness()
        val first = save(h, "Generated", metadata).entry
        h.prompts.put(first.document.source + "External", "a.md")
        val manual = save(h, "Manual").entry
        val revision = h.history.revisions(manual.identity).single()
        assertNull(h.library.provenance(revision))
        assertNull(h.state.stamp(sidecar(h, revision)))
        h.history.archiveProvenance(metadata, revision, "Different bytes".encodeToByteArray())
        assertNull(h.library.provenance(revision))
        assertNull(h.editing.history(manual.identity, "a.md").single().provenance)
        assertFalse(h.library.restore(revision, "a.md", manual.stamp).provenanceMaintenanceFailed)
        assertNull(h.library.provenance("a.md"))
    }

    @Test fun localRenameMoveFirstIDMigrationAndDeleteKeepAllRevisionRecords() {
        val h = ServiceHarness()
        val old = h.put("Original")
        val revision = h.history.snapshot("Older".encodeToByteArray(), old.identity, h.clock.date)
        h.history.setHeadProvenance(metadata, old.identity, "Original".encodeToByteArray())
        h.history.archiveProvenance(metadata, revision, "Older".encodeToByteArray())
        val renamed = assertIs<LibraryMoveResult.Moved>(h.library.move("a.md", "renamed.md", old.stamp)).entry
        val moved = assertIs<LibraryMoveResult.Moved>(h.library.move("renamed.md", "folder/renamed.md", renamed.stamp)).entry
        assertNotEquals(old.identity, renamed.identity)
        assertNotEquals(renamed.identity, moved.identity)
        assertEquals(metadata, h.library.provenance(moved.relativePath))
        val assigned = h.library.assignIdentity(moved.relativePath, moved.stamp).entry
        assertIs<PromptIdentity.Assigned>(assigned.identity)
        val revisions = h.history.revisions(assigned.identity)
        assertEquals(2, revisions.size)
        revisions.forEach { assertEquals(metadata, h.library.provenance(it)) }
        assertNull(h.library.provenance(assigned.relativePath))
        val before = h.state.bytesSnapshot()
        h.library.delete(assigned.relativePath, assigned.stamp)
        assertEquals(before, h.state.bytesSnapshot())
        assertEquals(revisions, h.history.revisions(assigned.identity))
        val restored = h.library.restore(revisions.last(), "resurrected.md").entry
        assertEquals(assigned.identity, restored.identity)
        assertEquals(metadata, h.library.provenance("resurrected.md"))
    }

    @Test fun assignedMovesPreserveHeadAndRevisionAttributionWithoutStateWrites() {
        val h = ServiceHarness()
        val first = save(h, "First", origin(1000)).entry
        val second = save(h, "Second", origin(2000)).entry
        val before = h.state.bytesSnapshot()
        h.library.move("a.md", "b.md", second.stamp)
        val moved = assertIs<LibraryMoveResult.Moved>(h.library.move("b.md", "folder/b.md", second.stamp)).entry
        assertEquals(first.identity, moved.identity)
        assertEquals(before, h.state.bytesSnapshot())
        assertEquals(origin(2000), h.library.provenance(moved.relativePath))
        assertEquals(origin(1000), h.library.provenance(h.history.revisions(moved.identity).single()))
        h.library.delete(moved.relativePath, moved.stamp)
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun capPrunesSidecarsOldestFirstAndLeavesUnrelatedFiles() {
        val h = ServiceHarness()
        val first = save(h, "0", metadata).entry
        val directory = "history/${first.identity.storageKey}"
        h.state.put("Keep", "settings.json")
        h.state.put("Keep too", "$directory/unrecognized.json")
        for (index in 1..Limits.historyCapPerPrompt + 3) save(h, "$index", metadata)
        val revisions = h.history.revisions(first.identity)
        assertEquals(Limits.historyCapPerPrompt, revisions.size)
        revisions.forEach { assertEquals(metadata, h.library.provenance(it)) }
        assertEquals(Limits.historyCapPerPrompt, h.state.bytesSnapshot().keys.count { it.endsWith(".md.json") })
        assertEquals("Keep", h.state.text("settings.json"))
        assertEquals("Keep too", h.state.text("$directory/unrecognized.json"))
    }

    @Test fun orphanedSidecarsAreIgnoredWithoutBeingRead() {
        val h = ServiceHarness()
        save(h, "First", metadata)
        val entry = save(h, "Second").entry
        val revision = h.history.revisions(entry.identity).single()
        h.state.delete(h.statePath(revision))
        h.state.onRead = { if (it == sidecar(h, revision)) fail("Read orphaned attribution") }
        assertTrue(h.editing.history(entry.identity, "a.md").isEmpty())
        assertFailsWith<LibraryError.RevisionNotFound> { h.library.provenance(revision) }
    }

    @Test fun headAndArchiveWriteFailuresCarryTheCommitWithoutAnotherFileWrite() {
        for (archive in listOf(false, true)) {
            val h = ServiceHarness()
            if (archive) save(h, "Before", metadata)
            val promptWrites = h.prompts.writes.size
            h.state.fault = { operation, path ->
                if (operation == MemoryStore.Operation.PRIVATE_WRITE && path.endsWith(if (archive) ".md.json" else "/head.json")) {
                    StoreError.IOFailure
                } else null
            }
            val saved = save(h, "Committed", metadata)
            assertTrue(saved.provenanceMaintenanceFailed)
            assertFalse(saved.historyMaintenanceFailed)
            assertEquals(promptWrites + 1, h.prompts.writes.size)
            assertEquals("Committed", saved.entry.document.body)
            assertEquals(saved.entry.stamp, h.prompts.stamp("a.md"))
            assertEquals(saved.entry.stamp, h.index.snapshot().prompts.single().entry.stamp)
            if (archive) assertEquals(metadata, h.library.provenance("a.md"))
        }
    }

    @Test fun unreadableHeadIsACommittedSaveWarningButExplicitReadsStillFail() {
        val h = ServiceHarness()
        val first = save(h, "Generated", metadata).entry
        h.state.fault = { op, path -> if (op == MemoryStore.Operation.READ && path == head(first.identity)) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.provenance("a.md") }
        val saved = assertIs<EditResult.Saved>(h.editing.save("Manual", "a.md", first.stamp)).commit
        assertTrue(saved.provenanceMaintenanceFailed)
        assertNull(h.state.stamp(head(first.identity)))
        assertEquals("Manual", saved.entry.document.body)
    }

    @Test fun publicationFailureRemovesStagedSidecarsAndPreservesHead() {
        val h = ServiceHarness()
        val first = save(h, "Before", metadata).entry
        val before = h.state.bytesSnapshot()
        h.prompts.fault = { op, _ -> if (op == MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { save(h, "Failed", metadata) }
        assertEquals(before, h.state.bytesSnapshot())
        assertEquals(metadata, h.library.provenance("a.md"))
        assertEquals(first.stamp, h.prompts.stamp("a.md"))
    }

    @Test fun firstIDSaveAndFailedMoveRollBackAllMigratedAttribution() {
        for (move in listOf(false, true)) {
            val h = ServiceHarness()
            val old = h.put("Original")
            val revision = h.history.snapshot("Older".encodeToByteArray(), old.identity, h.clock.date)
            h.history.setHeadProvenance(metadata, old.identity, "Original".encodeToByteArray())
            h.history.archiveProvenance(metadata, revision, "Older".encodeToByteArray())
            val before = h.state.bytesSnapshot()
            h.prompts.fault = { op, _ -> if (op == if (move) MemoryStore.Operation.MOVE else MemoryStore.Operation.WRITE) StoreError.IOFailure else null }
            assertFailsWith<StoreError.IOFailure> {
                if (move) h.library.move("a.md", "b.md", old.stamp) else h.library.assignIdentity("a.md", old.stamp)
            }
            assertEquals(before, h.state.bytesSnapshot())
            assertEquals(old.identity, h.library.load("a.md").identity)
            assertEquals(metadata, h.library.provenance("a.md"))
        }
    }

    @Test fun partialSidecarMigrationRollsBackAndAHeadOnlyDestinationBlocksIt() {
        val h = ServiceHarness()
        val old = h.put("Original")
        val target = PromptIdentity.at("b.md")
        val revision = h.history.snapshot("Older".encodeToByteArray(), old.identity, h.clock.date)
        h.history.setHeadProvenance(metadata, old.identity, "Original".encodeToByteArray())
        h.history.archiveProvenance(metadata, revision, "Older".encodeToByteArray())
        val before = h.state.bytesSnapshot()
        var moves = 0
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.MOVE && ++moves == 2) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.library.move("a.md", "b.md", old.stamp) }
        assertEquals(before, h.state.bytesSnapshot())
        h.state.fault = null
        h.history.setHeadProvenance(metadata, target, "Unrelated".encodeToByteArray())
        val collision = h.state.bytesSnapshot()
        assertFailsWith<LibraryError.KeyedStateConflict> { h.library.move("a.md", "b.md", old.stamp) }
        assertEquals(collision, h.state.bytesSnapshot())
        assertNull(h.prompts.stamp("b.md"))
    }

    @Test fun externalReplacementAfterPublicationKeepsArchivedProvenance() {
        val h = ServiceHarness()
        val first = save(h, "Before", metadata).entry
        var published = false
        h.prompts.onWrite = { published = true }
        h.prompts.onStamp = { path ->
            if (published) {
                h.prompts.onStamp = null
                h.prompts.put(first.document.source + "External", path)
            }
        }
        assertIs<EditResult.Conflict>(h.editing.save("Committed", "a.md", first.stamp))
        val revision = h.history.revisions(first.identity).single()
        assertEquals(metadata, h.library.provenance(revision))
        assertNull(h.library.provenance("a.md"))
    }

    @Test fun unknownVersionsAndInvalidRecordFieldsFailExplicitlyThenManualSaveWarns() {
        val invalid = listOf(
            "version" to JsonPrimitive(2), "version" to JsonPrimitive(true), "version" to JsonPrimitive("1"),
            "origin" to JsonPrimitive("manual"), "timestamp" to JsonPrimitive("1970-01-01T00:00:01Z"),
            "timestamp" to JsonPrimitive("1970-01-01T00:00:01.234+00:00"),
            "timestamp" to JsonPrimitive("1970-02-30T00:00:01.234Z"),
            "providerHost" to JsonPrimitive(""), "model" to JsonPrimitive(""), "contentSHA256" to JsonPrimitive(10),
            "usage" to JsonObject(mapOf("inputTokens" to JsonPrimitive(-1), "outputTokens" to JsonPrimitive(0))),
            "usage" to JsonObject(mapOf("inputTokens" to JsonPrimitive(1.5), "outputTokens" to JsonPrimitive(0))),
            "usage" to JsonObject(mapOf("inputTokens" to JsonPrimitive(0))),
        )
        for ((key, value) in invalid) {
            val h = ServiceHarness()
            val first = save(h, "Before", metadata).entry
            change(h, head(first.identity), key, value)
            assertFailsWith<LibraryError.InvalidProvenance> { h.library.provenance("a.md") }
            val saved = save(h, "Manual")
            assertTrue(saved.provenanceMaintenanceFailed)
            assertEquals("Manual", saved.entry.document.body)
            assertNull(h.library.provenance("a.md"))
        }
    }

    @Test fun unsupportedRevisionAndMalformedUTF8SidecarsAreOmittedButNotOverwrittenByReads() {
        val h = ServiceHarness()
        save(h, "Generated", metadata)
        val current = save(h, "Manual").entry
        val revision = h.history.revisions(current.identity).single()
        val path = sidecar(h, revision)
        val original = h.state.read(path)
        for (bytes in listOf(original.decodeToString().replace("\"version\":1", "\"version\":2").encodeToByteArray(), byteArrayOf(-1))) {
            h.state.put(bytes, path)
            assertNull(h.editing.history(current.identity, "a.md").single().provenance)
            assertFailsWith<LibraryError.InvalidProvenance> { h.library.provenance(revision) }
            assertContentEquals(bytes, h.state.read(path))
        }
    }

    @Test fun invalidSuppliedMetadataWarnsOnlyAfterTheFileCommits() {
        val invalid = listOf(metadata.copy(timestamp = Instant.ofEpochSecond(-1)),
            metadata.copy(timestamp = Instant.ofEpochSecond(Limits.historyMaxUnixSeconds)),
            metadata.copy(providerHost = ""), metadata.copy(model = ""),
            metadata.copy(usage = AssistantTokenUsage(-1, 0)), metadata.copy(usage = AssistantTokenUsage(0, -1)))
        for (provenance in invalid) {
            val h = ServiceHarness()
            val saved = save(h, "Committed", provenance)
            assertTrue(saved.provenanceMaintenanceFailed)
            assertEquals("Committed", saved.entry.document.body)
            assertEquals(saved.entry.stamp, h.prompts.stamp("a.md"))
            assertNull(h.library.provenance("a.md"))
        }
    }

    @Test fun pruningNeverStripsASurvivingRevisionAndOrphanCleanupFailuresWarn() {
        for (failSidecar in listOf(false, true)) {
            val h = ServiceHarness()
            val first = save(h, "0", metadata).entry
            repeat(Limits.historyCapPerPrompt) { save(h, "${it + 1}", metadata) }
            val oldest = h.history.revisions(first.identity).last()
            val path = if (failSidecar) sidecar(h, oldest) else h.statePath(oldest)
            h.state.fault = { op, target -> if (op == MemoryStore.Operation.DELETE && target == path) StoreError.IOFailure else null }
            val saved = save(h, "Committed", metadata)
            assertTrue(saved.historyMaintenanceFailed)
            assertFalse(saved.provenanceMaintenanceFailed)
            assertEquals(saved.entry.stamp, h.prompts.stamp("a.md"))
            assertNotNull(h.state.stamp(sidecar(h, oldest)))
            if (failSidecar) {
                assertNull(h.state.stamp(h.statePath(oldest)))
                assertFalse(h.editing.history(first.identity, "a.md").any { it.revision == oldest })
            } else assertEquals(metadata, h.library.provenance(oldest))
        }
    }

    @Test fun corruptRestoreCarriesConcurrentHistoryMaintenanceWarning() {
        val h = ServiceHarness()
        save(h, "Generated", metadata)
        val current = save(h, "Manual").entry
        val revision = h.history.revisions(current.identity).single()
        h.state.put("Corrupt JSON", sidecar(h, revision))
        repeat(Limits.historyCapPerPrompt - 1) { h.history.snapshot("Older".encodeToByteArray(), current.identity, h.clock.date) }
        h.state.fault = { op, path -> if (op == MemoryStore.Operation.DELETE && path.endsWith(".md")) StoreError.IOFailure else null }
        val saved = assertIs<EditResult.Saved>(h.editing.restore(revision, "a.md", current.stamp)).commit
        assertTrue(saved.provenanceMaintenanceFailed)
        assertTrue(saved.historyMaintenanceFailed)
        assertEquals("Generated", saved.entry.document.body)
        assertEquals(saved.entry.stamp, h.prompts.stamp("a.md"))
        assertEquals(saved.entry.stamp, h.index.snapshot().prompts.single().entry.stamp)
    }

    @Test fun currentAttributionReadChecksTheEditorStampBeforeReadingMetadata() {
        val h = ServiceHarness()
        val old = save(h, "Before", metadata).entry
        save(h, "After", origin(2000))
        h.state.onRead = { fail("Stale editor must not read current attribution") }
        assertFailsWith<LibraryError.Conflict> { h.library.provenance("a.md", old.stamp) }
    }
}
