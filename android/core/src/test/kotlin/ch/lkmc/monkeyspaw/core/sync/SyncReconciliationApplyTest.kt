package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.*

class SyncReconciliationApplyTest {
    private val v = SyncTestValues

    @Test fun unknownSnapshotInstallsVerbatimPrivateBytesAndFullHash() {
        val h = ReconciliationHarness()
        val bytes = "---\r\n# comment\r\nid: '${v.personal.rawValue}'\r\nx-unknown: [雪, true]\r\n---\r\n\uFEFFBody\r\n\n".encodeToByteArray()
        h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10, rev = 4, bytes = bytes)))).use { pull ->
            val plan = h.plan(pull)
            val application = SyncReconciler.application(plan, h.mutations)
            application.edits.single().bytes!!.fill(0)
            assertContentEquals(bytes, application.edits.single().bytes)
            assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
            assertContentEquals(bytes, h.files.read("a.md"))
            assertEquals(SyncHash.of(bytes), h.states.snapshot.value?.prompts?.get(v.personalID)?.canonicalHash)
            assertEquals(4, h.states.snapshot.value?.prompts?.get(v.personalID)?.rev)
        }
    }

    @Test fun sourceRetirementUsesUnsignedUtf8PathOrder() {
        val h = ReconciliationHarness()
        h.baseline(h.record(path = "\uE000.md"), h.record(id = v.groupPrompt, path = "🐾.md"))
        h.put("Baseline", "\uE000.md")
        h.put("Baseline", "🐾.md", v.groupPrompt)
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0)).use { pull ->
            val application = SyncReconciler.application(h.plan(pull), h.mutations)
            assertEquals(listOf("\uE000.md", "🐾.md"), application.edits.map { it.path })
            assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
            assertTrue(h.files.listFiles().isEmpty())
        }
    }

    @Test fun dirtyRenameCopiesFirstPublishesServerThenRetiresActualSource() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        val local = h.put("Losing dirty version")
        h.put("Unrelated", "unrelated.md", v.groupPrompt)
        h.collected(h.scope(items = listOf(h.upsert(10, path = "new.md", rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            val application = SyncReconciler.application(plan, h.mutations, h.copy(plan))
            assertEquals(listOf("Conflicts/Copy.md", "new.md", "a.md"), application.edits.map { it.path })
            assertEquals(listOf(SyncLibraryEdit.Kind.RESCUE, SyncLibraryEdit.Kind.APPLY, SyncLibraryEdit.Kind.TRASH), application.edits.map { it.kind })
            val events = mutableListOf<String>()
            h.rig.libraryOperations.onOperation = { events.add(it) }
            h.rig.local.state.onWrite = { path -> if (path == "sync/state.json") events.add("state") }
            assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
            assertTrue(events.indexOf("publish-file-flush:Conflicts/Copy.md") < events.indexOf("publish-install:new.md"))
            assertTrue(events.indexOf("publish-install:new.md") < events.indexOf("trash-unlink:a.md"))
            assertTrue(events.indexOf("trash-parent-flush:a.md") < events.indexOf("state"))
            assertTrue(h.retained().any { it.contentEquals(local.bytes) })
            assertNull(h.files.stamp("a.md"))
            assertContentEquals(h.bytes("Server"), h.files.read("new.md"))
            assertEquals(SyncPromptOrigin.ConflictOf(v.personal), h.states.snapshot.value?.prompts?.get(PromptIdentity.Assigned(v.device))?.origin)
        }
    }

    @Test fun restoreMissingRescueGetsFreshPrivateIDBeforeSourceRetirement() {
        for (dirty in listOf(false, true)) {
            val h = ReconciliationHarness()
            h.baseline(h.record(rev = 99))
            val local = h.put(if (dirty) "Dirty" else "Baseline")
            h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), database = ReconciliationHarness.restored).use { pull ->
                val plan = h.plan(pull)
                val application = SyncReconciler.application(plan, h.mutations, h.copy(plan))
                assertEquals(listOf(SyncLibraryEdit.Kind.RESCUE, SyncLibraryEdit.Kind.TRASH), application.edits.map { it.kind })
                assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
                val copy = h.states.snapshot.value!!.prompts.getValue(PromptIdentity.Assigned(v.device))
                assertEquals(v.userScope, copy.scope)
                assertEquals(0, copy.rev)
                assertNull(copy.canonicalHash)
                assertEquals(SyncPromptOrigin.Rescued, copy.origin)
                assertEquals(v.device, PromptCodec.parseFile(h.files.read(copy.path), "Copy.md").frontMatter.id)
                assertTrue(h.retained().any { it.contentEquals(local.bytes) })
                assertNull(h.states.snapshot.value?.prompts?.get(v.personalID))
            }
        }
    }

    @Test fun restoreViewerCopyStaysPrivateAndReplacementUsesReadOnlyMode() {
        val h = ReconciliationHarness()
        val local = h.groupBytes("Viewer edit")
        h.baseline(h.record(bytes = local, scope = v.groupScope, rev = 99), role = Role.VIEWER)
        h.put(local, "Groups/Team/a.md")
        val remote = h.groupBytes("Restored")
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), h.scope(v.groupScope, Mode.SNAPSHOT, role = Role.VIEWER,
            items = listOf(h.upsert(10, rev = 2, bytes = remote))), database = ReconciliationHarness.restored).use { pull ->
            val plan = h.plan(pull)
            val application = SyncReconciler.application(plan, h.mutations, h.copy(plan))
            assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
            assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes["Groups/Team/a.md"])
            assertEquals(SyncFileMode.NORMAL, h.rig.libraryOperations.modes["Conflicts/Copy.md"])
            assertEquals(v.userScope, h.states.snapshot.value?.prompts?.get(PromptIdentity.Assigned(v.device))?.scope)
            assertContentEquals(remote, h.files.read("Groups/Team/a.md"))
            assertTrue(h.retained().any { it.contentEquals(local) })
        }
    }

    @Test fun invalidLocalVersionIsRetainedRawAndHeldInsteadOfRewritten() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        val invalid = "---\nid: '${v.personal.rawValue}'\nfields: invalid\n---\nLosing invalid prompt".encodeToByteArray()
        assertFalse(PromptCodec.parseFile(invalid, "a.md").canRender)
        h.put(invalid)
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), database = ReconciliationHarness.restored).use { pull ->
            val plan = h.plan(pull)
            val application = SyncReconciler.application(plan, h.mutations, h.copy(plan))
            assertNotNull(application.edits.first().heldIssue)
            assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
            assertContentEquals(invalid, h.files.read("Conflicts/Copy.md"))
            assertNull(h.states.snapshot.value?.prompts?.get(PromptIdentity.Assigned(v.device)))
            val held = h.rig.journal.heldRescues(h.rig.binding.root).single()
            assertEquals("a.md", held.sourcePath)
            assertEquals("Conflicts/Copy.md", held.path)
            assertTrue(h.retained().any { it.contentEquals(invalid) })
        }
    }

    @Test fun trashEditWithMissingPublicationBytesCannotAuthorizePreservation() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        h.put("Losing")
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), database = ReconciliationHarness.restored).use { pull ->
            val plan = h.plan(pull)
            val trash = h.mutations.trash(h.preservation(plan).local)
            h.assertBlocked(plan, mapOf("a.md" to SyncReconciliationCopy(trash, SyncPromptOrigin.Rescued)))
        }
    }

    @Test fun wrongLosingBytesOrOriginCannotAuthorizeOverwrite() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        h.put("Losing")
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            val origin = SyncPromptOrigin.ConflictOf(v.personal)
            val wrong = SyncLibraryFile("a.md", FileStamp("wrong"), h.bytes("Wrong losing bytes"))
            val edit = h.mutations.rescue(wrong, "Conflicts/Copy.md", v.device, origin)
            h.assertBlocked(plan, mapOf("a.md" to SyncReconciliationCopy(edit, origin)))
            val wrongOrigin = h.mutations.rescue(h.preservation(plan).local, "Conflicts/Copy.md", v.device, SyncPromptOrigin.Rescued)
            h.assertBlocked(plan, mapOf("a.md" to SyncReconciliationCopy(wrongOrigin, SyncPromptOrigin.Rescued)))
            h.assertBlocked(plan, h.copy(plan) + ("unneeded.md" to h.copy(plan).getValue("a.md")))
        }
    }

    @Test fun occupiedFoldedCopyDestinationAndExistingIdentityCannotBeUsed() {
        for (identityCollision in listOf(false, true)) {
            val h = ReconciliationHarness()
            h.baseline(h.record())
            h.put("Losing")
            h.put("Occupant", if (identityCollision) "untracked.md" else "Conflicts/copy.md", if (identityCollision) v.device else v.groupPrompt)
            h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
                val plan = h.plan(pull)
                h.assertBlocked(plan, h.copy(plan))
            }
        }
    }

    @Test fun copyCannotTakeAnIncomingServerDestination() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        h.put("Losing")
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 2), h.upsert(11, id = v.groupPrompt, path = "Conflicts/Copy.md")))).use { pull ->
            val plan = h.plan(pull)
            h.assertBlocked(plan, h.copy(plan))
        }
    }

    @Test fun reusedExactCopyKeepsAcknowledgedBaselineAndDoesNotCascade() {
        for (race in listOf(false, true)) {
            val h = ReconciliationHarness()
            val originalOrigin = SyncPromptOrigin.ConflictOf(v.groupPrompt)
            val losingDocument = PromptCodec.parseFile(h.bytes("Losing"), "a.md")
            val losing = SyncMutationOrigin.copyBytes(losingDocument, v.personal, originalOrigin, "a.md")
            val copyBytes = SyncMutationOrigin.copyBytes(PromptCodec.parseFile(losing, "a.md"), v.device, originalOrigin, "Renamed.md")
            val copyHash = SyncHash.of(h.bytes("Previously acknowledged copy", v.device))
            val old = h.baseline(h.record(), PromptIdentity.Assigned(v.device) to SyncPromptState(v.userScope,
                "Conflicts/Old.md", 5, copyHash, originalOrigin))
            h.put(losing)
            val existing = h.put(copyBytes, "Conflicts/Renamed.md")
            h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
                val plan = h.plan(pull)
                val edit = h.mutations.publication(existing.bytes, existing.path, existing, SyncIdentityTransition(existing.identity, existing.identity))
                val application = SyncReconciler.application(plan, h.mutations, mapOf("a.md" to SyncReconciliationCopy(edit, originalOrigin)))
                val intended = application.nextState.prompts.getValue(PromptIdentity.Assigned(v.device))
                assertEquals("Conflicts/Old.md", intended.path)
                assertEquals(5, intended.rev)
                assertEquals(copyHash, intended.canonicalHash)
                assertEquals(originalOrigin, intended.origin)
                if (race) {
                    val late = h.bytes("Later copy edit", v.device)
                    h.files.put(late, existing.path)
                    assertEquals(SyncApplyOutcome.ReplanAsConflict(edit.id), h.rig.journal.apply(application))
                    assertContentEquals(losing, h.files.read("a.md"))
                    assertContentEquals(late, h.files.read(existing.path))
                    assertEquals(old, h.states.snapshot.value)
                } else {
                    assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
                    assertEquals(2, h.files.listFiles().size)
                    assertContentEquals(copyBytes, h.files.read(existing.path))
                    assertContentEquals(h.bytes("Server"), h.files.read("a.md"))
                }
            }
        }
    }

    @Test fun unrelatedExistingCopyCannotRetireTheLosingVersion() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        h.put("Losing")
        val origin = SyncPromptOrigin.ConflictOf(v.personal)
        val document = PromptCodec.parseFile(h.bytes("Different losing version"), "a.md")
        val wrongBytes = SyncMutationOrigin.copyBytes(document, v.device, origin, "Copy.md")
        val existing = h.put(wrongBytes, "Conflicts/Copy.md")
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            val edit = h.mutations.publication(existing.bytes, existing.path, existing, SyncIdentityTransition(existing.identity, existing.identity))
            h.assertBlocked(plan, mapOf("a.md" to SyncReconciliationCopy(edit, origin)))
        }
    }

    @Test fun invalidLocalMarkerCannotAuthorizeReuseOfAnUnheldCopy() {
        val h = ReconciliationHarness()
        val old = h.baseline(h.record())
        val losing = "---\nid: '${v.personal.rawValue}'\nx-monkeyspaw-rescued: invalid\n---\nLosing".encodeToByteArray()
        h.put(losing)
        val origin = SyncPromptOrigin.ConflictOf(v.personal)
        val copyBytes = SyncMutationOrigin.copyBytes(PromptCodec.parseFile(losing, "a.md"), v.device, origin, "Copy.md")
        val existing = h.put(copyBytes, "Conflicts/Copy.md")
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            val edit = h.mutations.publication(existing.bytes, existing.path, existing, SyncIdentityTransition(existing.identity, existing.identity))
            assertFails { SyncReconciler.application(plan, h.mutations, mapOf("a.md" to SyncReconciliationCopy(edit, origin))) }
            assertEquals(old, h.states.snapshot.value)
            assertContentEquals(losing, h.files.read("a.md"))
            assertNull(h.rig.journal.pending)
        }
    }

    @Test fun racingDestinationReplacementAndLateSourceEditBlockAcknowledgement() {
        for (sourceRace in listOf(false, true)) {
            val h = ReconciliationHarness()
            val old = h.baseline(h.record())
            val original = h.put("Baseline")
            h.collected(h.scope(items = listOf(h.upsert(10, path = if (sourceRace) "new.md" else "a.md", rev = 2)))).use { pull ->
                val application = SyncReconciler.application(h.plan(pull), h.mutations)
                val late = h.bytes("Late version", if (sourceRace) v.personal else v.groupPrompt)
                if (sourceRace) h.rig.libraryOperations.afterPublish = { h.files.put(late, "a.md") }
                else h.files.put(late, "a.md")
                val failed = if (sourceRace) application.edits.last() else application.edits.single()
                assertEquals(SyncApplyOutcome.ReplanAsConflict(failed.id), h.rig.journal.apply(application))
                assertContentEquals(late, h.files.read("a.md"))
                if (sourceRace) assertContentEquals(h.bytes("Server"), h.files.read("new.md"))
                assertEquals(old, h.states.snapshot.value)
                assertNotNull(h.rig.journal.pending)
                assertTrue(h.retained().any { it.contentEquals(original.bytes) })
            }
        }
    }

    @Test fun displacedRacingVersionIsRetainedAlongsideExpectedBytes() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        val original = h.put("Baseline")
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            val racing = h.bytes("Noncooperating displaced version")
            h.rig.libraryOperations.afterCheck = { h.files.put(racing, "a.md") }
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
            assertContentEquals(h.bytes("Server"), h.files.read("a.md"))
            assertTrue(h.retained().any { it.contentEquals(original.bytes) })
            assertTrue(h.retained().any { it.contentEquals(racing) })
        }
    }

    @Test fun everyConvertedApplyFailureKeepsOldStateAndReplaysStableCopiesTwice() {
        fun prepared(): Pair<ReconciliationHarness, SyncApplyPlan> {
            val h = ReconciliationHarness()
            h.baseline(h.record())
            h.put("Losing dirty version")
            h.collected(h.scope(items = listOf(h.upsert(10, path = "new.md", rev = 2)))).use { pull ->
                val plan = h.plan(pull)
                return h to SyncReconciler.application(plan, h.mutations, h.copy(plan))
            }
        }
        val (baseline, application) = prepared()
        assertEquals(SyncApplyOutcome.Committed, baseline.rig.journal.apply(application))
        for (data in listOf(false, true)) {
            val count = if (data) baseline.rig.dataOperations.calls.size else baseline.rig.libraryOperations.calls.size
            for (cut in 1..count) {
                val (h, plan) = prepared()
                val operations = if (data) h.rig.dataOperations else h.rig.libraryOperations
                operations.failAt = cut
                assertFails { h.rig.journal.apply(plan) }
                assertEquals(plan.expectedState, h.states.snapshot.value, "data=$data cut=$cut")
                assertNotNull(h.mutations.pendingPermit)
                operations.failAt = null
                assertEquals(SyncApplyOutcome.Committed, h.rig.journal.replay())
                val files = h.files.bytesSnapshot()
                assertEquals(SyncApplyOutcome.Committed, h.rig.journal.replay())
                assertEquals(files, h.files.bytesSnapshot())
                assertEquals(plan.nextState, h.states.snapshot.value)
                assertEquals(setOf("new.md", "Conflicts/Copy.md"), h.files.listFiles().map { it.relativePath }.toSet())
                assertEquals(v.device, PromptCodec.parseFile(h.files.read("Conflicts/Copy.md"), "Copy.md").frontMatter.id)
                assertTrue(h.retained().any { it.contentEquals(h.bytes("Losing dirty version")) })
            }
        }
    }

    @Test fun multiScopeRestoreCannotCommitUUIDOrRepushBaselineBeforeAllFilesDurable() {
        val h = ReconciliationHarness()
        val local = h.bytes("Preserved for repush")
        val shared = h.groupBytes("Shared equal", v.groupPrompt)
        val old = h.baseline(h.record(bytes = local, rev = 99), h.record(id = v.groupPrompt, bytes = shared, rev = 80, scope = v.groupScope))
        h.put(local)
        h.put(shared, "Groups/Team/a.md")
        h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10, rev = 2, body = "Restored old server"))),
            h.scope(v.groupScope, Mode.SNAPSHOT, items = listOf(h.upsert(20, id = v.groupPrompt, path = "new.md", rev = 3, bytes = shared))),
            database = ReconciliationHarness.restored).use { pull ->
            val plan = h.plan(pull)
            assertEquals(1, plan.restoreUpdates.size)
            val application = SyncReconciler.application(plan, h.mutations)
            h.rig.libraryOperations.onOperation = { call ->
                assertEquals(old, h.states.snapshot.value)
                if (call == "publish-file-flush:Groups/Team/new.md") h.rig.libraryOperations.failAt = h.rig.libraryOperations.calls.size
            }
            assertFailsWith<SyncFileOperationError> { h.rig.journal.apply(application) }
            assertEquals(old, h.states.snapshot.value)
            assertContentEquals(local, h.files.read("a.md"))
            assertNotNull(h.rig.journal.pending)
            h.rig.libraryOperations.onOperation = null
            h.rig.libraryOperations.failAt = null
            val restarted = h.rig.restart()
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            assertEquals(ReconciliationHarness.restored, restarted.states.snapshot.value?.databaseID)
            assertEquals(pull.cursors, restarted.states.snapshot.value?.cursors)
            assertContentEquals(local, h.files.read("a.md"))
            assertNull(h.files.stamp("Groups/Team/a.md"))
            assertContentEquals(shared, h.files.read("Groups/Team/new.md"))
        }
    }

    @Test fun racingStateAndRetiredPermitCannotCommitAnOldPlan() {
        for (retire in listOf(false, true)) {
            val h = ReconciliationHarness()
            val old = h.baseline()
            h.collected(h.scope(items = listOf(h.upsert(10)))).use { pull ->
                val plan = h.plan(pull)
                if (retire) {
                    val permit = SyncWorkPermit(h.rig.binding, 1)
                    permit.revoke()
                    assertFails { SyncReconciler.apply(plan, h.mutations, h.rig.journal, permit = permit) }
                    assertEquals(old, h.states.snapshot.value)
                } else {
                    val newer = old.copy(cursors = mapOf(v.userScope to "other committed cursor"))
                    h.states.update(h.rig.binding) { newer }
                    val application = SyncReconciler.application(plan, h.mutations)
                    assertEquals(SyncApplyOutcome.ReplanAsConflict(application.id), h.rig.journal.apply(application))
                    assertEquals(newer, h.states.snapshot.value)
                }
                assertTrue(h.files.listFiles().isEmpty())
                assertNull(h.rig.journal.pending)
            }
        }
    }
}
