package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.*

class SyncGroupRescueTest {
    @Test fun removalRescuesDirtyUnknownIdlessAndUnsupportedBytesBeforeCleanRetirement() {
        val (h, plan) = removalFixture()
        val copies = plan.edits.filter { it.kind == SyncLibraryEdit.Kind.RESCUE }
        assertEquals(7, copies.size)
        assertEquals(List(copies.size) { SyncLibraryEdit.Kind.RESCUE }, plan.edits.take(copies.size).map { it.kind })
        assertNull(plan.nextState.groups[h.group])
        assertNull(plan.nextState.cursors[h.scope])
        assertEquals("private cursor", plan.nextState.cursors[SyncTestValues.userScope])
        assertEquals(SyncTestValues.uuid, plan.nextState.databaseID)
        assertTrue(plan.nextState.favorites.isEmpty())
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertNull(h.rig.libraryOperations.directoryIdentity("Groups/Team"))
        for (copy in copies) {
            assertContentEquals(copy.bytes, h.files.read(copy.path))
            assertEquals(SyncFileMode.NORMAL, h.rig.libraryOperations.modes[copy.path])
            assertContentEquals(copy.retainedBytes, h.rig.local.state.read("sync/retained/${copy.id}.bin"))
            if (copy.heldIssue == null) {
                assertEquals(SyncPromptOrigin.Rescued, SyncConflictMetadata.origin(copy.bytes!!, "copy.md"))
                assertTrue(copy.copyID !in (30..32).map { folderID(it).rawValue })
            } else assertContentEquals(copy.retainedBytes, copy.bytes)
        }
        assertEquals(4, h.journal.heldRescues(h.binding.root).size)
        var scan = h.scan()
        scan.preparation?.let { assertEquals(SyncApplyOutcome.Committed, h.journal.apply(it)); scan = h.scan() }
        assertEquals(3, scan.changes.filterIsInstance<SyncLocalChange.Create>().size)
        assertTrue(scan.changes.none { it is SyncLocalChange.Delete })
        assertTrue(scan.orphanFiles.isEmpty())
    }

    @Test fun actualMovedGroupIdentityOutsideItsFolderIsPreservedBeforeScopeStateDrops() {
        val h = GroupFolderHarness()
        val bytes = h.bytes("offline move")
        h.put(bytes, "personal/moved.md")
        val owned = h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("old.md", bytes)))
        val plan = removed(h, owned)
        assertEquals("personal/moved.md", plan.edits.first().retainedSourcePath)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertNull(h.files.stamp("personal/moved.md"))
        assertNull(h.state().prompts[SyncTestValues.personalID])
        assertTrue(h.scan().changes.none { it is SyncLocalChange.Delete })
    }

    @Test fun finalAccessibleIDsRequireInstallationOutsideRemovedFoldersAndScopeBeforeCleanup() {
        val h = GroupFolderHarness()
        val bytes = h.bytes("shared")
        h.put(bytes, "Groups/Team/A.md")
        val owned = h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("A.md", bytes)))
        fun plan() = SyncGroupFolders.removed(setOf(h.scope), h.state(), owned, h.inventory(), setOf(SyncTestValues.personalID),
            h.date, folderIDs(), h.mutations)
        assertFailsWith<SyncGroupFolderError.AccessibleInstallationRequired> { plan() }
        h.files.move("Groups/Team/A.md", "Private.md")
        assertFailsWith<SyncGroupFolderError.AccessibleInstallationRequired> { plan() }
        val record = SyncPromptState(SyncTestValues.userScope, "Private.md", 2, SyncHash.of(bytes))
        h.rig.states.update(h.binding) { h.state().copy(prompts = mapOf(SyncTestValues.personalID to record)) }
        val cleanup = plan()
        assertTrue(cleanup.edits.isEmpty())
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(cleanup))
        assertContentEquals(bytes, h.files.read("Private.md"))
        assertEquals(record, h.state().prompts[SyncTestValues.personalID])
    }

    @Test fun duplicateHeldAndLocallyRenamedCleanBytesAreRescuedRatherThanClassifiedAsClean() {
        for (reason in listOf("duplicate", "held", "renamed")) {
            val h = GroupFolderHarness()
            val bytes = h.bytes()
            val path = if (reason == "renamed") "Groups/Team/New.md" else "Groups/Team/A.md"
            h.put(bytes, path)
            if (reason == "duplicate") h.put(bytes, "Groups/Team/B.md")
            val owned = h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("A.md", bytes)))
            val inventory = h.inventory(if (reason == "held") setOf(path) else emptySet())
            val plan = SyncGroupFolders.removed(setOf(h.scope), h.state(), owned, inventory, at = h.date, freshID = folderIDs(), mutations = h.mutations)
            assertEquals(if (reason == "duplicate") 2 else 1, plan.edits.count { it.kind == SyncLibraryEdit.Kind.RESCUE })
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            if (reason == "held") assertEquals(plan.edits.first().path, h.ownership().holds.single().path)
        }
    }

    @Test fun staleCleanupRescuesLooseRawStrayRootsAndEmptyFoldersButPreservesCanonicalAndCaseDriftedManagedTree() {
        val h = GroupFolderHarness()
        val known = h.bytes("managed")
        h.put(known, "Groups/Alpha/A.md")
        h.put(h.bytes("loose", folderID(30)), "Groups/loose.md")
        val raw = byteArrayOf(0, -1)
        h.put(raw, "Groups/Old/notes.bin")
        h.rig.libraryOperations.putDirectory("Groups/Empty")
        h.put("stray root".encodeToByteArray(), "GROUPS/Other/a.md")
        val owned = h.seed(groups = mapOf(h.group to SyncGroupState("Alpha", "alpha", Role.EDITOR)))
        val plan = stale(h, owned)
        assertEquals(3, plan.edits.count { it.kind == SyncLibraryEdit.Kind.RESCUE })
        assertTrue(plan.directories.none { it.source == "Groups" || it.source.startsWith("Groups/Alpha") })
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertContentEquals(known, h.files.read("Groups/Alpha/A.md"))
        assertNull(h.rig.libraryOperations.directoryIdentity("Groups/Empty"))
        assertNull(h.rig.libraryOperations.directoryIdentity("GROUPS"))
        val again = stale(h, h.ownership())
        assertTrue(again.edits.isEmpty())
        assertTrue(again.directories.isEmpty())
        assertNull(again.bindingChange)
    }

    @Test fun foreignManagedFoldersRescueToHoldsAndHashOnlyHoldsCannotBorrowAccountProvenance() {
        for (foreignFolder in listOf(false, true)) {
            val h = GroupFolderHarness()
            val bytes = "held idless".encodeToByteArray()
            h.put(bytes, "Groups/Old/moved.md")
            h.seed(groups = emptyMap())
            val origin = SyncTestValues.accountIdentity(userID = SyncTestValues.otherUser)
            val owned = h.ownership().copy(managedFolders = if (foreignFolder) mapOf(h.group to SyncManagedFolder(origin, "Old")) else emptyMap(),
                holds = if (foreignFolder) emptyList() else listOf(SyncHeldPrompt(PromptIdentity.at("old.md"), "old.md", origin, SyncHash.of(bytes))))
            h.rig.accounts.updateBinding(h.binding.root) { owned }
            val plan = stale(h, owned)
            val copy = plan.edits.first()
            val holds = plan.bindingChange!!.next.holds
            assertEquals(1, holds.size)
            assertEquals(copy.path, holds.single().path)
            assertEquals(if (foreignFolder) origin else h.binding.account, holds.single().sourceAccount)
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            assertEquals(holds, h.ownership().holds)
            assertTrue(h.scan().changes.isEmpty())
        }
    }

    @Test fun pathOrIdentityHoldProvenanceWinsAndOtherInstallationOfSameIdentitySurvives() {
        val h = GroupFolderHarness()
        val bytes = h.bytes("held", folderID(30))
        val path = "Groups/Old/f.md"
        h.put(bytes, path)
        val origin = SyncTestValues.accountIdentity(userID = SyncTestValues.otherUser)
        val identity = PromptIdentity.Assigned(folderID(30))
        val hash = SyncHash.of(bytes)
        val other = SyncHeldPrompt(identity, "other-installation.md", origin, hash)
        val owned = h.seed(groups = emptyMap(), holds = listOf(
            SyncHeldPrompt(PromptIdentity.Assigned(folderID(31)), "twin.md", h.binding.account, hash),
            SyncHeldPrompt(identity, path, origin, hash), other))
        val plan = stale(h, owned)
        val copy = plan.edits.first()
        val holds = plan.bindingChange!!.next.holds
        assertEquals(setOf(copy.path, other.path), holds.map { it.path }.toSet())
        assertEquals(origin, holds.single { it.path == copy.path }.sourceAccount)
        assertEquals(other, holds.single { it.path == other.path })
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertEquals(holds, GroupFolderHarness(h.rig.restart()).ownership().holds)
    }

    @Test fun accountChangeRescuesEveryGroupAndAssignsPrivateIdlessHoldsBeforeNewAccountScan() {
        val h = GroupFolderHarness()
        val shared = h.bytes("clean")
        h.put(shared, "Groups/Team/A.md")
        h.put("private idless\r\n".encodeToByteArray(), "personal.md")
        h.put(h.bytes("private", folderID(31)), "existing.md")
        h.put(byteArrayOf(-1), "forensic.md")
        h.put("opaque".encodeToByteArray(), "notes.txt")
        val source = PromptIdentity.at("personal.md")
        h.rig.local.values.record(source, mapOf("field" to "remembered"))
        h.rig.local.usage.recordUse(source)
        val owned = h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("A.md", shared)))
        val account = SyncTestValues.accountIdentity(userID = SyncTestValues.otherUser)
        val plan = SyncGroupFolders.accountChange(account, h.state(), owned, h.inventory(), h.date, folderIDs(), h.mutations)!!
        assertEquals(1, plan.edits.count { it.kind == SyncLibraryEdit.Kind.RESCUE })
        assertEquals(5, plan.bindingChange!!.next.holds.size)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        val heldID = PromptCodec.parseFile(h.files.read("personal.md"), "personal.md").frontMatter.id!!
        val identity = PromptIdentity.Assigned(heldID)
        assertEquals(mapOf("field" to "remembered"), h.rig.local.values.rememberedValues(identity))
        assertTrue(h.rig.local.values.rememberedValues(source).isEmpty())
        assertEquals(1, h.rig.local.usage.useEvents(identity).size)
        h.files.move("personal.md", "renamed.md")
        h.put(h.bytes("changed", heldID), "renamed.md")
        val restarted = GroupFolderHarness(h.rig.restart())
        assertEquals(account, restarted.ownership().owner)
        assertTrue(restarted.ownership().managedFolders.isEmpty())
        val scan = restarted.scan(state = null, account = account)
        assertTrue(scan.changes.isEmpty())
        assertTrue("renamed.md" in scan.snapshot.heldPaths)
        assertContentEquals(byteArrayOf(-1), restarted.files.read("forensic.md"))
        assertTrue(restarted.ownership().holds.all { it.sourceAccount == owned.owner })
    }

    @Test fun accountChangeUsesIndependentOwnershipAfterSignOutAndRescuesActualGroupIDOutsideFolder() {
        for (signedOut in listOf(false, true)) {
            val h = GroupFolderHarness()
            val path = if (signedOut) "Groups/Team/A.md" else "moved.md"
            val bytes = h.bytes("offline")
            h.put(bytes, path)
            val owned = if (signedOut) SyncLibraryBinding(h.binding.root, h.binding.account,
                mapOf(h.group to SyncManagedFolder(h.binding.account, "Team"))).also { retained -> h.rig.accounts.updateBinding(h.binding.root) { retained } }
                else h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("A.md", bytes)))
            val plan = SyncGroupFolders.accountChange(SyncTestValues.accountIdentity(userID = SyncTestValues.otherUser),
                if (signedOut) null else h.state(), owned, h.inventory(), h.date, folderIDs(), h.mutations)!!
            assertEquals(path, plan.edits.first().retainedSourcePath)
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            assertNull(h.files.stamp(path))
            assertEquals(1, h.ownership().holds.size)
        }
        val h = GroupFolderHarness()
        val owned = h.seed(groups = emptyMap())
        h.put("unsent".encodeToByteArray(), "a.md")
        h.rig.clearCalls()
        assertNull(SyncGroupFolders.accountChange(h.binding.account, h.state(), owned, h.inventory(), h.date, folderIDs(), h.mutations))
        assertTrue(h.rig.local.state.writes.isEmpty())
        assertEquals("unsent", h.files.text("a.md"))
    }

    @Test fun staleInternalRetirementResetsCursorAndSnapshotRestoresOriginalWithoutSharedDelete() {
        val h = GroupFolderHarness()
        val original = h.bytes("shared")
        val head = SyncLocalScanner.canonical(original, "A.md", h.scope).bytes
        h.put(original, "Groups/Unmapped/A.md")
        val owned = h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("A.md", original)))
        val plan = stale(h, owned)
        val copy = plan.edits.first()
        assertEquals(SyncState.snapshotResetCursor, plan.nextState.cursors[h.scope])
        assertNull(plan.nextState.prompts[SyncTestValues.personalID])
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertTrue(h.scan().changes.none { it is SyncLocalChange.Delete })
        val pullRig = ReconciliationHarness(h.rig)
        pullRig.collected(pullRig.scope(), pullRig.scope(h.scope, mode = Mode.DELTA)).use { pull ->
            assertFailsWith<SyncReconciliationError.SnapshotRequired> { SyncReconciler.plan(pull, h.state(), h.inventory().local) }
        }
        restore(h, head)
        assertContentEquals(head, h.files.read("Groups/Team/A.md"))
        assertContentEquals(copy.bytes, h.files.read(copy.path))
        assertEquals(1, h.state().prompts[SyncTestValues.personalID]!!.rev)
    }

    @Test fun occupantRescueRetiresAcknowledgementKeepsIdentityOverlayAndRestoreCannotInferDelete() {
        val h = GroupFolderHarness()
        val bytes = h.bytes("original")
        val head = SyncLocalScanner.canonical(bytes, "A.md", h.scope).bytes
        val file = h.put(bytes, "Groups/Team/A.md")
        val owned = h.seed(prompts = mapOf(SyncTestValues.personalID to h.record("A.md", bytes)), favorites = mapOf(SyncTestValues.personalID to true))
        val plan = SyncGroupFolders.rescueOccupant(file, h.state(), owned, h.inventory(), h.date, folderIDs(), h.mutations)
        assertEquals(0, plan.nextState.prompts[SyncTestValues.personalID]!!.rev)
        assertNull(plan.nextState.prompts[SyncTestValues.personalID]!!.canonicalHash)
        assertEquals(true, plan.nextState.favorites[SyncTestValues.personalID])
        assertEquals("A.md", plan.nextState.prompts[SyncTestValues.personalID]!!.path)
        assertEquals("0", plan.nextState.cursors[h.scope])
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertTrue(h.scan().changes.none { it is SyncLocalChange.Delete })
        restore(h, head)
        assertContentEquals(head, h.files.read(file.path))
        assertContentEquals(plan.edits.first().bytes, h.files.read(plan.edits.first().path))
        assertEquals(true, h.state().favorites[SyncTestValues.personalID])
        assertTrue(h.scan().changes.none { it is SyncLocalChange.Delete })
    }

    @Test fun lateUnknownFileAndRescueAncestorCollisionPreventStateCommitWithoutLosingAnyBytes() {
        val h = GroupFolderHarness()
        h.put("local".encodeToByteArray(), "Groups/Team/A.md")
        val owned = h.seed()
        val old = h.state()
        val plan = removed(h, owned)
        h.rig.libraryOperations.onOperation = { if (it == "remove-directory:Groups/Team") h.files.put("late bytes", "Groups/Team/late.bin") }
        assertIs<SyncApplyOutcome.ReplanAsConflict>(h.journal.apply(plan))
        assertEquals("late bytes", h.files.text("Groups/Team/late.bin"))
        assertEquals(old, h.state())
        assertNotNull(h.journal.pending)
        val blocked = GroupFolderHarness()
        blocked.put("local".encodeToByteArray(), "Groups/Team/A.md")
        blocked.put("root occupant".encodeToByteArray(), "Conflicts")
        val binding = blocked.seed()
        assertFailsWith<SyncGroupFolderError.RescueRequired> { removed(blocked, binding) }
        assertEquals("local", blocked.files.text("Groups/Team/A.md"))
        assertNull(blocked.rig.local.state.stamp("sync/apply.json"))
    }

    @Test fun maximumGroupWrapperRescuesToBoundedPrivatePathAndRenameChecksUnknownLongDescendants() {
        val h = GroupFolderHarness()
        val folder = "T".repeat(255)
        // Use exactly the wire limit, wrapped by a maximum group folder.
        val bounded = List(3) { "a".repeat(255) }.joinToString("/") + "/x/" + "b".repeat(251) + ".md"
        assertEquals(Limits.maxPathBytes, bounded.encodeToByteArray().size)
        val path = "Groups/$folder/$bounded"
        assertEquals(Limits.maxRootedPathBytes, path.encodeToByteArray().size)
        val bytes = h.bytes()
        h.put(bytes, path)
        val owned = h.seed(groups = mapOf(h.group to SyncGroupState("Long", folder, Role.EDITOR)),
            prompts = mapOf(SyncTestValues.personalID to h.record(bounded, h.bytes("before"))))
        val plan = removed(h, owned)
        val copy = plan.edits.first()
        assertTrue(copy.path.encodeToByteArray().size <= Limits.maxPathBytes)
        assertEquals(path, copy.retainedSourcePath)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertContentEquals(bytes, copy.retainedBytes)
        val long = GroupFolderHarness()
        long.put("unknown".encodeToByteArray(), "Groups/A/" + bounded.dropLast(3) + "b.md")
        val owner = long.seed(groups = mapOf(long.group to SyncGroupState("A", "A", Role.EDITOR)))
        assertFails { SyncGroupFolders.update(listOf(long.member(folder)), long.state(), owner, long.inventory(), long.mutations) }
        assertFalse(long.rig.libraryOperations.calls.any { it.startsWith("rename-directory:") })
    }

    @Test fun removedScopeRejectsPrivateScopeAndRepeatedFreshIdentityBeforeAnyPublication() {
        val h = GroupFolderHarness()
        h.put(h.bytes(), "Groups/Team/A.md")
        val owned = h.seed()
        assertFailsWith<SyncError.InvalidScope> {
            SyncGroupFolders.removed(setOf(SyncTestValues.userScope), h.state(), owned, h.inventory(), at = h.date, freshID = folderIDs(), mutations = h.mutations)
        }
        assertFailsWith<SyncError.InvalidState> {
            SyncGroupFolders.removed(setOf(h.scope), h.state(), owned, h.inventory(), at = h.date, freshID = { SyncTestValues.personal }, mutations = h.mutations)
        }
        assertNull(h.rig.local.state.stamp("sync/apply.json"))
    }

    @Test fun everyRemovalLibraryAndPrivatePersistenceFailureReplaysStableCopiesTwice() {
        val (baseline, plan) = removalFixture(small = true)
        baseline.rig.clearCalls()
        assertEquals(SyncApplyOutcome.Committed, baseline.journal.apply(plan))
        val counts = mapOf("library" to baseline.rig.libraryOperations.calls.size, "data" to baseline.rig.dataOperations.calls.size,
            "write" to baseline.rig.local.state.writes.size, "delete" to 1)
        for ((kind, count) in counts) for (cut in 1..count) {
            val (h, pending) = removalFixture(small = true)
            val before = h.state()
            h.rig.clearCalls()
            when (kind) {
                "library" -> h.rig.libraryOperations.failAt = cut
                "data" -> h.rig.dataOperations.failAt = cut
                else -> {
                    var writes = 0
                    h.rig.local.state.fault = { op, path ->
                        if (kind == "write" && op == MemoryStore.Operation.PRIVATE_WRITE && ++writes == cut ||
                            kind == "delete" && op == MemoryStore.Operation.DELETE && path == "sync/apply.json") StoreError.IOFailure else null
                    }
                }
            }
            assertFails("$kind $cut") { h.journal.apply(pending) }
            assertEquals(before, h.rig.states.snapshot.value, "$kind $cut")
            h.rig.libraryOperations.failAt = null
            h.rig.dataOperations.failAt = null
            h.rig.local.state.fault = null
            val restarted = GroupFolderHarness(h.rig.restart())
            if (restarted.journal.pending == null && restarted.rig.states.snapshot.value != pending.nextState) {
                assertEquals(SyncApplyOutcome.Committed, restarted.journal.apply(pending), "$kind $cut")
            } else assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay(), "$kind $cut")
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay(), "$kind $cut")
            val copies = pending.edits.filter { it.kind == SyncLibraryEdit.Kind.RESCUE }
            copies.forEach { assertContentEquals(it.bytes, restarted.files.read(it.path), "$kind $cut") }
            assertEquals(copies.size, restarted.files.listFiles().size, "$kind $cut")
            assertEquals(pending.nextState, restarted.state(), "$kind $cut")
            assertEquals(pending.bindingChange!!.next, restarted.ownership(), "$kind $cut")
        }
    }

    @Test fun accountOwnershipFlushFailureBlocksAccessAndHoldsAreRecoveredBeforeNewAccountScan() {
        val h = GroupFolderHarness()
        h.put(h.bytes(), "Groups/Team/A.md")
        h.put("private".encodeToByteArray(), "personal.md")
        val owned = h.seed()
        val account = SyncTestValues.accountIdentity(userID = SyncTestValues.otherUser)
        val plan = SyncGroupFolders.accountChange(account, h.state(), owned, h.inventory(), h.date, folderIDs(), h.mutations)!!
        h.rig.dataOperations.onOperation = { if (it == "file:sync/binding.json") h.rig.dataOperations.failAt = h.rig.dataOperations.calls.size }
        assertFailsWith<SyncError.DurabilityUncertain> { h.journal.apply(plan) }
        assertFailsWith<LibraryError.RecoveryRequired> { h.rig.local.library.entries() }
        h.rig.dataOperations.onOperation = null
        h.rig.dataOperations.failAt = null
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        val restarted = GroupFolderHarness(h.rig.restart())
        val scan = restarted.scan(state = null, account = account)
        assertTrue(scan.changes.isEmpty())
        assertEquals(2, scan.snapshot.heldPaths.size)
        assertEquals(account, restarted.ownership().owner)
    }

    private fun removed(h: GroupFolderHarness, owned: SyncLibraryBinding) = SyncGroupFolders.removed(setOf(h.scope), h.state(), owned,
        h.inventory(), at = h.date, freshID = folderIDs(), mutations = h.mutations)
    private fun stale(h: GroupFolderHarness, owned: SyncLibraryBinding) = SyncGroupFolders.stale(h.state(), owned, h.inventory(), h.date, folderIDs(), h.mutations)

    private fun removalFixture(small: Boolean = false): Pair<GroupFolderHarness, SyncApplyPlan> {
        val h = GroupFolderHarness()
        val clean = h.bytes("clean", folderID(30))
        val before = h.bytes("before", folderID(31))
        h.put(clean, "Groups/Team/clean.md")
        h.put(h.bytes("after", folderID(31)), "Groups/Team/dirty.md")
        h.put(byteArrayOf(-1, 0, 10), "Groups/Team/binary.md")
        if (!small) {
            h.put(h.bytes("unknown", folderID(32)), "Groups/Team/unknown.md")
            h.put("idless".encodeToByteArray(), "Groups/Team/idless.md")
            h.put("keep bytes".encodeToByteArray(), "Groups/Team/notes.txt")
            h.put("---\nformat: 999\n---\nFuture".encodeToByteArray(), "Groups/Team/future.md")
            h.put("---\na: [\n---\nBad".encodeToByteArray(), "Groups/Team/bad.md")
        }
        val owned = h.seed(groups = h.groups(Role.VIEWER), prompts = mapOf(PromptIdentity.Assigned(folderID(30)) to h.record("clean.md", clean),
            PromptIdentity.Assigned(folderID(31)) to h.record("dirty.md", before)), favorites = mapOf(PromptIdentity.Assigned(folderID(30)) to true))
        return h to removed(h, owned)
    }

    private fun restore(h: GroupFolderHarness, head: ByteArray) {
        val pullRig = ReconciliationHarness(h.rig)
        val item = FeedItem.Upsert(1, FeedPrompt(SyncTestValues.personal.rawValue, 1, "A.md", head.decodeToString()))
        pullRig.collected(pullRig.scope(), pullRig.scope(h.scope, mode = Mode.SNAPSHOT, items = listOf(item))).use { pull ->
            val reconciliation = SyncReconciler.plan(pull, h.state(), h.inventory().local)
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(SyncReconciler.application(reconciliation, h.mutations)))
        }
    }
}
