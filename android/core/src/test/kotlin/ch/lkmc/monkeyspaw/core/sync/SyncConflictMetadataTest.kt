package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.*
import kotlin.test.*

class SyncConflictMetadataTest {
    private val v = SyncTestValues
    private val original = SyncPromptOrigin.ConflictOf(v.personal)

    @Test fun typedMarkersIgnoreNamesAndOnlyProjectInPrivateScope() {
        assertEquals(original, origin("x-monkeyspaw-conflict-of: '${v.personal.rawValue}'"))
        assertEquals(SyncPromptOrigin.Rescued, origin("x-monkeyspaw-rescued: true"))
        assertNull(origin("x-monkeyspaw-rescued: false"))
        assertNull(origin("title: Ordinary (conflict Device 2026-10-13 2100)"))
        assertNull(SyncConflictMetadata.origin(bytes("x-monkeyspaw-conflict-of: '${v.personal.rawValue}'"), "a.md", SyncPathValidator.Scope.GROUP))
    }

    @Test fun malformedMarkersCannotClaimLineage() {
        val bad = listOf("x-monkeyspaw-conflict-of: false", "x-monkeyspaw-conflict-of: null",
            "x-monkeyspaw-conflict-of: [bad]", "x-monkeyspaw-conflict-of: invalid",
            "x-monkeyspaw-conflict-of: '${v.personal.rawValue.lowercase()}'",
            "x-monkeyspaw-conflict-of: '${v.groupPrompt.rawValue}'", "x-monkeyspaw-rescued: 'true'",
            "x-monkeyspaw-rescued: 1", "x-monkeyspaw-rescued: null",
            "x-monkeyspaw-conflict-of: '${v.personal.rawValue}'\nx-monkeyspaw-rescued: true")
        for (header in bad) {
            val data = bytes(header)
            assertFailsWith<SyncConflictMetadataError.InvalidOrigin>(header) { SyncConflictMetadata.origin(data, "a.md") }
            assertTrue(SyncConflictMetadata.hasInvalidOrigin(PromptCodec.parseFile(data, "a.md")))
            for (scope in SyncPathValidator.Scope.entries) {
                val ingested = SyncConflictMetadata.ingest(data, "a.md", scope)
                assertNull(ingested.origin)
                assertEquals(SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE), ingested.issue)
            }
            assertFailsWith<SyncConflictMetadataError.InvalidOrigin> { SyncConflictMetadata.settingOrigin(null, data, "a.md") }
        }
    }

    @Test fun unrenderableDocumentsRemainDistinctFromInvalidMarkers() {
        for (data in listOf(byteArrayOf(-1), bytes("x-monkeyspaw-rescued: true\nx-monkeyspaw-rescued: false"),
            "---\nformat: 2\n---\nFuture".encodeToByteArray())) {
            assertFailsWith<SyncConflictMetadataError.InvalidPrompt> { SyncConflictMetadata.origin(data, "a.md") }
            assertFailsWith<SyncConflictMetadataError.InvalidPrompt> { SyncConflictMetadata.ingest(data, "a.md", SyncPathValidator.Scope.USER) }
            assertFalse(SyncConflictMetadata.hasInvalidOrigin(PromptCodec.parseFile(data, "a.md")))
        }
    }

    @Test fun markersSurviveOrdinaryCopyRenameAndExactPrivateCanonicalization() {
        val body = "Body\r\n\uFEFFTail\r\n"
        val marked = SyncConflictMetadata.settingOrigin(original, bytes("favorite: true\nx-custom:\n  nested: [true, 1, '1']", body), "a.md")
        val document = PromptCodec.parseFile(marked, "a.md")
        val idless = PromptDocument(document.source, document.body, document.frontMatter.copy(id = null), document.template,
            document.decodingIssues, document.preservedHeader?.copy(entries = document.preservedHeader.entries.filterNot {
                PortableYaml.string(it.key) == "id"
            }), document.declarationLocations)
        val copied = PromptCodec.write(PromptMutations.assigningIdentity(v.device, idless, "Copy.md")).encodeToByteArray()
        assertEquals(original, SyncConflictMetadata.origin(copied, "Renamed elsewhere.md"))
        assertEquals(body, PromptCodec.parseFile(copied, "Renamed elsewhere.md").body)
        assertContentEquals(copied, CanonicalForm.user(copied, "Renamed elsewhere.md").bytes)
        assertTrue(copied.decodeToString().contains("x-custom:"))
        val unchanged = SyncConflictMetadata.settingOrigin(original, marked, "a.md")
        assertContentEquals(marked, unchanged)
        unchanged.fill(0)
        assertEquals(original, SyncConflictMetadata.origin(marked, "a.md"))
    }

    @Test fun keepBothClearsBothKeysAndPreservesBodyAndTypedMetadata() {
        for (marker in listOf("x-monkeyspaw-conflict-of: '${v.personal.rawValue}'", "x-monkeyspaw-rescued: true", "x-monkeyspaw-rescued: false")) {
            val input = bytes("$marker\nx-extra: 'keep'\nx-types: [true, 1, '1']", "Exact\r\n\n")
            val cleared = SyncConflictMetadata.settingOrigin(null, input, "Copy.md")
            assertNull(SyncConflictMetadata.origin(cleared, "Copy.md"))
            assertFalse(cleared.decodeToString().contains("x-monkeyspaw-"))
            assertEquals("Exact\r\n\n", PromptCodec.parseFile(cleared, "Copy.md").body)
            assertTrue(cleared.decodeToString().contains("x-extra: keep"))
            val header = PromptCodec.parseFile(cleared, "Copy.md").preservedHeader!!
            val types = header.entries.single { PortableYaml.string(it.key) == "x-types" }.value as YamlNode.Sequence
            assertEquals(listOf(YamlTag.BOOL, YamlTag.INT, YamlTag.STR), types.values.map { (it as YamlNode.Scalar).tag })
            assertEquals("1", PortableYaml.string(types.values.last()))
        }
        val ordinary = bytes("# exact comment\nx-extra: keep")
        assertContentEquals(ordinary, SyncConflictMetadata.settingOrigin(null, ordinary, "Copy.md"))
        assertFailsWith<SyncConflictMetadataError.InvalidOrigin> {
            SyncConflictMetadata.settingOrigin(SyncPromptOrigin.ConflictOf(v.groupPrompt), ordinary, "Copy.md")
        }
    }

    @Test fun privatePullIngestsCrossDeviceMarkersAnywhereAndClearsOldOrigin() {
        for (marker in listOf("x-monkeyspaw-conflict-of: '${v.personal.rawValue}'", "x-monkeyspaw-rescued: true", "x-monkeyspaw-rescued: false", "title: Cleared")) {
            val h = ReconciliationHarness()
            val old = h.baseline(h.record(id = v.groupPrompt, path = "Elsewhere/Renamed.md"))
            h.states.update(h.rig.binding) { old.copy(prompts = old.prompts.mapValues { it.value.copy(origin = original) }) }
            val data = bytes(marker)
            h.collected(h.scope(items = listOf(h.upsert(10, v.groupPrompt, "Elsewhere/Renamed.md", 2, bytes = data)))).use { pull ->
                val plan = h.plan(pull)
                assertEquals(origin(marker), plan.nextState.prompts.getValue(v.groupID).origin)
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertContentEquals(data, h.files.read("Elsewhere/Renamed.md"))
            }
        }
    }

    @Test fun invalidLocalMarkersBecomePermanentRawHoldsAfterJournalRemovalAndRestart() {
        val h = SyncJournalHarness()
        val raw = bytes("x-monkeyspaw-rescued: 'true'", "Keep raw\r\n")
        h.local.prompts.put(raw, "Groups/Team/a.md")
        val source = h.mutations.read("Groups/Team/a.md")!!
        val requested = SyncPromptOrigin.ConflictOf(v.groupPrompt)
        val destination = SyncNaming.conflict(source.path, null, "Device", h.local.clock.date, listOf(source.path))
        val copy = SyncReconciliationCopy(h.mutations.rescue(source, destination, v.device, requested), requested)
        assertEquals(SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE), copy.edit.heldIssue)
        assertNull(copy.edit.copyID)
        assertContentEquals(raw, copy.edit.bytes)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(h.plan(listOf(copy.edit))))
        val restarted = h.restart()
        assertNull(restarted.journal.pending)
        val hold = restarted.journal.heldRescues(restarted.binding.root).single()
        assertEquals(copy.edit.path, hold.path)
        assertEquals(source.path, hold.sourcePath)
        assertEquals(copy.origin, hold.origin)
        assertEquals(SyncHash.of(raw), hold.hash)
        assertTrue(restarted.journal.heldRescues(SyncLibraryRoot("/other-root")).isEmpty())
        assertContentEquals(raw, restarted.local.prompts.read(hold.path))
        restarted.local.state.put("tampered", "sync/retained/${copy.edit.id}.bin")
        assertFailsWith<SyncError.InvalidState> { restarted.journal.heldRescues(restarted.binding.root) }
    }

    private fun origin(header: String): SyncPromptOrigin? = SyncConflictMetadata.origin(bytes(header), "a.md")
    private fun bytes(header: String, body: String = "Body"): ByteArray =
        "---\nid: '${v.groupPrompt.rawValue}'\n$header\n---\n$body".encodeToByteArray()
}
