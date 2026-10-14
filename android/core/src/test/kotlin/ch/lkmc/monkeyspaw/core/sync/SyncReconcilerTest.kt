package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.UUID
import kotlin.test.*

class SyncReconcilerTest {
    private val v = SyncTestValues
    private val user = v.userScope
    private val team = v.groupScope

    @Test fun ownEchoAndOlderDeltaKeepDirtyContentAndAcknowledgedBaseline() {
        for (rev in listOf(2L, 7L)) {
            val h = ReconciliationHarness()
            val old = h.baseline(h.record(body = "Acknowledged", rev = 7))
            val local = h.put("Unsynced edit")
            h.collected(h.scope(items = listOf(h.upsert(10, rev = rev, body = "Echo")))).use { pull ->
                val plan = h.plan(pull)
                assertTrue(plan.operations.isEmpty())
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertContentEquals(local.bytes, h.files.read("a.md"))
                assertEquals(old.prompts, h.states.snapshot.value?.prompts)
                assertEquals(pull.cursors, h.states.snapshot.value?.cursors)
                assertTrue(h.files.writes.isEmpty())
            }
        }
    }

    @Test fun ownMoveEchoAndWrongScopeRemovalCannotDeleteNewOwner() {
        for (item in listOf(FeedItem.MoveOut(10, v.personal.rawValue), FeedItem.Delete(10, v.personal.rawValue))) {
            val h = ReconciliationHarness()
            val bytes = h.groupBytes("Moved")
            h.baseline(h.record(bytes = bytes, rev = 2, scope = team))
            h.put(bytes, "Groups/Team/a.md")
            h.collected(h.scope(items = listOf(item)), h.scope(team, items = listOf(h.upsert(11, rev = 2, bytes = bytes)))).use { pull ->
                val plan = h.plan(pull)
                assertTrue(plan.operations.isEmpty())
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertContentEquals(bytes, h.files.read("Groups/Team/a.md"))
                assertEquals(team, h.states.snapshot.value?.prompts?.get(v.personalID)?.scope)
                assertTrue(h.rig.libraryOperations.calls.none { it.startsWith("trash") })
            }
        }
    }

    @Test fun moveBackEchoFoldsBeforeRevisionShortcut() {
        val h = ReconciliationHarness()
        val bytes = h.groupBytes("Acknowledged final")
        h.baseline(h.record(bytes = bytes, rev = 4, scope = team))
        h.put(bytes, "Groups/Team/a.md")
        h.collected(h.scope(team, items = listOf(FeedItem.MoveOut(10, v.personal.rawValue), h.upsert(13, rev = 4, bytes = bytes))),
            h.scope(items = listOf(h.upsert(11, rev = 3, body = "Intermediate"), FeedItem.MoveOut(12, v.personal.rawValue)))).use { pull ->
            val plan = h.plan(pull)
            assertTrue(plan.operations.isEmpty())
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
            assertContentEquals(bytes, h.files.read("Groups/Team/a.md"))
        }
    }

    @Test fun multiScopeMoveChainsUseGlobalSequenceAndFinalPath() {
        val h = ReconciliationHarness()
        val original = h.bytes("Original")
        h.baseline(h.record(bytes = original))
        h.put(original)
        val final = h.groupBytes("Final")
        h.collected(h.scope(team, items = listOf(h.upsert(11, path = "in.md", rev = 2, bytes = h.groupBytes("In")),
            FeedItem.MoveOut(12, v.personal.rawValue), h.upsert(15, path = "final.md", rev = 4, bytes = final))),
            h.scope(items = listOf(FeedItem.MoveOut(10, v.personal.rawValue), h.upsert(13, path = "back.md", rev = 3),
                FeedItem.MoveOut(14, v.personal.rawValue)))).use { pull ->
            val application = SyncReconciler.application(h.plan(pull), h.mutations)
            assertEquals(listOf("Groups/Team/final.md", "a.md"), application.edits.map { it.path })
            assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
            assertEquals(listOf("Groups/Team/final.md"), h.files.listFiles().map { it.relativePath })
            assertContentEquals(final, h.files.read("Groups/Team/final.md"))
            assertEquals(4, h.states.snapshot.value?.prompts?.get(v.personalID)?.rev)
            assertTrue(h.retained().any { it.contentEquals(original) })
        }
    }

    @Test fun snapshotsAdoptEqualContentAtLowerRevisionsForNormalAndRestore() {
        for (database in listOf(v.uuid, ReconciliationHarness.restored)) {
            val h = ReconciliationHarness()
            val bytes = h.bytes("Equal")
            h.baseline(h.record(bytes = bytes, rev = 99))
            h.put(bytes)
            h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10, rev = 2, bytes = bytes))), database = database).use { pull ->
                val plan = h.plan(pull)
                assertTrue(plan.operations.isEmpty())
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertTrue(h.files.writes.isEmpty())
                assertEquals(2, h.states.snapshot.value?.prompts?.get(v.personalID)?.rev)
                assertEquals(database, h.states.snapshot.value?.databaseID)
            }
        }
    }

    @Test fun normalSnapshotWithLowerDifferentRevisionPreservesDirtyVersion() {
        val h = ReconciliationHarness()
        h.baseline(h.record(body = "Baseline", rev = 99))
        val local = h.put("Dirty")
        h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10, rev = 2, body = "Server")))).use { pull ->
            val plan = h.plan(pull)
            assertEquals(SyncReconciliationPreservation.Reason.DIRTY_UPSERT, h.preservation(plan).reason)
            assertContentEquals(local.bytes, h.preservation(plan).local.bytes)
            assertEquals(2, plan.nextState.prompts[v.personalID]?.rev)
            h.assertBlocked(plan)
        }
    }

    @Test fun normalSnapshotMissingCleanAndDirtyVersionsDiffer() {
        for (dirty in listOf(false, true)) {
            val h = ReconciliationHarness()
            h.baseline(h.record())
            h.put(if (dirty) "Dirty" else "Baseline")
            h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0)).use { pull ->
                val plan = h.plan(pull)
                assertNull(plan.nextState.prompts[v.personalID])
                if (dirty) {
                    assertEquals(SyncReconciliationPreservation.Reason.DIRTY_REMOVAL, h.preservation(plan).reason)
                    h.assertBlocked(plan)
                } else {
                    assertIs<SyncReconciliationOperation.Remove>(plan.operations.single())
                    assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                    assertNull(h.files.stamp("a.md"))
                }
            }
        }
    }

    @Test fun restoreMissingAlwaysPreservesEvenCleanVersions() {
        for (dirty in listOf(false, true)) {
            val h = ReconciliationHarness()
            h.baseline(h.record(rev = 99))
            h.put(if (dirty) "Dirty" else "Baseline")
            h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), database = ReconciliationHarness.restored).use { pull ->
                val plan = h.plan(pull)
                assertEquals(SyncReconciliationPlan.Mode.RESTORE, plan.mode)
                assertEquals(SyncReconciliationPreservation.Reason.RESTORE_MISSING, h.preservation(plan).reason)
                assertNull(plan.nextState.prompts[v.personalID])
                h.assertBlocked(plan)
            }
        }
    }

    @Test fun restoreWritableDifferenceQueuesRepushAfterAdoptingHead() {
        val h = ReconciliationHarness()
        val local = h.bytes("Local before restore")
        h.baseline(h.record(bytes = local, rev = 99))
        h.put(local)
        val server = h.bytes("Restored server")
        h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10, rev = 2, bytes = server))),
            database = ReconciliationHarness.restored).use { pull ->
            val plan = h.plan(pull)
            assertContentEquals(local, plan.restoreUpdates.single().local.bytes)
            assertEquals(2, plan.restoreUpdates.single().remote.rev)
            assertTrue(SyncReconciler.application(plan, h.mutations).edits.isEmpty())
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
            assertContentEquals(local, h.files.read("a.md"))
            assertEquals(SyncHash.of(server), h.states.snapshot.value?.prompts?.get(v.personalID)?.canonicalHash)
        }
    }

    @Test fun restoreViewerDifferenceRequiresPrivatePreservation() {
        val h = ReconciliationHarness()
        val local = h.groupBytes("Viewer version")
        h.baseline(h.record(bytes = local, rev = 99, scope = team), role = Role.VIEWER)
        h.put(local, "Groups/Team/a.md")
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), h.scope(team, Mode.SNAPSHOT, role = Role.VIEWER,
            items = listOf(h.upsert(10, rev = 2, bytes = h.groupBytes("Server")))), database = ReconciliationHarness.restored).use { pull ->
            val plan = h.plan(pull)
            assertTrue(plan.restoreUpdates.isEmpty())
            assertEquals(SyncReconciliationPreservation.Reason.RESTORE_VIEWER, h.preservation(plan).reason)
            assertEquals(SyncFileMode.READ_ONLY, h.preservation(plan).installation?.remote?.mode)
            h.assertBlocked(plan)
        }
    }

    @Test fun snapshotThenTailRetainsSnapshotPolicyAtLowerRevisions() {
        val h = ReconciliationHarness()
        h.baseline(h.record(rev = 99))
        h.put("Baseline")
        h.collectedPages(listOf(h.scope(mode = Mode.SNAPSHOT, head = 10, items = listOf(h.upsert(10, rev = 2, body = "Snapshot")))),
            listOf(h.scope(head = 11, items = listOf(h.upsert(11, rev = 3, body = "Tail"))))).use { pull ->
            val plan = h.plan(pull)
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
            assertEquals(3, h.states.snapshot.value?.prompts?.get(v.personalID)?.rev)
            assertContentEquals(h.bytes("Tail"), h.files.read("a.md"))
        }
    }

    @Test fun separatelyCapturedSnapshotsChooseLaterOwnerBeforeMissingDeletion() {
        for (sourcePresent in listOf(false, true)) {
            val h = ReconciliationHarness()
            val old = h.bytes("Before move")
            h.baseline(h.record(bytes = old, rev = 99))
            h.put(old)
            val moved = h.groupBytes("After move")
            h.collected(h.scope(team, Mode.SNAPSHOT, head = 20, items = listOf(h.upsert(20, rev = 2, bytes = moved))),
                h.scope(mode = Mode.SNAPSHOT, head = 10, items = if (sourcePresent) listOf(h.upsert(10, bytes = old)) else emptyList())).use { pull ->
                val plan = h.plan(pull)
                assertTrue(plan.operations.none { it is SyncReconciliationOperation.Preserve })
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertEquals(team, h.states.snapshot.value?.prompts?.get(v.personalID)?.scope)
                assertContentEquals(moved, h.files.read("Groups/Team/a.md"))
                assertNull(h.files.stamp("a.md"))
            }
        }
    }

    @Test fun remoteRenameFindsActualIDAndPreservesDirtyLocalRename() {
        val h = ReconciliationHarness()
        h.baseline(h.record(path = "old.md"))
        val changed = h.put("Locally moved", "elsewhere.md")
        val occupant = h.put("Replacement", "old.md", v.groupPrompt)
        h.collected(h.scope(items = listOf(h.upsert(10, path = "new.md", rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            assertEquals("elsewhere.md", h.preservation(plan).local.path)
            assertContentEquals(changed.bytes, h.preservation(plan).local.bytes)
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan, h.copy(plan)))
            assertContentEquals(occupant.bytes, h.files.read("old.md"))
            assertNull(h.files.stamp("elsewhere.md"))
        }
    }

    @Test fun removalPreservesLocallyMovedIDAndIgnoresReplacementAtRecordedPath() {
        val h = ReconciliationHarness()
        h.baseline(h.record(path = "old.md"))
        val changed = h.put("Moved dirty", "elsewhere.md")
        val unrelated = h.put("Occupant", "old.md", v.groupPrompt)
        h.collected(h.scope(items = listOf(FeedItem.Delete(10, v.personal.rawValue)))).use { pull ->
            val plan = h.plan(pull)
            assertEquals(SyncReconciliationPreservation.Reason.DIRTY_REMOVAL, h.preservation(plan).reason)
            assertContentEquals(changed.bytes, h.preservation(plan).local.bytes)
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan, h.copy(plan)))
            assertContentEquals(unrelated.bytes, h.files.read("old.md"))
            assertNull(h.files.stamp("elsewhere.md"))
        }
    }

    @Test fun missingActualIDNeverAuthorizesDeletingItsReplacement() {
        for (mode in Mode.entries) {
            val h = ReconciliationHarness()
            h.baseline(h.record())
            val unrelated = h.put("Unrelated", id = v.groupPrompt)
            h.collected(h.scope(mode = mode, items = if (mode == Mode.DELTA) listOf(FeedItem.Delete(10, v.personal.rawValue)) else emptyList())).use { pull ->
                val plan = h.plan(pull)
                assertTrue(plan.operations.isEmpty())
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertContentEquals(unrelated.bytes, h.files.read("a.md"))
                assertNull(h.states.snapshot.value?.prompts?.get(v.personalID))
            }
        }
    }

    @Test fun fullFoldAndMultipleOccupantsRequireRelocationWithoutMutation() {
        for (paths in listOf(listOf("Straße.md"), listOf("Straße.md", "strasse.md"))) {
            val h = ReconciliationHarness()
            h.baseline()
            paths.forEachIndexed { index, path -> h.put("Occupant $index", path, if (index == 0) v.groupPrompt else v.device) }
            h.collected(h.scope(items = listOf(h.upsert(10, path = "STRASSE.md")))).use { pull ->
                val plan = h.plan(pull)
                assertEquals(paths.toSet(), plan.operations.map { assertIs<SyncReconciliationOperation.PathClash>(it).occupant.path }.toSet())
                h.assertBlocked(plan)
            }
        }
    }

    @Test fun firstSyncDefersIDAndIdentityNeutralPathMatchesToAdoption() {
        for (id in listOf(v.personal, v.groupPrompt, null)) {
            val h = ReconciliationHarness()
            val bytes = if (id == null) "Copied library".encodeToByteArray() else h.bytes("Copied library", id)
            h.put(bytes)
            h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10, body = if (id == v.personal) "Different" else "Copied library")))).use { pull ->
                val plan = h.plan(pull)
                assertEquals(SyncReconciliationPlan.Mode.FIRST_SYNC, plan.mode)
                val adoption = assertIs<SyncReconciliationOperation.Adoption>(plan.operations.single())
                assertContentEquals(bytes, adoption.local.bytes)
                if (id != v.personal) assertTrue(CanonicalForm.equivalentForAdoption(bytes, adoption.remote.bytes, CanonicalForm.Scope.USER, "a.md"))
                h.assertBlocked(plan)
            }
        }
    }

    @Test fun heldFilesStayOutOfIDMatchingAndStillBlockDestinations() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        h.put("Held", "held.md")
        h.put("Baseline")
        h.collected(h.scope(items = listOf(h.upsert(10, path = "held.md", rev = 2)))).use { pull ->
            val plan = h.plan(pull, held = setOf("held.md"))
            assertEquals("held.md", assertIs<SyncReconciliationOperation.PathClash>(plan.operations.single()).occupant.path)
            h.assertBlocked(plan)
        }
    }

    @Test fun unavailableBindingMismatchDuplicateIDsAndInvalidBaselinesFailClosed() {
        val h = ReconciliationHarness()
        val old = h.baseline(h.record())
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0)).use { pull ->
            assertFailsWith<SyncReconciliationError.UnavailableLibrary> { SyncReconciler.plan(pull, old,
                SyncReconciliationSnapshot(h.rig.binding, emptyList(), SyncReconciliationSnapshot.Availability.UNAVAILABLE)) }
            assertFailsWith<SyncReconciliationError.BindingMismatch> { SyncReconciler.plan(pull, old,
                SyncReconciliationSnapshot(SyncTestValues.binding(root = "/other"), emptyList())) }
            h.put("A")
            h.put("B", "b.md")
            assertFailsWith<SyncReconciliationError.InvalidLocalSnapshot> { h.plan(pull) }
            val invalid = SyncLibraryFile("c.md", FileStamp("invalid"), h.bytes("C"), hash = v.hash)
            assertFailsWith<SyncReconciliationError.InvalidLocalSnapshot> { SyncReconciler.plan(pull, old,
                SyncReconciliationSnapshot(h.rig.binding, listOf(invalid))) }
            assertEquals(old, h.states.snapshot.value)
            assertNull(h.rig.journal.pending)
        }
    }

    @Test fun visibilityAndRemovedScopeCannotCommitUntilPolicyResolves() {
        val h = ReconciliationHarness()
        h.baseline(h.record(id = v.groupPrompt, scope = team))
        h.collected(h.scope(items = listOf(h.upsert(10, path = "_Hidden.md"))), h.scope(team)).use { pull ->
            val plan = h.plan(pull)
            assertIs<SyncReconciliationOperation.LocalVisibility>(plan.operations.single())
            h.assertBlocked(plan)
        }
        h.collected(h.scope(), removed = setOf(team)).use { pull ->
            val plan = h.plan(pull)
            assertIs<SyncReconciliationOperation.RemovedScope>(plan.operations.single())
            assertNull(plan.nextState.groups[v.group])
            assertNull(plan.nextState.prompts[v.groupID])
            h.assertBlocked(plan)
        }
    }

    @Test fun recheckedUnsafePathsAndSupersededContentCannotUseEchoShortcuts() {
        for (path in listOf("../bad.md", "a/../bad.md", "Groups/bad.md", "e\u0301.md")) {
            val h = ReconciliationHarness()
            val old = h.baseline(h.record(rev = 7))
            val local = h.put("Baseline")
            h.collected(h.scope(items = listOf(h.upsert(10, path = path, rev = 2), h.upsert(11, rev = 8)))).use { pull ->
                assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
                assertEquals(old, h.states.snapshot.value)
                assertContentEquals(local.bytes, h.files.read("a.md"))
                assertNull(h.rig.journal.pending)
            }
        }
        val h = ReconciliationHarness()
        h.baseline(h.record(rev = 7))
        for (content in listOf(h.bytes("Wrong ID", v.groupPrompt), "---\nformat: 999\n---\nFuture".encodeToByteArray(),
            "---\nfields: [\n---\nMalformed".encodeToByteArray())) {
            h.collected(h.scope(items = listOf(h.upsert(10, rev = 2, bytes = content), h.upsert(11, rev = 8)))).use { pull ->
                assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
                assertNull(h.rig.journal.pending)
            }
        }
    }

    @Test fun noncanonicalGroupContentIsRejectedBeforeAnyWrite() {
        val h = ReconciliationHarness()
        h.baseline()
        h.collected(h.scope(), h.scope(team, items = listOf(h.upsert(10, bytes = h.bytes("Not group canonical"))))).use { pull ->
            assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
            assertTrue(h.files.listFiles().isEmpty())
            assertNull(h.rig.journal.pending)
        }
    }

    @Test fun invalidMarkerEchoPreservesPreviousOriginAndRecordsFixedIssue() {
        val h = ReconciliationHarness()
        val bytes = "---\nid: '${v.personal.rawValue}'\nx-monkeyspaw-rescued: invalid\n---\nBody".encodeToByteArray()
        val old = h.baseline(v.personalID to SyncPromptState(user, "a.md", 7, SyncHash.of(bytes), SyncPromptOrigin.Rescued))
        val local = h.put("Unsynced")
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 7, bytes = bytes)))).use { pull ->
            val plan = h.plan(pull)
            assertTrue(plan.operations.isEmpty())
            val prompt = plan.nextState.prompts.getValue(v.personalID)
            assertEquals(SyncPromptOrigin.Rescued, prompt.origin)
            assertEquals(SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE), prompt.lastError?.code)
            assertEquals(old.prompts[v.personalID]?.canonicalHash, prompt.canonicalHash)
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
            assertContentEquals(local.bytes, h.files.read("a.md"))
        }
    }

    @Test fun validAndInvalidRemoteOriginsKeepExactBytesAndGroupOriginsStayPrivate() {
        for (scope in listOf(user, team)) for (invalid in listOf(false, true)) {
            val h = ReconciliationHarness()
            h.baseline()
            val source = "---\nid: '${v.personal.rawValue}'\nx-monkeyspaw-rescued: ${if (invalid) "invalid" else "true"}\n---\nBody".encodeToByteArray()
            val bytes = if (scope == team) CanonicalForm.group(source, "a.md").bytes else source
            val pages = listOf(h.scope(items = if (scope == user) listOf(h.upsert(10, bytes = bytes)) else emptyList())) +
                if (scope == team) listOf(h.scope(team, items = listOf(h.upsert(10, bytes = bytes)))) else emptyList()
            h.collected(*pages.toTypedArray()).use { pull ->
                val plan = h.plan(pull)
                val prompt = plan.nextState.prompts.getValue(v.personalID)
                assertEquals(if (scope == user && !invalid) SyncPromptOrigin.Rescued else null, prompt.origin)
                assertEquals(if (invalid) SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE) else null, prompt.lastError?.code)
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertContentEquals(bytes, h.files.read(if (scope == team) "Groups/Team/a.md" else "a.md"))
            }
        }
    }

    @Test fun groupFavoriteTrueFalseAndAbsentRespectPrivateOverlay() {
        for (favorite in listOf(true, false, null)) {
            val h = ReconciliationHarness()
            val canonical = h.groupBytes("Body")
            val old = h.baseline(h.record(bytes = canonical, scope = team))
            h.states.update(h.rig.binding) { old.copy(favorites = mapOf(v.personalID to true)) }
            val local = if (favorite == null) canonical else "---\nid: '${v.personal.rawValue}'\nfavorite: $favorite\n---\nBody".encodeToByteArray()
            h.put(local, "Groups/Team/a.md")
            h.collected(h.scope(), h.scope(team, items = listOf(h.upsert(10, rev = 2, bytes = canonical)))).use { pull ->
                val plan = h.plan(pull)
                assertEquals(if (favorite == false) null else true, plan.nextState.favorites[v.personalID])
                assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
                assertContentEquals(canonical, h.files.read("Groups/Team/a.md"))
            }
        }
    }

    @Test fun resetCursorRequiresSnapshotAndWrongUserOrIncompleteRestoreFailsClosed() {
        val h = ReconciliationHarness()
        val old = h.baseline()
        h.states.update(h.rig.binding) { old.copy(cursors = mapOf(user to SyncState.snapshotResetCursor)) }
        h.collected(h.scope()).use { pull ->
            assertEquals(user, assertFailsWith<SyncReconciliationError.SnapshotRequired> { h.plan(pull) }.scope)
        }
        h.collected(h.scope(), database = ReconciliationHarness.restored).use { pull ->
            assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
        }
        h.collected(SyncScope(ScopeIdentity.User(v.otherUser.rawValue), Mode.SNAPSHOT, 0, "done", false, emptyList())).use { pull ->
            assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
        }
    }

    @Test fun duplicateGlobalSequencesAndAmbiguousSnapshotOwnersAreRejected() {
        val h = ReconciliationHarness()
        h.baseline()
        h.collected(h.scope(items = listOf(h.upsert(10))), h.scope(team,
            items = listOf(h.upsert(10, id = v.groupPrompt, bytes = h.groupBytes("Other", v.groupPrompt))))).use { pull ->
            assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
        }
        h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10))),
            h.scope(team, Mode.SNAPSHOT, items = listOf(h.upsert(20, bytes = h.groupBytes("Same rev"))))).use { pull ->
            assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
        }
        h.collected(h.scope(mode = Mode.SNAPSHOT, items = listOf(h.upsert(10), h.upsert(10)))).use { pull ->
            assertFailsWith<SyncReconciliationError.InvalidPull> { h.plan(pull) }
        }
    }

    @Test fun fullWirePathAndGroupWrapperFitTheRootedCap() {
        val h = ReconciliationHarness()
        val segment = "a".repeat(255)
        val path = "$segment/$segment/$segment/x/${"a".repeat(251)}.md"
        assertEquals(1024, path.encodeToByteArray().size)
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), h.scope(team, Mode.SNAPSHOT,
            items = listOf(h.upsert(10, path = path, bytes = h.groupBytes("Body"))))).use { pull ->
            val plan = SyncReconciler.plan(pull, null, SyncReconciliationSnapshot(h.rig.binding, emptyList()), mapOf(v.group to segment))
            val remote = assertIs<SyncReconciliationOperation.Install>(plan.operations.single()).installation.remote
            assertEquals(1287, remote.libraryPath.encodeToByteArray().size)
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan))
            assertContentEquals(h.groupBytes("Body"), h.files.read(remote.libraryPath))
        }
    }

    @Test fun planningOwnsCollectionsAndBytesAndNeverMutatesDurableState() {
        val h = ReconciliationHarness()
        val old = h.baseline()
        val file = h.put("Local", "local.md", v.groupPrompt)
        val input = mutableListOf(file)
        val holds = mutableSetOf("held.md")
        val snapshot = SyncReconciliationSnapshot(h.rig.binding, input, heldPaths = holds)
        input.clear()
        holds.clear()
        h.collected(h.scope(items = listOf(h.upsert(10, body = "sensitive-sentinel")))).use { pull ->
            val filesBefore = h.files.bytesSnapshot()
            val stateBefore = h.rig.local.state.bytesSnapshot()
            val plan = SyncReconciler.plan(pull, old, snapshot)
            val remote = assertIs<SyncReconciliationOperation.Install>(plan.operations.single()).installation.remote
            remote.bytes.fill(0)
            assertContentEquals(h.bytes("sensitive-sentinel"), remote.bytes)
            assertEquals(setOf("local.md"), plan.occupiedPaths)
            assertEquals(setOf("held.md"), snapshot.heldPaths)
            assertFailsWith<UnsupportedOperationException> { (plan.operations as MutableList).clear() }
            assertFailsWith<UnsupportedOperationException> { (plan.occupiedPaths as MutableSet).clear() }
            assertFalse(listOf(plan, remote, plan.operations, snapshot).toString().contains("sensitive-sentinel"))
            assertEquals(filesBefore, h.files.bytesSnapshot())
            assertEquals(stateBefore, h.rig.local.state.bytesSnapshot())
            assertNull(h.rig.journal.pending)
        }
    }
}

internal class ReconciliationHarness(val rig: SyncJournalHarness = SyncJournalHarness(seed = false)) {
    private val v = SyncTestValues
    val files get() = rig.local.prompts
    val states get() = rig.states
    val mutations get() = rig.mutations

    fun bytes(body: String, id: ULID = v.personal): ByteArray = SyncJournalHarness.source(body, id.rawValue).encodeToByteArray()
    fun groupBytes(body: String, id: ULID = v.personal): ByteArray = CanonicalForm.group(bytes(body, id), "a.md").bytes
    fun put(body: String, path: String = "a.md", id: ULID = v.personal): SyncLibraryFile = put(bytes(body, id), path)
    fun put(bytes: ByteArray, path: String = "a.md"): SyncLibraryFile {
        files.put(bytes, path)
        return mutations.read(path)!!
    }
    fun record(id: ULID = v.personal, path: String = "a.md", body: String = "Baseline", bytes: ByteArray? = null,
               rev: Long = 1, scope: SyncScopeKey = v.userScope): Pair<PromptIdentity, SyncPromptState> =
        PromptIdentity.Assigned(id) to SyncPromptState(scope, path, rev, SyncHash.of(bytes ?: if (scope is SyncScopeKey.User)
            bytes(body, id) else groupBytes(body, id)))

    fun baseline(vararg records: Pair<PromptIdentity, SyncPromptState>, role: Role = Role.EDITOR): SyncState {
        val groups = if (records.any { it.second.scope == v.groupScope }) mapOf(v.group to SyncGroupState("Team", "Team", role)) else emptyMap()
        val cursors = mapOf(v.userScope to "old personal cursor") + if (groups.isEmpty()) emptyMap() else mapOf(v.groupScope to "old group cursor")
        val state = SyncState(rig.binding, v.uuid, cursors, groups, records.toMap())
        states.update(rig.binding) { state }
        return state
    }
    fun scope(key: SyncScopeKey = v.userScope, mode: Mode = Mode.DELTA, head: Long = 100,
              items: List<FeedItem> = emptyList(), role: Role = Role.EDITOR): SyncScope = SyncScope(
        if (key is SyncScopeKey.User) ScopeIdentity.User(key.id.rawValue) else ScopeIdentity.Group(key.id.rawValue, "Team", role),
        mode, head, "new ${key.rawValue}", false, items.map {
            if (mode == Mode.SNAPSHOT && it is FeedItem.Upsert) it.copy(seq = head) else it
        })
    fun upsert(seq: Long, id: ULID = v.personal, path: String = "a.md", rev: Long = 1, body: String = "Server", bytes: ByteArray? = null): FeedItem.Upsert =
        FeedItem.Upsert(seq, FeedPrompt(id.rawValue, rev, path, (bytes ?: bytes(body, id)).decodeToString(throwOnInvalidSequence = true)))

    fun collected(vararg scopes: SyncScope, database: UUID = v.uuid, removed: Set<SyncScopeKey> = emptySet()): SyncCollectedPull =
        collectedPages(scopes.toList(), database = database, removed = removed)

    fun collectedPages(vararg pages: List<SyncScope>, database: UUID = v.uuid, removed: Set<SyncScopeKey> = emptySet()): SyncCollectedPull {
        val staging = SyncPullStaging(MemoryStore())
        val scopes = linkedMapOf<SyncScopeKey, SyncCollectedScope>()
        for (page in pages) {
            staging.append(PullResponse(database.toString(), page, removed.map { it.rawValue }))
            for (scope in page) {
                val key = SyncScopeKey.parse(scope.identity.key)
                scopes[key] = SyncCollectedScope(scope.identity, scope.head, scope.cursor,
                    if (scope.mode == Mode.SNAPSHOT) scope.head else scopes[key]?.snapshotHead, 0)
            }
        }
        return SyncCollectedPull(database, scopes, removed, staging)
    }
    fun plan(pull: SyncCollectedPull, held: Set<String> = emptySet()): SyncReconciliationPlan {
        val local = mutations.listedFiles()
        rig.clearCalls()
        return SyncReconciler.plan(pull, states.load(rig.binding), SyncReconciliationSnapshot(rig.binding, local, heldPaths = held), mapOf(v.group to "Team"))
    }
    fun apply(plan: SyncReconciliationPlan, copies: Map<String, SyncReconciliationCopy> = emptyMap()): SyncApplyOutcome =
        SyncReconciler.apply(plan, mutations, rig.journal, copies)
    fun preservation(plan: SyncReconciliationPlan): SyncReconciliationPreservation =
        plan.operations.filterIsInstance<SyncReconciliationOperation.Preserve>().single().preservation
    fun copy(plan: SyncReconciliationPlan, path: String = "Conflicts/Copy.md", id: ULID = v.device): Map<String, SyncReconciliationCopy> {
        val preservation = preservation(plan)
        val origin = if (preservation.reason == SyncReconciliationPreservation.Reason.RESTORE_MISSING) SyncPromptOrigin.Rescued
            else runCatching { SyncMutationOrigin.origin(ch.lkmc.monkeyspaw.core.domain.format.PromptCodec.parseFile(preservation.local.bytes,
                LibraryPath.filename(preservation.local.path))) }.getOrNull() ?: SyncPromptOrigin.ConflictOf(preservation.id)
        return mapOf(preservation.local.path to SyncReconciliationCopy(mutations.rescue(preservation.local, path, id, origin), origin))
    }
    fun assertBlocked(plan: SyncReconciliationPlan, copies: Map<String, SyncReconciliationCopy> = emptyMap()) {
        val state = states.snapshot.value
        val filesBefore = files.bytesSnapshot()
        val dataBefore = rig.local.state.bytesSnapshot()
        assertFailsWith<SyncReconciliationError.RequiresPolicy> { apply(plan, copies) }
        assertEquals(state, states.snapshot.value)
        assertEquals(filesBefore, files.bytesSnapshot())
        assertEquals(dataBefore, rig.local.state.bytesSnapshot())
        assertNull(rig.journal.pending)
    }
    fun retained(): List<ByteArray> = rig.local.state.listFiles().filter {
        it.relativePath.startsWith("sync/retained/") && it.relativePath.endsWith(".bin")
    }.map { rig.local.state.read(it.relativePath) }

    companion object { val restored: UUID = UUID.fromString("22222222-2222-4222-8222-222222222222") }
}
