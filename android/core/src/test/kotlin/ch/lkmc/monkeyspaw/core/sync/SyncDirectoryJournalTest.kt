package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.*

class SyncDirectoryJournalTest {
    private val v = SyncTestValues

    @Test fun vanishedDirectoryWalksReplanApplyAndVerifyWithoutClaimingAReservation() {
        for (kind in SyncDirectoryEdit.Kind.entries) for (code in listOf(SyncFileFailureCode.NOT_FOUND, SyncFileFailureCode.CHANGED)) {
            val h = SyncJournalHarness()
            h.libraryOperations.putDirectory("Groups/Team")
            val edit = if (kind == SyncDirectoryEdit.Kind.RESERVE) SyncDirectoryEdit(kind, "Groups/New")
                else SyncDirectoryEdit(kind, "Groups/Team", h.libraryOperations.directoryIdentity("Groups/Team"),
                    if (kind == SyncDirectoryEdit.Kind.RENAME) "Groups/New" else null)
            h.libraryOperations.onOperation = { if (it == "directories:Groups") throw SyncFileOperationError(code) }
            assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, h.mutations.apply(edit))
            assertEquals(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, h.mutations.verify(edit))
            assertEquals(SyncApplyOutcome.ReplanAsConflict(edit.id), h.journal.apply(h.plan(directories = listOf(edit))))
            assertEquals(h.expected, h.states.snapshot.value)
            assertFalse(h.libraryOperations.calls.any { it.startsWith("rename-directory:") || it.startsWith("remove-directory:") })
            h.libraryOperations.onOperation = null
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        }
    }

    @Test fun incompleteDirectoryMigrationCannotReplanWhenTheSourceWalkVanishes() {
        val (h, plan) = renameFixture()
        val step = SyncDirectoryStep(plan.directories.single(), h.mutations.prepareMigrations(plan.directories.single()))
        h.libraryOperations.onOperation = { if (it == "directories:Groups") throw SyncFileOperationError(SyncFileFailureCode.NOT_FOUND) }
        assertFalse(h.mutations.canReplan(step))
        val error = SyncFileOperationError(SyncFileFailureCode.NOT_FOUND, SyncFileMutationEffect.APPLIED)
        h.libraryOperations.onOperation = { if (it == "directories:Groups") throw error }
        assertSame(error, assertFailsWith<SyncFileOperationError> { h.mutations.apply(step.edit) })
        assertSame(error, assertFailsWith<SyncFileOperationError> { h.mutations.verify(step.edit) })
    }

    @Test fun caseOnlyRenameReplaysFromTheIntermediateAndMigratesIdlessKeysExactlyOnce() {
        val (h, plan) = renameFixture(caseOnly = true)
        val edit = plan.directories.single()
        var interrupted = false
        h.libraryOperations.onOperation = { name ->
            if (name == "directory:Groups" && h.libraryOperations.directoryIdentity(edit.intermediate!!) == edit.identity) {
                interrupted = true
                h.libraryOperations.failAt = h.libraryOperations.calls.size
            }
        }
        assertFailsWith<SyncFileOperationError> { h.journal.apply(plan) }
        assertTrue(interrupted)
        assertEquals(h.expected, h.states.snapshot.value)
        assertFailsWith<LibraryError.RecoveryRequired> { h.journal.replan(h.plan()) }
        h.libraryOperations.onOperation = null
        h.libraryOperations.failAt = null
        val restarted = h.restart()
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        val writes = restarted.local.state.writes.size
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertEquals(writes, restarted.local.state.writes.size)
        assertRenamed(restarted, plan)
    }

    @Test fun everyDirectoryAndKeyedFlushAndPrivateWriteFailureRetainsAReplayablePlan() {
        val (baseline, plan) = renameFixture()
        assertEquals(SyncApplyOutcome.Committed, baseline.journal.apply(plan))
        for (kind in listOf("library", "data", "write", "delete")) {
            val count = when (kind) {
                "library" -> baseline.libraryOperations.calls.size
                "data" -> baseline.dataOperations.calls.size
                "write" -> baseline.local.state.writes.size
                else -> 1
            }
            for (cut in 1..count) {
                val (h, pending) = renameFixture()
                when (kind) {
                    "library" -> h.libraryOperations.failAt = cut
                    "data" -> h.dataOperations.failAt = cut
                    else -> {
                        var writes = 0
                        h.local.state.fault = { op, path ->
                            if (kind == "write" && op == MemoryStore.Operation.PRIVATE_WRITE && ++writes == cut ||
                                kind == "delete" && op == MemoryStore.Operation.DELETE && path == "sync/apply.json") StoreError.IOFailure else null
                        }
                    }
                }
                assertFails("kind=$kind cut=$cut") { h.journal.apply(pending) }
                assertEquals(h.expected, h.states.snapshot.value, "kind=$kind cut=$cut")
                h.libraryOperations.failAt = null
                h.dataOperations.failAt = null
                h.local.state.fault = null
                val restarted = h.restart()
                if (restarted.journal.pending == null && restarted.states.snapshot.value != pending.nextState) {
                    assertEquals(SyncApplyOutcome.Committed, restarted.journal.apply(pending), "kind=$kind cut=$cut")
                }
                else assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay(), "kind=$kind cut=$cut")
                assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
                assertRenamed(restarted, pending)
            }
        }
    }

    @Test fun renamedEmptyDirectoryRejectsAReplacementIncarnationAndOccupiedDestination() {
        for (replacement in listOf(false, true)) {
            val h = SyncJournalHarness()
            h.libraryOperations.putDirectory("Groups/Team")
            val identity = h.libraryOperations.directoryIdentity("Groups/Team")!!
            val edit = SyncDirectoryEdit(SyncDirectoryEdit.Kind.RENAME, "Groups/Team", identity, "Groups/New")
            val plan = h.plan(directories = listOf(edit))
            h.libraryOperations.onOperation = { name ->
                if (name == "directory:Groups") h.libraryOperations.failAt = h.libraryOperations.calls.size
            }
            assertFails { h.journal.apply(plan) }
            assertEquals(identity, h.libraryOperations.directoryIdentity("Groups/New"))
            h.libraryOperations.onOperation = null
            h.libraryOperations.failAt = null
            if (replacement) h.libraryOperations.putDirectory("Groups/New") else h.libraryOperations.putDirectory("Groups/Team")
            assertEquals(SyncApplyOutcome.ReplanAsConflict(edit.id), h.journal.replay())
            assertEquals(h.expected, h.states.snapshot.value)
            assertNotNull(h.journal.pending)
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
        }
    }

    @Test fun directoryRemovalRejectsLateUnknownFilesAndNeverPrunesAReplacementIncarnation() {
        for (lateFile in listOf(false, true)) {
            val h = SyncJournalHarness()
            h.libraryOperations.putDirectory("Groups/Team")
            val edit = SyncDirectoryEdit(SyncDirectoryEdit.Kind.REMOVE_EMPTY, "Groups/Team",
                h.libraryOperations.directoryIdentity("Groups/Team"))
            if (lateFile) h.libraryOperations.onOperation = { name ->
                if (name == "remove-directory:Groups/Team") h.local.prompts.put("unknown", "Groups/Team/late.bin")
            } else h.libraryOperations.putDirectory("Groups/Team")
            assertEquals(SyncApplyOutcome.ReplanAsConflict(edit.id), h.journal.apply(h.plan(directories = listOf(edit))))
            assertEquals(h.expected, h.states.snapshot.value)
            assertNotNull(h.libraryOperations.directoryIdentity("Groups/Team"))
            if (lateFile) assertEquals("unknown", h.local.prompts.text("Groups/Team/late.bin"))
            assertNotNull(h.journal.pending)
        }
    }

    @Test fun emptyDirectoryRemovalReflushesSurvivingParentsAfterAnUncertainUnlink() {
        val h = SyncJournalHarness()
        h.libraryOperations.putDirectory("Groups/Team")
        val edit = SyncDirectoryEdit(SyncDirectoryEdit.Kind.REMOVE_EMPTY, "Groups/Team",
            h.libraryOperations.directoryIdentity("Groups/Team"))
        val plan = h.plan(directories = listOf(edit))
        h.libraryOperations.onOperation = { name ->
            if (name == "directory:Groups") h.libraryOperations.failAt = h.libraryOperations.calls.size
        }
        assertFails { h.journal.apply(plan) }
        assertNull(h.libraryOperations.directoryIdentity("Groups/Team"))
        assertEquals(h.expected, h.states.snapshot.value)
        h.libraryOperations.onOperation = null
        h.libraryOperations.failAt = null
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertTrue(h.libraryOperations.calls.contains("directory:<root>"))
    }

    @Test fun reservationRechecksTheFullFoldedNamespaceAndSurvivesOwnedFilesAfterCommit() {
        val h = SyncJournalHarness()
        val edit = SyncDirectoryEdit(SyncDirectoryEdit.Kind.RESERVE, "Groups/New")
        val plan = h.plan(directories = listOf(edit))
        h.libraryOperations.putDirectory("Groups/NEW")
        assertEquals(SyncApplyOutcome.ReplanAsConflict(edit.id), h.journal.apply(plan))
        assertEquals(h.expected, h.states.snapshot.value)
        val fresh = SyncJournalHarness()
        val reserve = SyncDirectoryEdit(SyncDirectoryEdit.Kind.RESERVE, "Groups/New")
        val intended = fresh.plan(directories = listOf(reserve))
        var deleted = false
        fresh.local.state.onDelete = { if (it == "sync/apply.json") deleted = true }
        fresh.dataOperations.onOperation = { name -> if (deleted && name == "directory:sync") fresh.dataOperations.failAt = fresh.dataOperations.calls.size }
        assertFailsWith<SyncError.DurabilityUncertain> { fresh.journal.apply(intended) }
        fresh.local.prompts.put("new owned file", "Groups/New/arrived.bin")
        fresh.dataOperations.onOperation = null
        fresh.dataOperations.failAt = null
        assertEquals(SyncApplyOutcome.Committed, fresh.journal.replay())
        assertEquals("new owned file", fresh.local.prompts.text("Groups/New/arrived.bin"))
        assertEquals(intended.nextState, fresh.states.snapshot.value)
    }

    @Test fun everyOwnershipCommitFlushFailureRecoversOnTheSameGraphBeforeStateAcknowledgement() {
        for (flush in listOf("file:sync/binding.json", "directory:sync", "directory:<root>")) {
            val h = SyncJournalHarness()
            val change = SyncBindingChange(null, SyncLibraryBinding(h.binding.root, h.binding.account))
            val plan = h.plan(change = change)
            var committing = false
            h.local.state.onWrite = { if (it == "sync/binding.json") committing = true }
            h.dataOperations.onOperation = { name -> if (committing && name == flush) h.dataOperations.failAt = h.dataOperations.calls.size }
            assertFailsWith<SyncError.DurabilityUncertain> { h.journal.apply(plan) }
            assertEquals(h.expected, h.states.snapshot.value)
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
            h.dataOperations.onOperation = null
            h.dataOperations.failAt = null
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
            assertEquals(change.next, h.accounts.binding(h.binding.root))
            assertEquals(plan.nextState, h.states.snapshot.value)
        }
    }

    @Test fun renameChecksTheCompleteLongestJoinedPathBeforeAnyNativeRename() {
        val h = SyncJournalHarness()
        h.libraryOperations.putDirectory("Groups/A")
        val suffix = (1..4).joinToString("/") { "a".repeat(240) } + "/" + "b".repeat(239) + ".md"
        h.local.prompts.put("unknown", "Groups/A/$suffix")
        assertTrue("Groups/A/$suffix".encodeToByteArray().size <= Limits.maxRootedPathBytes)
        val edit = SyncDirectoryEdit(SyncDirectoryEdit.Kind.RENAME, "Groups/A",
            h.libraryOperations.directoryIdentity("Groups/A"), "Groups/" + "T".repeat(255))
        assertFailsWith<SyncError.WriteFailed> { h.journal.apply(h.plan(directories = listOf(edit))) }
        assertEquals("unknown", h.local.prompts.text("Groups/A/$suffix"))
        assertFalse(h.libraryOperations.calls.any { it.startsWith("rename-directory:") })
        assertEquals(h.expected, h.states.snapshot.value)
    }

    @Test fun directoryRecordsRejectAssignedKeysAndIncompleteCaseRenameIntents() {
        val h = SyncJournalHarness()
        h.libraryOperations.putDirectory("Groups/Team")
        val identity = h.libraryOperations.directoryIdentity("Groups/Team")!!
        val assigned = h.put(path = "Groups/Team/a.md")
        val invalid = listOf(
            SyncDirectoryEdit(SyncDirectoryEdit.Kind.RENAME, "Groups/Team", identity, "Groups/TEAM"),
            SyncDirectoryEdit(SyncDirectoryEdit.Kind.RENAME, "Groups/Team", identity, "Groups/Other", localFiles = listOf(assigned)),
            SyncDirectoryEdit(SyncDirectoryEdit.Kind.REMOVE_EMPTY, "Groups", identity),
            SyncDirectoryEdit(SyncDirectoryEdit.Kind.RESERVE, "Groups/_unknown"),
        )
        invalid.forEach {
            assertFailsWith<SyncError.InvalidState> { h.journal.apply(h.plan(directories = listOf(it))) }
            assertNull(h.mutations.pendingPermit)
            assertNull(h.local.state.stamp("sync/apply.json"))
        }
    }

    private fun renameFixture(caseOnly: Boolean = false): Pair<SyncJournalHarness, SyncApplyPlan> {
        val h = SyncJournalHarness()
        h.libraryOperations.putDirectory("Groups/Team")
        val local = h.put("idless", "Groups/Team/a.md", assigned = false)
        h.local.prompts.put("hidden raw", "Groups/Team/.hidden/opaque.bin")
        h.local.prompts.put(SyncJournalHarness.source("assigned"), "Groups/Team/assigned.md")
        h.local.values.record(local.identity, mapOf("field" to "remembered"))
        h.local.usage.recordUse(local.identity)
        h.local.history.snapshot("history".encodeToByteArray(), local.identity, h.local.clock.date)
        val edit = SyncDirectoryEdit(SyncDirectoryEdit.Kind.RENAME, "Groups/Team", h.libraryOperations.directoryIdentity("Groups/Team"),
            if (caseOnly) "Groups/TEAM" else "Groups/Renamed", if (caseOnly) "Groups/_sync-stable" else null, listOf(local))
        h.clearCalls()
        return h to h.plan(directories = listOf(edit))
    }

    private fun assertRenamed(h: SyncJournalHarness, plan: SyncApplyPlan) {
        val edit = plan.directories.single()
        assertNull(h.libraryOperations.directoryIdentity(edit.source))
        edit.intermediate?.let { assertNull(h.libraryOperations.directoryIdentity(it)) }
        assertEquals(edit.identity, h.libraryOperations.directoryIdentity(edit.destination!!))
        assertEquals("hidden raw", h.local.prompts.text("${edit.destination}/.hidden/opaque.bin"))
        assertEquals(v.personalID, h.local.library.load("${edit.destination}/assigned.md").identity)
        val new = PromptIdentity.at("${edit.destination}/a.md")
        val old = edit.localFiles.single().identity
        assertEquals(mapOf("field" to "remembered"), h.local.values.rememberedValues(new))
        assertTrue(h.local.values.rememberedValues(old).isEmpty())
        assertEquals(1, h.local.usage.useEvents(new).size)
        assertTrue(h.local.usage.useEvents(old).isEmpty())
        assertEquals(1, h.local.history.revisions(new).size)
        assertTrue(h.local.history.revisions(old).isEmpty())
        assertEquals(plan.nextState, h.states.snapshot.value)
        assertNull(h.local.state.stamp("sync/apply.json"))
    }
}
