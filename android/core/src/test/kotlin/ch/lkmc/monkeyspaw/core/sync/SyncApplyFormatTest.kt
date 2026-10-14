package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CancellationException
import kotlin.test.*

class SyncApplyFormatTest {
    private val v = SyncTestValues

    @Test fun immutablePlansAndSwiftVersionOneStorageShapesRoundTripExactBytesAndMigrations() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        val edits = plan.edits.toMutableList()
        val saved = SyncApplyPlan(plan.expectedState, plan.nextState, edits)
        edits.clear()
        assertEquals(1, saved.edits.size)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(saved))
        val old = plan.edits.single().expected!!
        val migration = SyncKeyedMigration(SyncKeyedStoreKind.HISTORY,
            SyncKeyedMigration.Change.File(SyncKeyedFileMove("history/${old.identityKey}/opaque.bin",
                "history/${v.personalID.storageKey}/opaque.bin", byteArrayOf(-1, 0, 13, 10))))
        val record = SyncApplyRecord(UUID.randomUUID(), plan.expectedState, plan.nextState,
            listOf(SyncApplyStep(plan.edits.single(), listOf(migration))))
        val objectValue = SyncApplyJson.codec.encode(record)
        val decoded = SyncApplyJson.codec.decode(WireJson.parse(syncDocumentBytes(objectValue)).objectValue())
        assertEquals(record.nextState, decoded.nextState)
        assertContentEquals(record.steps.single().edit.bytes, decoded.steps.single().edit.bytes)
        assertContentEquals(old.bytes, decoded.steps.single().edit.expected!!.bytes)
        val step = objectValue.required("steps").arrayValue().single().objectValue()
        val stamp = step.required("edit").objectValue().required("expected").objectValue().required("stamp").objectValue()
        assertEquals(old.stamp.journalToken(), stamp.text("token"))
        val move = step.required("migrations").arrayValue().single().objectValue().required("change").objectValue()
            .required("file").objectValue().required("_0").objectValue()
        assertEquals("/wANCg==", move.text("bytes"))
        assertEquals(move.text("bytes"), move.text("destinationBytes"))
        assertEquals("<sync apply plan>", plan.toString())
        assertEquals("<sync apply journal>", record.toString())
        assertEquals("<sync apply step>", record.steps.single().toString())
        decoded.steps.single().edit.bytes!!.fill(0)
        assertContentEquals(plan.edits.single().bytes, decoded.steps.single().edit.bytes)
    }

    @Test fun supportedUnknownFieldsSurviveProgressByStableStepAndMigrationIdentity() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        h.libraryOperations.failAt = 1
        assertFails { h.journal.apply(plan) }
        val intent = SyncTestValues.raw(h.local.state, "sync/apply.json")
        val first = intent.required("steps").arrayValue().single().objectValue()
        val migrations = first.required("migrations").arrayValue().map {
            it.objectValue().withText("x-migration", "kept")
        }
        val extended = intent.withText("x-root", "kept").setting("steps", WireValue.ArrayValue(listOf(
            first.withText("x-step", "kept").edit("edit") { it.withText("x-edit", "kept") }
                .setting("migrations", WireValue.ArrayValue(migrations)))))
        SyncTestValues.put(h.local.state, "sync/apply.json", extended)
        var final: SyncObject? = null
        h.local.state.onDelete = { if (it == "sync/apply.json") final = SyncTestValues.raw(h.local.state, it) }
        h.libraryOperations.failAt = null
        h.journal = h.replacementJournal()
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        val completed = final!!
        assertEquals("kept", completed.text("x-root"))
        val step = completed.required("steps").arrayValue().single().objectValue()
        assertEquals("kept", step.text("x-step"))
        assertEquals("kept", step.required("edit").objectValue().text("x-edit"))
        step.required("migrations").arrayValue().forEach { assertEquals("kept", it.objectValue().text("x-migration")) }
    }

    @Test fun fileOnlyLegacyJournalDefaultsDirectoryFieldsAndReplanWritesExplicitNullBaseline() {
        val h = SyncJournalHarness(seed = false)
        val edit = h.replacement()
        val plan = h.plan(listOf(edit), expectedState = null)
        h.libraryOperations.failAt = 1
        assertFails { h.journal.apply(plan) }
        val legacy = SyncObject(SyncTestValues.raw(h.local.state, "sync/apply.json").fields - setOf("directorySteps", "bindingChange"))
        SyncTestValues.put(h.local.state, "sync/apply.json", legacy)
        h.libraryOperations.failAt = null
        h.journal = h.replacementJournal()
        assertTrue(h.journal.pending!!.directorySteps.isEmpty())
        assertNull(h.journal.pending!!.bindingChange)
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        val second = SyncJournalHarness()
        val first = second.plan(listOf(second.replacement()))
        second.local.prompts.put(SyncJournalHarness.source("changed"), "a.md")
        assertTrue(second.journal.apply(first) is SyncApplyOutcome.ReplanAsConflict)
        second.states.clear()
        var replacement: SyncObject? = null
        second.local.state.onDelete = { if (it == "sync/apply.json") replacement = SyncTestValues.raw(second.local.state, it) }
        val next = second.plan(listOf(second.replacement(second.mutations.read("a.md")!!)), expectedState = null)
        assertEquals(SyncApplyOutcome.Committed, second.journal.replan(next))
        assertEquals(WireValue.Null, replacement!!.required("expectedState"))
    }

    @Test fun decodedMigrationsMustMatchTheRecordedIdentityAndValidateTheirActualPayloads() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        h.libraryOperations.failAt = 1
        assertFails { h.journal.apply(plan) }
        h.libraryOperations.failAt = null
        val original = SyncTestValues.raw(h.local.state, "sync/apply.json")
        val step = original.required("steps").arrayValue().single().objectValue()
        val usage = step.required("migrations").arrayValue().first { it.objectValue().text("store") == "usage" }.objectValue()
        val badBytes = "invalid usage".encodeToByteArray()
        val payload = usage.edit("change") { change -> change.edit("file") { file -> file.edit("_0") { move ->
            move.withText("bytes", Base64.getEncoder().encodeToString(badBytes)).withText("hash", SyncHash.of(badBytes).rawValue)
        } } }
        val wrongIdentity = usage.edit("change") { change -> change.edit("file") { file -> file.edit("_0") { move ->
            move.withText("destination", "usage/${v.groupID.storageKey}")
        } } }
        val valuesFile = usage.withText("store", "values")
        for (migration in listOf(payload, wrongIdentity, valuesFile)) {
            val modified = original.setting("steps", WireValue.ArrayValue(listOf(step.setting("migrations", WireValue.ArrayValue(listOf(migration))))))
            SyncTestValues.put(h.local.state, "sync/apply.json", modified)
            val accesses = h.local.prompts.accesses
            assertFailsWith<SyncError.CorruptFile> { h.replacementJournal() }
            assertEquals(accesses, h.local.prompts.accesses)
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
        }
    }

    @Test fun aggregateJournalCapFailsBeforePublicationAndReleasesUntouchedPreparation() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        val old = plan.edits.single().expected!!.identityKey
        h.local.state.put(ByteArray(Limits.syncRecordMaxBytes / 2) { 42 }, "history/$old/large.bin")
        val writes = h.local.state.writes.size
        assertFailsWith<SyncError.InvalidState> { h.journal.apply(plan) }
        assertEquals(writes, h.local.state.writes.size)
        assertTrue(h.local.prompts.writes.isEmpty())
        assertNull(h.local.state.stamp("sync/apply.json"))
        assertNull(h.mutations.pendingPermit)
        assertEquals(h.expected, h.states.snapshot.value)
    }

    @Test fun duplicateOperationAndExactDestinationIDsFailBeforeAnyMutation() {
        val h = SyncJournalHarness()
        val edit = h.replacement()
        val second = h.replacement(h.put(path = "b.md"))
        val sameID = SyncLibraryEdit(edit.id, second.kind, second.path, second.expected, second.bytes, second.hash,
            second.transition, second.mode, second.retainedBytes, second.retainedSourcePath)
        for (edits in listOf(listOf(edit, edit), listOf(edit, sameID))) {
            assertFailsWith<SyncError.InvalidState> { h.journal.apply(h.plan(edits)) }
            assertNull(h.local.state.stamp("sync/apply.json"))
            assertNull(h.mutations.pendingPermit)
            assertTrue(h.local.prompts.writes.isEmpty())
        }
    }

    @Test fun uncertainJournalReadFailuresRetainTheLatchAndRecoverOnlyAfterValidatedReflush() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        h.dataOperations.failAt = 1
        assertFailsWith<SyncError.DurabilityUncertain> { h.journal.apply(plan) }
        h.dataOperations.failAt = null
        h.local.state.fault = { operation, path -> if (operation == MemoryStore.Operation.READ && path == "sync/apply.json") StoreError.IOFailure else null }
        repeat(2) {
            assertEquals(SyncError.ReadFailed(StoreError.IOFailure), assertFailsWith<SyncError> { h.journal.replay() })
            assertEquals(plan.nextState, h.mutations.pendingPermit?.nextState)
            assertTrue(h.mutations.hasUnreadableJournal)
            assertEquals(h.expected, h.states.snapshot.value)
        }
        h.local.state.fault = null
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(plan.nextState, h.states.snapshot.value)
    }

    @Test fun workAdmissionRefusesWrongBindingsButCompletesAnAlreadyAdmittedDurableTransaction() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        val wrong = SyncWorkPermit(v.binding("/other"), 1)
        val accesses = h.local.prompts.accesses + h.local.state.accesses
        assertFailsWith<SyncError.BindingMismatch> { h.journal.apply(plan, wrong) }
        assertEquals(accesses, h.local.prompts.accesses + h.local.state.accesses)
        val permit = SyncWorkPermit(h.binding, 2)
        h.libraryOperations.beforePublish = { assertFalse(permit.revoke()); assertFalse(permit.isDrained) }
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan, permit))
        assertTrue(permit.isDrained)
        assertFailsWith<CancellationException> { h.journal.replay(permit) }
        assertEquals(plan.nextState, h.states.snapshot.value)
    }

    @Test fun stateRacesReturnAPlanConflictAndWrongAccountRecoveryNeverFlushesOrMutatesFiles() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        h.libraryOperations.afterPublish = {
            h.libraryOperations.afterPublish = null
            h.states.update(h.binding) { it.copy(cursors = mapOf(v.userScope to "external")) }
        }
        assertEquals(SyncApplyOutcome.ReplanAsConflict(plan.id), h.journal.apply(plan))
        assertEquals("external", h.states.snapshot.value!!.cursors[v.userScope])
        assertNotNull(h.journal.pending)
        val other = SyncState(v.binding(account = v.accountIdentity(userID = v.otherUser)))
        SyncTestValues.put(h.local.state, "sync/state.json", SyncStateJson.codec.encode(other))
        val unchanged = h.local.state.read("sync/state.json")
        h.clearCalls()
        assertFailsWith<SyncError.BindingMismatch> { h.journal.replay() }
        assertTrue(h.libraryOperations.calls.isEmpty())
        assertTrue(h.dataOperations.calls.isEmpty())
        assertContentEquals(unchanged, h.local.state.read("sync/state.json"))
    }
}
