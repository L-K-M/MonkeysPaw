package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

class SyncApplyJournalTest {
    private val v = SyncTestValues

    @Test fun durablePrivateIntentAndRetentionPrecedePublicationAndStatePrecedesDeletion() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        val events = mutableListOf<String>()
        h.local.state.onWrite = { events.add("write:$it") }
        h.local.state.onDelete = { events.add("delete:$it") }
        h.dataOperations.onOperation = { events.add("data:$it") }
        h.libraryOperations.onOperation = { events.add("library:$it") }
        var checked = 0
        h.libraryOperations.beforePublish = {
            checked++
            val record = SyncApplyJson.codec.decode(SyncTestValues.raw(h.local.state, "sync/apply.json"))
            assertTrue(h.local.state.isPrivate("sync/apply.json"))
            assertTrue(record.steps.first { it.edit.path == if (checked == 1) "Conflicts/Copy.md" else "a.md" }.started)
            assertEquals(plan.nextState, record.nextState)
            assertEquals(h.expected, h.states.snapshot.value)
            assertTrue(h.dataOperations.calls.contains("file:sync/apply.json"))
            assertTrue(h.dataOperations.calls.contains("directory:<root>"))
            plan.edits.take(checked).forEach { edit ->
                val path = "sync/retained/${edit.id}.bin"
                assertTrue(h.local.state.isPrivate(path))
                assertContentEquals(edit.retainedBytes, h.local.state.read(path))
                assertTrue(h.dataOperations.calls.contains("file:$path"))
            }
        }
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertEquals(2, checked)
        val publish = events.indexOfLast { it.startsWith("library:publish-root-flush") }
        val stateWrite = events.indexOf("write:sync/state.json")
        val stateFlush = events.indexOf("data:file:sync/state.json")
        val delete = events.indexOf("delete:sync/apply.json")
        assertTrue(publish < stateWrite && stateWrite < stateFlush && stateFlush < delete)
        assertEquals(listOf("data:directory:sync", "data:directory:<root>"), events.takeLast(2))
        assertCopies(h, plan)
    }

    @Test fun everyLibraryAndDataCapabilityFailureReplaysTwiceOnTheSameGraph() {
        val baseline = SyncJournalHarness()
        val initial = baseline.preparedCopy()
        assertEquals(SyncApplyOutcome.Committed, baseline.journal.apply(initial))
        assertTrue(baseline.dataOperations.calls.size > 30)
        for (data in listOf(false, true)) {
            val count = if (data) baseline.dataOperations.calls.size else baseline.libraryOperations.calls.size
            for (cut in 1..count) {
                val h = SyncJournalHarness()
                val plan = h.preparedCopy()
                val operations = if (data) h.dataOperations else h.libraryOperations
                operations.failAt = cut
                val error = assertFails { h.journal.apply(plan) }
                assertTrue(error is SyncError.DurabilityUncertain || error is SyncFileOperationError, "data=$data cut=$cut")
                assertEquals(h.expected, h.states.snapshot.value, "data=$data cut=$cut")
                assertNotNull(h.mutations.pendingPermit, "data=$data cut=$cut")
                assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.load("a.md") }
                operations.failAt = null
                assertEquals(SyncApplyOutcome.Committed, h.journal.replay(), "data=$data cut=$cut")
                val writes = h.local.prompts.writes.size
                assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
                assertEquals(writes, h.local.prompts.writes.size)
                assertCopies(h, plan)
            }
        }
    }

    @Test fun everyPrivateWriteAndDeletionFailureRecoversFromRecreatedStores() {
        val baseline = SyncJournalHarness()
        baseline.journal.apply(baseline.preparedCopy())
        for (cut in 1..baseline.local.state.writes.size) {
            val h = SyncJournalHarness()
            val plan = h.preparedCopy()
            var write = 0
            h.local.state.fault = { operation, _ ->
                if (operation == MemoryStore.Operation.PRIVATE_WRITE && ++write == cut) StoreError.IOFailure else null
            }
            assertFailsWith<SyncError.WriteFailed> { h.journal.apply(plan) }
            assertEquals(h.expected, h.states.snapshot.value)
            h.local.state.fault = null
            val restarted = h.restart()
            if (restarted.journal.pending == null) {
                assertNull(h.mutations.pendingPermit)
                assertContentEquals(plan.edits.last().expected!!.bytes, restarted.local.prompts.read("a.md"))
                assertEquals(SyncApplyOutcome.Committed, restarted.journal.apply(plan))
            } else assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            assertCopies(restarted, plan)
        }
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        h.local.state.fault = { operation, path -> if (operation == MemoryStore.Operation.DELETE && path == "sync/apply.json") StoreError.IOFailure else null }
        assertFailsWith<SyncError.WriteFailed> { h.journal.apply(plan) }
        assertEquals(h.expected, h.states.snapshot.value)
        assertEquals(SyncError.DurabilityUncertain, h.states.snapshot.error)
        assertNotNull(h.local.state.stamp("sync/apply.json"))
        h.local.state.fault = null
        val restarted = h.restart()
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertCopies(restarted, plan)
    }

    @Test fun interruptedIdentityMigrationReplaysEveryFlushAndPrivateWriteWithoutDuplicatingKeys() {
        val baseline = SyncJournalHarness()
        baseline.journal.apply(baseline.preparedAdoption())
        for (flush in listOf(true, false)) {
            val count = if (flush) baseline.dataOperations.calls.size else baseline.local.state.writes.size
            for (cut in 1..count) {
                val h = SyncJournalHarness()
                val plan = h.preparedAdoption()
                if (flush) h.dataOperations.failAt = cut
                else {
                    var writes = 0
                    h.local.state.fault = { operation, _ ->
                        if (operation == MemoryStore.Operation.PRIVATE_WRITE && ++writes == cut) StoreError.IOFailure else null
                    }
                }
                assertFails { h.journal.apply(plan) }
                assertEquals(h.expected, h.states.snapshot.value)
                h.dataOperations.failAt = null
                h.local.state.fault = null
                val restarted = h.restart()
                if (restarted.journal.pending == null) restarted.journal.apply(plan) else restarted.journal.replay()
                assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
                assertAdopted(restarted, plan)
            }
        }
    }

    @Test fun liveJournalReplacementRetainsIntendedStateThroughEveryFinalDeletionFlush() {
        for (suffix in listOf("directory:sync", "directory:<root>")) {
            val h = SyncJournalHarness()
            val plan = h.preparedCopy()
            h.dataOperations.onOperation = { name ->
                if (h.local.state.stamp("sync/apply.json") == null && name == suffix) h.dataOperations.failAt = h.dataOperations.calls.size
            }
            assertFailsWith<SyncError.DurabilityUncertain> { h.journal.apply(plan) }
            assertEquals(h.expected, h.states.snapshot.value)
            assertEquals(plan.nextState, h.mutations.pendingPermit?.nextState)
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.values.removeAll() }
            h.dataOperations.onOperation = null
            h.dataOperations.failAt = null
            h.journal = h.replacementJournal()
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
            assertCopies(h, plan)
        }
    }

    @Test fun missingUncommittedIntentKeepsOwnerAndGateUntilTheExactIntentIsRestored() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        h.libraryOperations.failAt = 1
        assertFailsWith<SyncFileOperationError> { h.journal.apply(plan) }
        val intent = h.local.state.read("sync/apply.json")
        h.local.state.delete("sync/apply.json")
        h.libraryOperations.failAt = null
        assertFailsWith<LibraryError.RecoveryRequired> { h.replacementJournal() }
        assertEquals(plan.id, h.mutations.pendingPermit?.id)
        assertTrue(h.mutations.hasUnreadableJournal)
        assertFailsWith<LibraryError.RecoveryRequired> { h.mutations.begin(plan.id, plan.nextState) }
        h.mutations.finish(plan.id)
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
        h.local.state.put(intent, "sync/apply.json")
        h.journal = h.replacementJournal()
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertCopies(h, plan)
    }

    @Test fun failedStateReflushOnLiveReplayCannotReleaseTheRecoveryGate() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        h.dataOperations.onOperation = { name ->
            if (h.local.state.stamp("sync/apply.json") == null && name == "directory:sync") {
                h.dataOperations.failAt = h.dataOperations.calls.size
            }
        }
        assertFailsWith<SyncError.DurabilityUncertain> { h.journal.apply(plan) }
        assertNull(h.local.state.stamp("sync/apply.json"))
        h.dataOperations.failAt = null
        h.dataOperations.onOperation = { name ->
            if (name == "file:sync/state.json") h.dataOperations.failAt = h.dataOperations.calls.size
        }

        assertFailsWith<SyncError.DurabilityUncertain> { h.journal.replay() }
        assertFailsWith<LibraryError.RecoveryRequired> { h.mutations.begin(plan.id, plan.nextState) }
        h.mutations.finish(plan.id)
        assertEquals(plan.id, h.mutations.pendingPermit?.id)
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.values.removeAll() }

        h.dataOperations.onOperation = null
        h.dataOperations.failAt = null
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertCopies(h, plan)
        h.local.library.entries()
    }

    @Test fun bindingMismatchBlocksUncertainStateRecoveryBeforeAcknowledgement() {
        for (flush in listOf("file:sync/state.json", "directory:sync", "directory:<root>")) {
            val h = SyncJournalHarness()
            val owned = SyncLibraryBinding(h.binding.root, h.binding.account)
            val plan = h.plan(listOf(h.replacement()), change = SyncBindingChange(null, owned))
            var writingState = false
            h.local.state.onWrite = { if (it == "sync/state.json") writingState = true }
            h.dataOperations.onOperation = { name ->
                if (writingState && name == flush) h.dataOperations.failAt = h.dataOperations.calls.size
            }
            assertFailsWith<SyncError.DurabilityUncertain>(flush) { h.journal.apply(plan) }
            assertEquals(plan.expectedState, h.states.snapshot.value, flush)
            assertEquals(SyncError.DurabilityUncertain, h.states.snapshot.error, flush)
            assertEquals(owned, h.accounts.binding(owned.root), flush)
            h.local.state.onWrite = null
            h.dataOperations.onOperation = null
            h.dataOperations.failAt = null

            // Ownership may change on disk while the state publication awaits recovery.
            val bindingBytes = h.local.state.read("sync/binding.json")
            val unexpected = SyncLibraryBinding(owned.root, v.accountIdentity(userID = v.otherUser))
            v.put(h.local.state, "sync/binding.json", syncObject("version" to wireLong(Limits.syncBindingVersion.toLong()),
                "libraries" to WireValue.ArrayValue(listOf(SyncAccountJson.binding(unexpected)))))
            val journalBytes = h.local.state.read("sync/apply.json")
            val stateBytes = h.local.state.read("sync/state.json")
            val operations = h.dataOperations.calls.size
            assertFailsWith<LibraryError.RecoveryRequired>(flush) { h.journal.replay() }
            assertEquals(operations, h.dataOperations.calls.size, flush)
            assertEquals(plan.expectedState, h.states.snapshot.value, flush)
            assertEquals(SyncError.DurabilityUncertain, h.states.snapshot.error, flush)
            assertContentEquals(stateBytes, h.local.state.read("sync/state.json"), flush)
            assertContentEquals(journalBytes, h.local.state.read("sync/apply.json"), flush)
            assertEquals(plan.id, h.journal.pending?.id, flush)
            assertFailsWith<LibraryError.RecoveryRequired>(flush) { h.local.library.entries() }

            h.local.state.writePrivate(bindingBytes, "sync/binding.json")
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay(), flush)
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay(), flush)
            assertEquals(plan.nextState, h.states.snapshot.value, flush)
            assertNull(h.states.snapshot.error, flush)
            assertNull(h.journal.pending, flush)
            h.local.library.entries()
        }
    }

    @Test fun missingPreparationIntentCannotInferCommitFromAnUnchangedState() {
        val h = SyncJournalHarness()
        val edit = h.replacement()
        val plan = h.plan(listOf(edit), next = h.expected)
        h.libraryOperations.failAt = 1
        assertFailsWith<SyncFileOperationError> { h.journal.apply(plan) }
        h.libraryOperations.failAt = null
        h.local.state.delete("sync/apply.json")
        assertEquals(h.expected, h.states.snapshot.value)
        assertFailsWith<LibraryError.RecoveryRequired> { h.replacementJournal() }
        assertEquals(plan.id, h.mutations.pendingPermit?.id)
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
    }

    @Test fun corruptFutureAndTamperedIntentNeverTouchesTheLibraryOrReleasesAnExistingOwner() {
        val h = SyncJournalHarness()
        val plan = h.preparedCopy()
        h.libraryOperations.failAt = 1
        assertFails { h.journal.apply(plan) }
        h.libraryOperations.failAt = null
        val original = h.local.state.read("sync/apply.json")
        val objectValue = WireJson.parse(original).objectValue()
        fun changedStep(change: (SyncObject) -> SyncObject): ByteArray {
            val steps = objectValue.required("steps").arrayValue()
            return WireJson.canonical(objectValue.setting("steps", WireValue.ArrayValue(listOf(change(steps[0].objectValue())) + steps.drop(1))))
        }
        val variants = listOf(
            "broken".encodeToByteArray() to SyncError.CorruptFile,
            "{\"version\":99}".encodeToByteArray() to SyncError.FutureVersion(99),
            changedStep { SyncObject(it.fields - "started") } to SyncError.CorruptFile,
            changedStep { SyncObject(it.fields - "completed") } to SyncError.CorruptFile,
            changedStep { it.setting("completed", wireBoolean(true)).setting("started", wireBoolean(false)) } to SyncError.CorruptFile,
            changedStep { it.edit("edit") { edit -> edit.withText("hash", "0".repeat(64)) } } to SyncError.CorruptFile,
            changedStep { it.edit("edit") { edit -> edit.withText("bytes", "??") } } to SyncError.CorruptFile,
            changedStep { it.edit("edit") { edit -> edit.withText("path", "../outside.md") } } to SyncError.CorruptFile,
        )
        for ((bytes, expected) in variants) {
            h.local.state.put(bytes, "sync/apply.json")
            val accesses = h.local.prompts.accesses
            assertEquals(expected, assertFailsWith<SyncError> { h.replacementJournal() })
            assertEquals(accesses, h.local.prompts.accesses)
            assertContentEquals(bytes, h.local.state.read("sync/apply.json"))
            assertEquals(plan.nextState, h.mutations.pendingPermit?.nextState)
            assertFailsWith<LibraryError.RecoveryRequired> { h.mutations.replacePermit(plan.id, UUID.randomUUID(), plan.nextState) }
            h.mutations.finish(plan.id)
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.load("a.md") }
        }
        h.local.state.put(original, "sync/apply.json")
        h.journal = h.replacementJournal()
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertCopies(h, plan)
    }

    @Test fun corruptOwnerlessJournalResetMustBeDurableBeforeOrdinaryAccessResumes() {
        val h = SyncJournalHarness()
        h.local.state.put("broken", "sync/apply.json")
        assertFailsWith<SyncError.CorruptFile> { h.replacementJournal() }
        h.local.state.delete("sync/apply.json")
        h.dataOperations.calls.clear()
        h.dataOperations.failAt = 1
        assertFailsWith<SyncFileOperationError> { h.replacementJournal() }
        assertTrue(h.mutations.hasUnreadableJournal)
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
        h.dataOperations.failAt = null
        h.journal = h.replacementJournal()
        assertFalse(h.mutations.hasUnreadableJournal)
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        h.local.values.removeAll()
    }

    @Test fun initialWriteAndPreparationFailureReleaseTheOwnerWithoutLosingTypedKeyedConflict() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        h.local.state.put("occupied", "history/${v.personal.rawValue}")
        assertFailsWith<LibraryError.KeyedStateConflict> { h.journal.apply(plan) }
        assertNull(h.mutations.pendingPermit)
        assertNull(h.local.state.stamp("sync/apply.json"))
        assertTrue(h.local.prompts.writes.isEmpty())
        h.local.state.delete("history/${v.personal.rawValue}")
        h.local.state.fault = { op, path -> if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/apply.json") StoreError.IOFailure else null }
        assertFailsWith<SyncError.WriteFailed> { h.journal.apply(plan) }
        assertNull(h.mutations.pendingPermit)
        h.local.state.fault = null
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertAdopted(h, plan)
    }

    @Test fun externalKeyedConflictPreservesIntentAndRefusesDiscardingPublishedIdentity() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        val old = PromptIdentity.at("a.md")
        h.libraryOperations.afterPublish = {
            h.libraryOperations.afterPublish = null
            h.local.state.put("external", "history/${old.storageKey}/nested/opaque.bin")
        }
        assertEquals(SyncApplyOutcome.RecoveryRequired(plan.id), h.journal.apply(plan))
        val intent = h.local.state.read("sync/apply.json")
        assertEquals(h.expected, h.states.snapshot.value)
        assertFailsWith<LibraryError.RecoveryRequired> { h.journal.replan(h.plan()) }
        assertContentEquals(intent, h.local.state.read("sync/apply.json"))
        assertEquals("external", h.local.state.text("history/${old.storageKey}/nested/opaque.bin"))
        assertFailsWith<LibraryError.RecoveryRequired> { h.local.usage.recordUse(old) }
        h.local.state.put("unknown", "history/${old.storageKey}/nested/opaque.bin")
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertAdopted(h, plan)
    }

    @Test fun cooperatingWritesAreGatedAndPrivateIODoesNotHoldTheLibraryLock() {
        val h = SyncJournalHarness()
        val plan = h.preparedAdoption()
        val old = PromptIdentity.at("a.md")
        h.libraryOperations.beforePublish = {
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.values.record(old, mapOf("field" to "new")) }
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.values.removeAll() }
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.usage.recordUse(old) }
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.history.snapshot(byteArrayOf(1), old, h.local.clock.date) }
        }
        val worker = Executors.newSingleThreadExecutor()
        val checked = mutableSetOf<String>()
        try {
            h.dataOperations.onOperation = { name ->
                if (name.startsWith("file:") && checked.add(name)) {
                    worker.submit {
                        assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.load("a.md") }
                    }.get(5, TimeUnit.SECONDS)
                }
            }
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        } finally { worker.shutdownNow() }
        assertTrue("file:sync/apply.json" in checked && "file:values.json" in checked && "file:sync/state.json" in checked)
        assertTrue(checked.any { it.startsWith("file:history/") })
        h.local.values.record(v.personalID, mapOf("field" to "later"))
    }

    @Test fun permanentRawRetentionAndBoundHoldMetadataSurviveCommitAndRestart() {
        val h = SyncJournalHarness()
        val raw = byteArrayOf(-1, 0, 13, 10)
        h.local.prompts.put(raw, "Groups/Team/raw.md")
        val file = h.mutations.read("Groups/Team/raw.md")!!
        val copy = h.mutations.rescue(file, "Conflicts/rescued/raw.md", v.groupPrompt)
        val plan = h.plan(listOf(copy, h.mutations.trash(file)))
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        val restarted = h.restart()
        val held = restarted.journal.heldRescues(h.binding.root).single()
        assertEquals(copy.id, held.operationID)
        assertEquals(copy.path, held.path)
        assertEquals(file.path, held.sourcePath)
        assertEquals(h.binding, held.binding)
        assertEquals(SyncIssueCode.Content(PromptIssueCode.INVALID_UTF8), held.issue)
        assertEquals(SyncPromptOrigin.Rescued, held.origin)
        assertContentEquals(raw, restarted.local.prompts.read(copy.path))
        assertContentEquals(raw, restarted.local.state.read("sync/retained/${copy.id}.bin"))
        assertTrue(restarted.journal.heldRescues(SyncLibraryRoot("/other")).isEmpty())
        restarted.local.state.put(byteArrayOf(1), "sync/retained/${copy.id}.bin")
        assertFailsWith<SyncError.InvalidState> { restarted.journal.heldRescues(h.binding.root) }
    }

    @Test fun replayUpgradesLegacyRetentionWithoutDroppingUnknownFieldsAndClearedLegacyHoldsFailClosed() {
        val h = SyncJournalHarness()
        h.local.prompts.put(byteArrayOf(-1), "raw.md")
        val file = h.mutations.read("raw.md")!!
        val copy = h.mutations.rescue(file, "Conflicts/raw.md", v.groupPrompt)
        val plan = h.plan(listOf(copy))
        h.libraryOperations.failAt = 1
        assertFails { h.journal.apply(plan) }
        val path = "sync/retained/${copy.id}.json"
        val metadata = SyncTestValues.raw(h.local.state, path)
        val legacy = SyncObject(metadata.fields - setOf("serverURL", "userID", "libraryRoot", "destinationPath", "origin") +
            ("x-extension" to wireString("kept")))
        SyncTestValues.put(h.local.state, path, legacy)
        assertFailsWith<SyncError.InvalidState> { h.journal.heldRescues(h.binding.root) }
        h.libraryOperations.failAt = null
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(copy.path, h.journal.heldRescues(h.binding.root).single().path)
        assertEquals("kept", SyncTestValues.raw(h.local.state, path).text("x-extension"))
    }

    @Test fun additionalDisplacedBytesAndPermanentRetentionConflictPreserveEffectAndEvidence() {
        for (publicationFailure in listOf(false, true)) for (retentionConflict in listOf(false, true)) {
            val h = SyncJournalHarness()
            val edit = h.replacement()
            val plan = h.plan(listOf(edit))
            val losing = SyncJournalHarness.source("last instant").encodeToByteArray()
            val path = "sync/retained/${edit.id}-displaced.bin"
            h.libraryOperations.afterCheck = { h.local.prompts.put(losing, "a.md") }
            if (publicationFailure) h.libraryOperations.onOperation = { name ->
                if (name == "publish-file-flush:a.md") h.libraryOperations.failAt = h.libraryOperations.calls.size
            }
            if (retentionConflict) h.local.state.put("preexisting", path)
            else h.local.state.fault = { op, p -> if (op == MemoryStore.Operation.PRIVATE_WRITE && p == path) StoreError.IOFailure else null }
            val error = assertFailsWith<SyncFileOperationError> { h.journal.apply(plan) }
            assertEquals(SyncFileMutationEffect.APPLIED, error.effect)
            assertContentEquals(losing, error.displacedBytes)
            assertEquals(if (retentionConflict) SyncFileFailureCode.INVALID_STATE else if (publicationFailure)
                SyncFileFailureCode.DURABILITY_FAILED else SyncFileFailureCode.IO_FAILURE, error.code)
            assertEquals(h.expected, h.states.snapshot.value)
            assertNotNull(h.journal.pending)
            assertContentEquals(edit.retainedBytes, h.local.state.read("sync/retained/${edit.id}.bin"))
            if (retentionConflict) assertEquals("preexisting", h.local.state.text(path))
            assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.entries() }
        }
    }

    @Test fun conflictReplanArchivesCompleteIntentAndKeepsStableCopiesThroughUncertainReplacement() {
        for (replaceObject in listOf(false, true)) {
            val h = SyncJournalHarness()
            val first = h.plan(listOf(h.replacement()))
            h.local.prompts.put(SyncJournalHarness.source("changed"), "a.md")
            assertEquals(SyncApplyOutcome.ReplanAsConflict(first.edits.single().id), h.journal.apply(first))
            val oldIntent = h.local.state.read("sync/apply.json")
            val replacement = h.plan(listOf(h.replacement(h.mutations.read("a.md")!!, "replanned")))
            h.dataOperations.onOperation = { name -> if (name == "file:sync/apply.json") h.dataOperations.failAt = h.dataOperations.calls.size }
            assertFailsWith<SyncError.DurabilityUncertain> { h.journal.replan(replacement) }
            assertContentEquals(oldIntent, h.local.state.read("sync/retained/${first.id}-journal.json"))
            assertEquals(first.id, h.mutations.pendingPermit?.id)
            h.dataOperations.onOperation = null
            h.dataOperations.failAt = null
            if (replaceObject) h.journal = h.replacementJournal()
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
            assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
            assertContentEquals(replacement.edits.single().bytes, h.local.prompts.read("a.md"))
            assertEquals(replacement.nextState, h.states.snapshot.value)
        }
    }

    @Test fun completedStepsRecheckBytesAndRestoreViewerModeWithoutOverwritingAnExternalEdit() {
        for (external in listOf(false, true)) {
            val h = SyncJournalHarness()
            val edit = h.replacement(mode = SyncFileMode.READ_ONLY)
            val plan = h.plan(listOf(edit))
            h.dataOperations.onOperation = { name -> if (name == "file:sync/state.json") h.dataOperations.failAt = h.dataOperations.calls.size }
            assertFailsWith<SyncError.DurabilityUncertain> { h.journal.apply(plan) }
            assertTrue(h.journal.pending!!.steps.single().completed)
            h.libraryOperations.modes[edit.path] = SyncFileMode.NORMAL
            if (external) h.local.prompts.put(SyncJournalHarness.source("external"), edit.path)
            h.dataOperations.onOperation = null
            h.dataOperations.failAt = null
            if (external) {
                assertEquals(SyncApplyOutcome.ReplanAsConflict(edit.id), h.journal.replay())
                assertEquals(SyncJournalHarness.source("external"), h.local.prompts.text(edit.path))
                assertNotNull(h.journal.pending)
                assertFailsWith<LibraryError.RecoveryRequired> { h.local.library.load(edit.path) }
            } else {
                val writes = h.local.prompts.writes.size
                assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
                assertEquals(writes, h.local.prompts.writes.size)
                assertEquals(SyncFileMode.READ_ONLY, h.libraryOperations.modes[edit.path])
            }
        }
    }

    private fun assertCopies(h: SyncJournalHarness, plan: SyncApplyPlan) {
        assertEquals(plan.nextState, h.states.snapshot.value)
        assertNull(h.states.snapshot.error)
        assertNull(h.local.state.stamp("sync/apply.json"))
        assertNull(h.mutations.pendingPermit)
        assertEquals(setOf("a.md", "Conflicts/Copy.md"), h.local.prompts.listFiles().map { it.relativePath }.toSet())
        plan.edits.forEach { assertContentEquals(it.bytes, h.local.prompts.read(it.path)) }
        assertEquals(v.groupID, h.local.library.load("Conflicts/Copy.md").identity)
        plan.edits.forEach { assertContentEquals(it.retainedBytes, h.local.state.read("sync/retained/${it.id}.bin")) }
    }

    private fun assertAdopted(h: SyncJournalHarness, plan: SyncApplyPlan) {
        val old = PromptIdentity.at("a.md")
        assertEquals(plan.nextState, h.states.snapshot.value)
        assertContentEquals(plan.edits.single().bytes, h.local.prompts.read("a.md"))
        assertEquals(2, h.local.history.revisions(v.personalID).size)
        assertTrue(h.local.history.revisions(old).isEmpty())
        assertEquals(1, h.local.usage.useEvents(v.personalID).size)
        assertTrue(h.local.usage.useEvents(old).isEmpty())
        assertEquals(mapOf("field" to "remembered"), h.local.values.rememberedValues(v.personalID))
        assertTrue(h.local.values.rememberedValues(old).isEmpty())
        assertEquals("unknown", h.local.state.text("history/${v.personalID.storageKey}/nested/opaque.bin"))
    }
}
