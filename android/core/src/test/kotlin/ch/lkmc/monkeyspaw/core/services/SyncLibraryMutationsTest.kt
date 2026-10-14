package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.paths.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.UUID
import kotlin.test.*

class SyncLibraryMutationsTest {
    private val v = SyncTestValues
    private fun source(id: String = v.personal.rawValue, body: String = "body\n") = "---\nid: '$id'\n---\n$body"
    private fun publication(h: SyncMutationHarness, old: SyncLibraryFile?, path: String = old?.path ?: "a.md",
                            bytes: ByteArray = source().encodeToByteArray(), kind: SyncLibraryEdit.Kind = SyncLibraryEdit.Kind.APPLY) =
        h.mutations.publication(bytes, path, old, SyncIdentityTransition(old?.identity, v.personalID), kind = kind)

    @Test fun exactServerBytesNeverPassThroughTheWriterAndReplayReestablishesModes() {
        val h = SyncMutationHarness()
        val old = h.put(source(body = "old"))
        val bytes = ("---\n# keep comment\nid: '${v.personal.rawValue}'\ntitle: '  title  '\nx-extra: [true, 7]\n---\n" +
            "BOM:\ufeff café e\u0301\r\ntrailing\n\n").encodeToByteArray()
        val edit = h.mutations.publication(bytes, old.path, old, SyncIdentityTransition(old.identity, v.personalID), SyncFileMode.READ_ONLY)
        val result = h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
        assertEquals(SyncLibraryMutationOutcome.APPLIED, result.outcome)
        assertEquals(SyncFileMutationEffect.APPLIED, result.effect)
        assertContentEquals(old.bytes, result.displacedBytes)
        assertContentEquals(bytes, h.local.prompts.read(old.path))
        assertEquals(SyncHash.of(bytes), h.mutations.read(old.path)?.hash)
        assertEquals(SyncFileMode.READ_ONLY, h.operations.modes[old.path])
        h.operations.modes[old.path] = SyncFileMode.NORMAL
        val writes = h.local.prompts.writes.size
        h.mutations.apply(edit, SyncLibraryMutations.Attempt.REPLAY)
        h.mutations.apply(edit, SyncLibraryMutations.Attempt.REPLAY)
        assertEquals(writes, h.local.prompts.writes.size)
        assertEquals(SyncFileMode.READ_ONLY, h.operations.modes[old.path])
        assertTrue(h.operations.calls.contains("file:a.md"))
        assertTrue(h.operations.calls.contains("directory:<root>"))
    }

    @Test fun editAndBaselineBytesAreImmutableIncludingRetainedAndReturnedBytes() {
        val h = SyncMutationHarness()
        val bytes = source(body = "old").encodeToByteArray()
        val file = SyncLibraryFile("a.md", FileStamp("stamp"), bytes)
        val original = bytes.copyOf()
        bytes.fill(0)
        file.bytes.fill(0)
        assertContentEquals(original, file.bytes)
        file.validate()
        val intended = source(body = "new").encodeToByteArray()
        val exact = intended.copyOf()
        val edit = publication(h, file, bytes = intended)
        intended.fill(0)
        edit.bytes!!.fill(0)
        edit.retainedBytes!!.fill(0)
        edit.validate()
        assertContentEquals(exact, edit.bytes)
        assertContentEquals(original, edit.retainedBytes)
        val result = SyncLibraryMutationResult(SyncLibraryMutationOutcome.APPLIED, original)
        result.displacedBytes!!.fill(0)
        assertContentEquals(file.bytes, result.displacedBytes)
        assertEquals("<sync library file>", file.toString())
        assertEquals("<sync library edit>", edit.toString())
    }

    @Test fun changedIncarnationContentOrOccupantIsPreservedBeforeAnyNativePublication() {
        for (replacement in listOf(source(body = "old"), source(body = "changed"), source(v.groupPrompt.rawValue, "occupant"))) {
            val h = SyncMutationHarness()
            val old = h.put(source(body = "old"))
            val edit = publication(h, old)
            h.local.prompts.put(replacement, old.path)
            val result = h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
            assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, result.outcome)
            assertEquals(SyncFileMutationEffect.UNCHANGED, result.effect)
            assertEquals(replacement, h.local.prompts.text(old.path))
            assertTrue(h.operations.calls.isEmpty())
            assertTrue(h.local.prompts.writes.isEmpty())
        }
    }

    @Test fun changedIncarnationDuringReadAbortsAndDoesNotReturnAStaleBaseline() {
        val h = SyncMutationHarness()
        h.put(source())
        h.local.prompts.onRead = { path -> h.local.prompts.onRead = null; h.local.prompts.put(source(), path) }
        assertFailsWith<LibraryError.Conflict> { h.mutations.read("a.md") }
        assertTrue(h.operations.calls.isEmpty())
    }

    @Test fun lateChangedOccupantsAndNewOccupiedDestinationsArePreservedByTheCapabilityCheck() {
        for (absent in listOf(false, true)) {
            val h = SyncMutationHarness()
            val old = if (absent) null else h.put(source(body = "old"))
            val edit = publication(h, old)
            val occupant = source(v.groupPrompt.rawValue, "late occupant")
            h.operations.beforePublish = { h.local.prompts.put(occupant, "a.md") }
            val result = h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
            assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, result.outcome)
            assertEquals(SyncFileMutationEffect.UNCHANGED, result.effect)
            assertEquals(occupant, h.local.prompts.text("a.md"))
            assertTrue(h.local.prompts.writes.isEmpty())
        }
    }

    @Test fun verificationPreservesAnExternalPostPublicationOccupantAndActualAppliedEffect() {
        val h = SyncMutationHarness()
        val old = h.put(source(body = "old"))
        val edit = publication(h, old)
        val occupant = source(v.groupPrompt.rawValue, "new occupant")
        h.operations.afterPublish = { h.local.prompts.put(occupant, "a.md") }
        val result = h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
        assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, result.outcome)
        assertEquals(SyncFileMutationEffect.APPLIED, result.effect)
        assertContentEquals(old.bytes, result.displacedBytes)
        assertEquals(occupant, h.local.prompts.text("a.md"))
    }

    @Test fun additionalDisplacedBytesSurviveTheDocumentedNoncooperatingWriterWindow() {
        val h = SyncMutationHarness()
        val old = h.put(source(body = "baseline"))
        val edit = publication(h, old)
        val racing = source(body = "last instant bytes").encodeToByteArray()
        h.operations.afterCheck = { h.local.prompts.put(racing, "a.md") }
        val result = h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
        assertEquals(SyncLibraryMutationOutcome.APPLIED, result.outcome)
        assertContentEquals(racing, result.displacedBytes)
        assertContentEquals(old.bytes, edit.retainedBytes)
        result.displacedBytes!!.fill(0)
        assertContentEquals(racing, result.displacedBytes)
    }

    @Test fun everyPublicationCapabilityFailureRetainsEffectBytesAndCanReplayTwice() {
        fun rig(): Pair<SyncMutationHarness, SyncLibraryEdit> {
            val h = SyncMutationHarness()
            val old = h.put(source(body = "losing"), "Groups/Team/nested/a.md")
            return h to publication(h, old)
        }
        val (initial, initialEdit) = rig()
        initial.mutations.apply(initialEdit, SyncLibraryMutations.Attempt.FIRST)
        for (cut in 1..initial.operations.calls.size) {
            val (h, edit) = rig()
            h.operations.failAt = cut
            val error = assertFailsWith<SyncFileOperationError> { h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST) }
            if (cut >= 3) {
                assertEquals(SyncFileMutationEffect.APPLIED, error.effect)
                assertEquals(SyncFileFailureCode.DURABILITY_FAILED, error.code)
                assertContentEquals(edit.retainedBytes, error.displacedBytes)
                assertContentEquals(edit.bytes, h.local.prompts.read(edit.path))
            } else {
                assertEquals(SyncFileMutationEffect.UNCHANGED, error.effect)
                assertContentEquals(edit.retainedBytes, h.local.prompts.read(edit.path))
            }
            assertNull(error.cause)
            h.operations.failAt = null
            assertEquals(SyncLibraryMutationOutcome.APPLIED, h.mutations.apply(edit, SyncLibraryMutations.Attempt.REPLAY).outcome)
            val writes = h.local.prompts.writes.size
            assertEquals(SyncLibraryMutationOutcome.APPLIED, h.mutations.apply(edit, SyncLibraryMutations.Attempt.REPLAY).outcome)
            assertEquals(writes, h.local.prompts.writes.size)
            assertContentEquals(edit.bytes, h.local.prompts.read(edit.path))
        }
    }

    @Test fun durabilityFailureAlsoReturnsAdditionalDisplacedBytesRatherThanTheOlderBaseline() {
        val h = SyncMutationHarness()
        val old = h.put(source(body = "baseline"))
        val edit = publication(h, old)
        val racing = source(body = "racing bytes").encodeToByteArray()
        h.operations.afterCheck = { h.local.prompts.put(racing, "a.md") }
        h.operations.failAt = 3
        val error = assertFailsWith<SyncFileOperationError> { h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST) }
        assertEquals(SyncFileMutationEffect.APPLIED, error.effect)
        assertContentEquals(racing, error.displacedBytes)
        assertContentEquals(old.bytes, edit.retainedBytes)
        assertContentEquals(edit.bytes, h.local.prompts.read("a.md"))
    }

    @Test fun trashChecksTheFullBaselineAndReplaysDeletionDurabilityWithoutDeletingAReplacement() {
        val h = SyncMutationHarness()
        val old = h.put(source())
        val edit = h.mutations.trash(old)
        h.operations.beforeTrash = { h.local.prompts.put(source(v.groupPrompt.rawValue, "occupant"), old.path) }
        assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST).outcome)
        assertEquals(v.groupID, h.mutations.read(old.path)?.identity)
        h.operations.beforeTrash = null
        val actual = h.mutations.read(old.path)!!
        val retirement = h.mutations.trash(actual)
        h.operations.failAt = h.operations.calls.size + 3
        val error = assertFailsWith<SyncFileOperationError> { h.mutations.apply(retirement, SyncLibraryMutations.Attempt.FIRST) }
        assertEquals(SyncFileMutationEffect.APPLIED, error.effect)
        assertContentEquals(actual.bytes, error.displacedBytes)
        assertNull(h.local.prompts.stamp(old.path))
        h.operations.failAt = null
        assertEquals(SyncLibraryMutationOutcome.APPLIED, h.mutations.apply(retirement, SyncLibraryMutations.Attempt.REPLAY).outcome)
        h.local.prompts.put(source(), old.path)
        assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, h.mutations.apply(retirement, SyncLibraryMutations.Attempt.REPLAY).outcome)
        assertNotNull(h.local.prompts.stamp(old.path))
    }

    @Test fun modeEditsCoverForensicRegularFilesWithoutRewritingTheirBytes() {
        val h = SyncMutationHarness()
        h.local.prompts.put(byteArrayOf(-1, 0, 10), "Groups/Team/unknown.bin")
        val file = h.mutations.read("Groups/Team/unknown.bin")!!
        val edit = h.mutations.mode(SyncFileMode.READ_ONLY, file)
        assertEquals(SyncLibraryMutationOutcome.APPLIED, h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST).outcome)
        assertTrue(h.local.prompts.writes.isEmpty())
        assertContentEquals(file.bytes, h.local.prompts.read(file.path))
        assertEquals(SyncFileMode.READ_ONLY, h.operations.modes[file.path])
        val writable = h.mutations.mode(SyncFileMode.NORMAL, h.mutations.read(file.path)!!)
        h.mutations.apply(writable, SyncLibraryMutations.Attempt.FIRST)
        assertEquals(SyncFileMode.NORMAL, h.operations.modes[file.path])
    }

    @Test fun validRescuesHaveOneStableFreshPrivateIDAndBodyWithPermanentOrigin() {
        val h = SyncMutationHarness()
        val old = h.put(source(body = "body\r\n\n"), "Groups/Team/a.md")
        val destination = "Conflicts/Team/copy.md"
        val edit = h.mutations.rescue(old, destination, v.groupPrompt, SyncPromptOrigin.ConflictOf(v.personal))
        assertEquals(v.groupPrompt.rawValue, edit.copyID)
        assertEquals(old.path, edit.retainedSourcePath)
        assertContentEquals(old.bytes, edit.retainedBytes)
        h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
        val writes = h.local.prompts.writes.size
        h.mutations.apply(edit, SyncLibraryMutations.Attempt.REPLAY)
        val copy = PromptCodec.parseFile(h.local.prompts.read(destination), "copy.md")
        assertEquals(v.groupPrompt, copy.frontMatter.id)
        assertEquals("body\r\n\n", copy.body)
        assertEquals(SyncPromptOrigin.ConflictOf(v.personal), SyncMutationOrigin.origin(copy))
        assertEquals(writes, h.local.prompts.writes.size)
        assertContentEquals(old.bytes, h.local.prompts.read(old.path))
        assertFailsWith<SyncError.InvalidState> { h.mutations.rescue(old, destination, v.personal) }
    }

    @Test fun forensicFutureNonpromptAndMalformedOriginRescuesKeepExactBytesAndTypedHolds() {
        val inputs = listOf(
            Triple("a.md", byteArrayOf(-1, 0, 1), SyncIssueCode.Content(PromptIssueCode.INVALID_UTF8)),
            Triple("a.md", "---\nformat: 2\n---\nfuture\n".encodeToByteArray(), SyncIssueCode.Content(PromptIssueCode.UNSUPPORTED_FORMAT)),
            Triple("a.bin", "valid looking body\n".encodeToByteArray(), SyncIssueCode.LocalVisibility),
            Triple("a.md", "---\nx-monkeyspaw-rescued: 'true'\n---\nbody\n".encodeToByteArray(), SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE)),
        )
        for ((path, bytes, issue) in inputs) {
            val h = SyncMutationHarness()
            h.local.prompts.put(bytes, path)
            val edit = h.mutations.rescue(h.mutations.read(path)!!, "Conflicts/raw.md", v.groupPrompt)
            assertEquals(issue, edit.heldIssue)
            assertNull(edit.copyID)
            assertContentEquals(bytes, edit.bytes)
            assertContentEquals(bytes, edit.retainedBytes)
            h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
            h.mutations.apply(edit, SyncLibraryMutations.Attempt.REPLAY)
            assertContentEquals(bytes, h.local.prompts.read("Conflicts/raw.md"))
        }
    }

    @Test fun wireAndRootedLimitsAreIndependentAtTheCompleteGroupWrapperAndPlusOne() {
        val wire = "a".repeat(255) + "/" + "b".repeat(255) + "/" + "c".repeat(255) + "/" + "d".repeat(251) + "/a.md"
        assertEquals(1024, wire.encodeToByteArray().size)
        assertEquals(wire, SyncPathValidator.validate(wire, SyncPathValidator.Scope.GROUP).path)
        val overWire = assertFailsWith<SyncPathIssue> {
            SyncPathValidator.validate(wire.removeSuffix(".md") + "x.md", SyncPathValidator.Scope.GROUP)
        }
        assertEquals(SyncPathIssueCode.PATH_TOO_LONG, overWire.code)
        val rooted = "Groups/" + "g".repeat(255) + "/" + wire
        assertEquals(1287, rooted.encodeToByteArray().size)
        val h = SyncMutationHarness()
        val old = h.put(source(), rooted)
        val edit = publication(h, old)
        h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
        assertContentEquals(edit.bytes, h.local.prompts.read(rooted))
        assertFailsWith<StoreError.InvalidPath> { h.mutations.read(rooted + "x") }
        assertFailsWith<StoreError.InvalidPath> { h.mutations.publication(source().encodeToByteArray(), rooted + "x", null,
            SyncIdentityTransition(null as PromptIdentity?, v.personalID)) }
        val privateCopy = "Conflicts/" + "a".repeat(255) + "/" + "b".repeat(255) + "/" + "c".repeat(255) + "/" + "d".repeat(243) + ".md"
        assertEquals(Limits.maxPathBytes, privateCopy.encodeToByteArray().size)
        h.mutations.rescue(old, privateCopy, v.groupPrompt)
        assertFailsWith<SyncError.InvalidState> { h.mutations.rescue(old, privateCopy.removeSuffix(".md") + "x.md", v.groupPrompt) }
    }

    @Test fun fullInventoryIncludesFilteredFilesHiddenAndEmptyDirectoriesAndRefusesRacingListings() {
        val h = SyncMutationHarness()
        h.put(source())
        h.local.prompts.put(byteArrayOf(-1), "_excluded.bin")
        h.local.prompts.put("hidden", ".hidden/raw")
        h.operations.putDirectory("Groups/empty")
        val filtered = object : PromptStore by h.local.prompts {
            override fun listFiles() = h.local.prompts.listFiles().filter { LibraryPath.isPrompt(it.relativePath) }
        }
        val library = LibraryService(filtered, h.local.state, h.local.clock, h.local.entropy)
        val mutations = SyncLibraryMutations(library, h.operations)
        assertEquals(listOf(".hidden/raw", "_excluded.bin", "a.md"), mutations.listedFiles().map { it.path })
        assertEquals(setOf(".hidden", "Groups", "Groups/empty"), mutations.directoryIdentities().keys)
        h.operations.inventory = { h.local.prompts.listFiles().also { h.local.prompts.put(source(), "a.md") } }
        assertFailsWith<LibraryError.Conflict> { mutations.listedFiles() }
    }

    @Test fun alternativeSpellingAdoptionAndRelocationCheckTheSourceBeforeRetiringIt() {
        val h = SyncMutationHarness()
        val old = h.put("idless\n", "Cafe\u0301.md")
        h.local.values.record(old.identity, mapOf("field" to "remembered"))
        val target = "Café.md"
        val edit = h.mutations.publication(source().encodeToByteArray(), target, null,
            SyncIdentityTransition(old.identity, v.personalID), kind = SyncLibraryEdit.Kind.ADOPT, adoptingSource = old)
        val migrations = h.mutations.prepareMigrations(edit)
        assertTrue(h.mutations.canReplan(edit, migrations, false))
        h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST)
        assertFalse(h.mutations.canReplan(edit, migrations, false))
        migrations.forEach { h.mutations.migrate(it, SyncFlushes()) }
        assertEquals(mapOf("field" to "remembered"), h.local.values.rememberedValues(v.personalID))
        assertContentEquals(old.bytes, h.local.prompts.read(old.path))
        h.mutations.apply(h.mutations.trash(old), SyncLibraryMutations.Attempt.FIRST)
        assertNull(h.local.prompts.stamp(old.path))
        val current = h.mutations.read(target)!!
        val relocate = h.mutations.publication(current.bytes, "nested/other.md", null,
            SyncIdentityTransition(current.identity, current.identity), kind = SyncLibraryEdit.Kind.RELOCATE, adoptingSource = current)
        h.local.prompts.put(source(body = "late edit"), target)
        assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, h.mutations.apply(relocate, SyncLibraryMutations.Attempt.FIRST).outcome)
        assertNull(h.local.prompts.stamp(relocate.path))
    }

    @Test fun externallyAssignedAdoptionMigratesTheOriginalPathKeyAndDuplicateRepairDoesNotStealSharedState() {
        val h = SyncMutationHarness()
        val old = h.put(source())
        val localKey = PromptIdentity.at(old.path)
        h.local.values.record(localKey, mapOf("field" to "value"))
        val adopt = h.mutations.publication(old.bytes, old.path, old, SyncIdentityTransition(localKey, old.identity), kind = SyncLibraryEdit.Kind.ADOPT)
        val migrations = h.mutations.prepareMigrations(adopt)
        assertEquals(1, migrations.size)
        migrations.forEach { h.mutations.migrate(it, SyncFlushes()) }
        assertEquals(mapOf("field" to "value"), h.local.values.rememberedValues(old.identity))
        val repaired = h.mutations.publication(source(v.groupPrompt.rawValue).encodeToByteArray(), old.path, old,
            SyncIdentityTransition(old.identity, v.groupID), kind = SyncLibraryEdit.Kind.REPAIR_DUPLICATE)
        assertTrue(h.mutations.prepareMigrations(repaired).isEmpty())
        h.mutations.apply(repaired, SyncLibraryMutations.Attempt.FIRST)
        assertEquals(mapOf("field" to "value"), h.local.values.rememberedValues(v.personalID))
        assertTrue(h.local.values.rememberedValues(v.groupID).isEmpty())
    }

    @Test fun changedOrPartiallyMigratedKeyedStateCannotBeDiscardedByReplanning() {
        val h = SyncMutationHarness()
        val old = h.put("idless")
        h.local.values.record(old.identity, mapOf("field" to "old"))
        val edit = publication(h, old, kind = SyncLibraryEdit.Kind.ADOPT)
        val migrations = h.mutations.prepareMigrations(edit)
        assertTrue(h.mutations.canReplan(edit, migrations, false))
        h.local.values.record(old.identity, mapOf("field" to "external change"))
        assertFalse(h.mutations.canReplan(edit, migrations, false))
        assertTrue(h.mutations.canReplan(edit, migrations, true))
        assertEquals(mapOf("field" to "external change"), h.local.values.rememberedValues(old.identity))
    }

    @Test fun interruptedHistoryMigrationResumesFromSavedIntentOnRecreatedStores() {
        val h = SyncMutationHarness()
        val old = h.put("idless")
        h.local.state.put("first", "history/${old.identityKey}/a.bin")
        h.local.state.put("second", "history/${old.identityKey}/nested/b.bin")
        h.local.values.record(old.identity, mapOf("field" to "value"))
        val edit = publication(h, old, kind = SyncLibraryEdit.Kind.ADOPT)
        val migrations = h.mutations.prepareMigrations(edit)
        assertEquals(3, migrations.size)
        h.mutations.migrate(migrations.first(), SyncFlushes())
        assertFalse(h.mutations.canReplan(edit, migrations, false))
        val flushes = SyncFlushes().also { it.failAt = 1 }
        assertFailsWith<StoreError.IOFailure> { h.mutations.migrate(migrations[1], flushes) }
        val reconstructed = LibraryService(h.local.prompts, h.local.state, h.local.clock, h.local.entropy)
        val mutations = SyncLibraryMutations(reconstructed, h.operations)
        flushes.failAt = null
        repeat(2) { migrations.forEach { mutations.migrate(it, flushes) } }
        assertEquals("first", h.local.state.text("history/${v.personalID.storageKey}/a.bin"))
        assertEquals("second", h.local.state.text("history/${v.personalID.storageKey}/nested/b.bin"))
        assertEquals(mapOf("field" to "value"), reconstructed.values.rememberedValues(v.personalID))
        assertTrue(reconstructed.values.rememberedValues(old.identity).isEmpty())
        assertContentEquals(old.bytes, h.local.prompts.read(old.path))
    }

    @Test fun occupiedKeyedDestinationRefusesPreparationBeforeAnyIdentityPublication() {
        val h = SyncMutationHarness()
        val old = h.put("idless")
        h.local.values.record(old.identity, mapOf("field" to "source"))
        h.local.values.record(v.personalID, mapOf("field" to "occupant"))
        val edit = publication(h, old, kind = SyncLibraryEdit.Kind.ADOPT)
        assertFailsWith<LibraryError.KeyedStateConflict> { h.mutations.prepareMigrations(edit) }
        assertContentEquals(old.bytes, h.local.prompts.read(old.path))
        assertTrue(h.local.prompts.writes.isEmpty())
        assertEquals(mapOf("field" to "occupant"), h.local.values.rememberedValues(v.personalID))
    }

    @Test fun malformedDecodedEditsFailBeforeAnyLibraryOrKeyedIO() {
        val h = SyncMutationHarness()
        val old = h.put(source())
        val intended = source().encodeToByteArray()
        val transition = SyncIdentityTransition(old.identity, v.personalID)
        val bad = listOf(
            SyncLibraryEdit(UUID.randomUUID(), SyncLibraryEdit.Kind.APPLY, old.path, old, intended, v.hash, transition,
                SyncFileMode.NORMAL, old.bytes, old.path),
            SyncLibraryEdit(UUID.randomUUID(), SyncLibraryEdit.Kind.MODE, old.path, old, old.bytes, old.hash, transition,
                SyncFileMode.READ_ONLY, null, null),
            SyncLibraryEdit(UUID.randomUUID(), SyncLibraryEdit.Kind.TRASH, old.path, old, null, null, null,
                SyncFileMode.NORMAL, "wrong".encodeToByteArray(), old.path),
            SyncLibraryEdit(UUID.randomUUID(), SyncLibraryEdit.Kind.APPLY, old.path, old, intended, SyncHash.of(intended),
                SyncIdentityTransition(v.groupID, v.personalID), SyncFileMode.NORMAL, old.bytes, old.path),
        )
        val accesses = h.local.prompts.accesses + h.local.state.accesses
        for (edit in bad) {
            assertFailsWith<SyncError.InvalidState> { h.mutations.apply(edit, SyncLibraryMutations.Attempt.FIRST) }
            assertFailsWith<SyncError.InvalidState> { h.mutations.prepareMigrations(edit) }
            assertFailsWith<SyncError.InvalidState> { h.mutations.verify(edit) }
        }
        assertEquals(accesses, h.local.prompts.accesses + h.local.state.accesses)
        assertTrue(h.operations.calls.isEmpty())
    }

    @Test fun syncAdoptionCanReplaceAssignedIdentityWhileOrdinaryEditorStillRefusesIt() {
        val h = SyncMutationHarness()
        val old = h.put(source(v.groupPrompt.rawValue))
        h.local.values.record(old.identity, mapOf("field" to "value"))
        val replacement = source()
        val editor = h.local.editing.save(replacement, old.path, old.stamp) as EditResult.Failed
        assertEquals(LibraryError.IdentityMismatch, editor.error)
        assertContentEquals(old.bytes, h.local.prompts.read(old.path))
        val adopt = publication(h, old, bytes = replacement.encodeToByteArray(), kind = SyncLibraryEdit.Kind.ADOPT)
        val planID = UUID.randomUUID()
        h.mutations.begin(planID, SyncState(v.binding()))
        val migrations = h.mutations.prepareMigrations(adopt)
        h.mutations.apply(adopt, SyncLibraryMutations.Attempt.FIRST)
        migrations.forEach { h.mutations.migrate(it, SyncFlushes()) }
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.load(old.path) }
        h.mutations.finish(planID)
        assertEquals(v.personalID, h.local.library.load(old.path).identity)
        assertEquals(mapOf("field" to "value"), h.local.values.rememberedValues(v.personalID))
    }
}
