package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantAcceptanceServiceTest {
    private class Harness(test: TestScope) {
        val worker = StandardTestDispatcher(test.testScheduler)
        val provider = ProviderSettingsHarness(io = worker)
        val files = MemoryStore()
        val state = MemoryStore()
        val clock = TestClock()
        val entropy = TestEntropy()
        var access = AssistantAccessState.PRIVATE_PROMPT
        val library = LibraryService(files, state, clock, entropy, AssistantAccess { access })
        val editing = EditingService(library)
        val client = AssistantFakeClient()
        val service = AssistantService(provider.service, client, client, worker, clock, entropy, timer = worker)
        var context = AssistantContext(UUID.randomUUID(), null)

        suspend fun configure() {
            provider.service.save(ProviderDraft(modelID = "model", key = ProviderKeyEdit.typed("test-key")))
            context = context.copy(profile = service.selectedProfile)
        }

        fun open(source: String = "Original", path: String = "a.md") {
            files.put(source, path)
            val loaded = library.loadForEditing(path)
            context = context.copy(editor = AssistantEditorSnapshot(loaded.source, path, 1, 1, loaded.entry.stamp,
                loaded.entry.document.frontMatter.id, readOnlyReason = loaded.readOnlyReason), access = access)
        }

        suspend fun prepared(destination: AssistantSaveDestination = AssistantSaveDestination.NEW_PROMPT,
            retainingID: ULID? = null): AssistantAcceptance {
            context = context.copy(access = access)
            val command = if (destination == AssistantSaveDestination.IMPROVE || destination == AssistantSaveDestination.PRIVATE_COPY) {
                AssistantCommand.Improve("Improve")
            } else AssistantCommand.Write("Brief")
            val candidate = service.prepare(LlmArtifact("Candidate", "", emptyList(), emptyList(),
                "  文書 e\u0301\r\n\n", "Never persist"), command, context, retainingID).await()
            return AssistantAcceptance(candidate, destination, AssistantTokenUsage(11, 7))
        }
    }

    @Test fun syncRecoveryRefusesEveryAssistantDestinationBeforeIO() = runTest {
        for (blocked in listOf(false, true)) for (destination in AssistantSaveDestination.entries) {
            val h = Harness(this)
            h.configure()
            if (destination == AssistantSaveDestination.PRIVATE_COPY) h.access = AssistantAccessState.GROUP_VIEWER
            h.open()
            val acceptance = h.prepared(destination)
            val owner = UUID.randomUUID()
            if (blocked) h.library.blockSyncApplyForRecovery()
            else h.library.beginSyncApply(owner, SyncTestValues.state())
            val accesses = h.files.accesses + h.state.accesses
            val before = h.files.bytesSnapshot() to h.state.bytesSnapshot()
            assertFailsWith<LibraryError.RecoveryRequired> {
                h.library.acceptAssistant(acceptance, AssistantSavePermit())
            }
            assertEquals(accesses, h.files.accesses + h.state.accesses)
            assertEquals(before, h.files.bytesSnapshot() to h.state.bytesSnapshot())
            if (blocked) h.library.finishEmptySyncRecovery() else h.library.endSyncApply(owner)
            assertNotNull(h.editing.accept(acceptance, AssistantSavePermit()).committed)
        }
    }

    @Test fun exclusiveCreationRetainsPreviewIDThroughOccupiedAndRacedNames() = runTest {
        val h = Harness(this)
        h.configure()
        val acceptance = h.prepared()
        h.files.put("Occupied", "Candidate.md")
        h.files.onCreate = { path -> if (path == "Candidate 2.md") h.files.put("Racer", path) }
        val outcome = h.editing.accept(acceptance, AssistantSavePermit())
        val entry = assertNotNull(outcome.committed).entry
        assertEquals("Candidate 3.md", entry.relativePath)
        assertEquals(acceptance.candidate.content.document.frontMatter.id, entry.document.frontMatter.id)
        assertContentEquals(acceptance.candidate.content.canonicalBytes, h.files.read(entry.relativePath))
        assertEquals("Occupied", h.files.text("Candidate.md"))
        assertEquals("Racer", h.files.text("Candidate 2.md"))
        assertTrue(h.library.history.revisions(entry.identity).isEmpty())
        assertEquals(AssistantTokenUsage(11, 7), h.library.provenance(entry.relativePath)?.usage)
        assertEquals(entry.stamp, h.library.index.snapshot().prompts.single().entry.stamp)
    }

    @Test fun improveRetainsLoadedOrFirstSaveIdentityAndArchivesExactDiskSource() = runTest {
        for (assigned in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            val id = ULID.parse("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!!
            val source = if (assigned) "---\nid: ${id.rawValue}\nfavorite: true\ncustom: retained\n---\nOriginal\r\n" else "Original\r\n"
            h.open(source)
            h.context = h.context.copy(editor = checkNotNull(h.context.editor).copy(source = "Unsaved without ID", revision = 2))
            val acceptance = h.prepared(AssistantSaveDestination.IMPROVE)
            if (assigned) assertEquals(id, acceptance.candidate.content.document.frontMatter.id)
            val entry = assertNotNull(h.editing.accept(acceptance, AssistantSavePermit()).committed).entry
            assertEquals(acceptance.candidate.content.document.frontMatter.id, entry.document.frontMatter.id)
            assertContentEquals(acceptance.candidate.content.canonicalBytes, h.files.read("a.md"))
            val revision = h.library.history.revisions(entry.identity).single()
            assertContentEquals(source.encodeToByteArray(), h.library.history.read(revision))
            assertNull(h.library.provenance(revision))
        }
    }

    @Test fun everyDestinationRefusesChangedOrDeletedSourceBeforeAnyStateWrite() = runTest {
        for (destination in AssistantSaveDestination.entries) for (deleted in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            if (destination == AssistantSaveDestination.PRIVATE_COPY) h.access = AssistantAccessState.GROUP_VIEWER
            h.open()
            val acceptance = h.prepared(destination)
            if (deleted) h.files.delete("a.md") else h.files.put("External", "a.md")
            val conflict = assertIs<AssistantAcceptanceOutcome.Conflict>(h.editing.accept(acceptance, AssistantSavePermit()))
            if (deleted) assertEquals(AssistantAcceptanceConflict.Deleted, conflict.reason)
            else assertEquals(h.files.stamp("a.md"), assertIs<AssistantAcceptanceConflict.Modified>(conflict.reason).currentStamp)
            assertTrue(h.state.bytesSnapshot().isEmpty())
            assertNull(h.files.stamp("Candidate.md"))
        }
    }

    @Test fun newPromptRechecksSourceAfterNameProbeIncludingDeletion() = runTest {
        for (deleted in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            h.open()
            val acceptance = h.prepared()
            h.files.onStamp = { path ->
                if (path == "Candidate.md") {
                    h.files.onStamp = null
                    if (deleted) h.files.delete("a.md") else h.files.put("Changed during naming", "a.md")
                }
            }
            assertIs<AssistantAcceptanceOutcome.Conflict>(h.editing.accept(acceptance, AssistantSavePermit()))
            assertNull(h.files.stamp("Candidate.md"))
            assertTrue(h.state.bytesSnapshot().isEmpty())
        }
    }

    @Test fun finalPermitCheckRollsBackStagedHistoryAndIdentityMigration() = runTest {
        val h = Harness(this)
        h.configure()
        h.open()
        val acceptance = h.prepared(AssistantSaveDestination.IMPROVE)
        val permit = AssistantSavePermit()
        h.state.onWrite = { path -> if (path.endsWith(".md")) permit.invalidate(
            AssistantAcceptanceOutcome.Conflict(AssistantAcceptanceConflict.ChangedBuffer)) }
        val outcome = assertIs<AssistantAcceptanceOutcome.Conflict>(h.editing.accept(acceptance, permit))
        assertEquals(AssistantAcceptanceConflict.ChangedBuffer, outcome.reason)
        assertEquals("Original", h.files.text("a.md"))
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun finalStampCheckRollsBackHistoryWithoutOverwritingExternalBytes() = runTest {
        val h = Harness(this)
        h.configure()
        h.open()
        val acceptance = h.prepared(AssistantSaveDestination.IMPROVE)
        h.state.onWrite = { path -> if (path.endsWith(".md")) h.files.put("Newer", "a.md") }
        assertIs<AssistantAcceptanceOutcome.Conflict>(h.editing.accept(acceptance, AssistantSavePermit()))
        assertEquals("Newer", h.files.text("a.md"))
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun invalidOrNoncanonicalCandidatesAndOccupiedIDsCannotPublish() = runTest {
        for (mode in 0..2) {
            val h = Harness(this)
            h.configure()
            val good = h.prepared()
            val candidate = if (mode == 0) good.candidate else {
                val id = good.candidate.content.document.frontMatter.id
                val source = if (mode == 1) "---\ntitle: Candidate\nid: ${id!!.rawValue}\n---\nBody" else "{{broken"
                val content = ArtifactMergeCandidate(PromptCodec.parse(source, "Candidate.md"))
                AssistantCandidate(content, good.candidate.diff, h.context, AssistantMutationAccess.CURRENT_SCOPE)
            }
            if (mode == 0) h.files.put(good.candidate.content.canonicalBytes, "other.md")
            val outcome = assertIs<AssistantAcceptanceOutcome.Failed>(h.editing.accept(
                AssistantAcceptance(candidate, AssistantSaveDestination.NEW_PROMPT, null), AssistantSavePermit()))
            if (mode == 2) assertIs<AssistantAcceptanceFailure.Invalid>(outcome.reason)
            else assertEquals(if (mode == 0) LibraryError.IdentityMismatch else LibraryError.PreviewMismatch,
                assertIs<AssistantAcceptanceFailure.Editing>(outcome.reason).error)
            assertNull(h.files.stamp("Candidate.md"))
            assertTrue(h.state.bytesSnapshot().isEmpty())
        }
    }

    @Test fun warningsAndDuplicateTokensDoNotWriteAnotherRevision() = runTest {
        for ((historyFailed, provenanceFailed) in listOf(true to false, false to true, true to true)) {
            val h = Harness(this)
            h.configure()
            h.open()
            val acceptance = h.prepared(AssistantSaveDestination.IMPROVE)
            val identity = PromptIdentity.Assigned(checkNotNull(acceptance.candidate.content.document.frontMatter.id))
            repeat(Limits.historyCapPerPrompt) { h.library.history.snapshot("Earlier".encodeToByteArray(), identity, h.clock.date) }
            h.state.fault = { operation, path ->
                if (historyFailed && operation == MemoryStore.Operation.DELETE && path.endsWith(".md") ||
                    provenanceFailed && operation == MemoryStore.Operation.PRIVATE_WRITE && path.endsWith("/head.json")) StoreError.IOFailure else null
            }
            val outcome = h.editing.accept(acceptance, AssistantSavePermit())
            assertEquals(historyFailed, assertNotNull(outcome.committed).historyMaintenanceFailed)
            assertEquals(provenanceFailed, outcome is AssistantAcceptanceOutcome.CommittedWithProvenanceWarning)
            val writes = h.files.writes.size
            val duplicate = assertIs<AssistantAcceptanceOutcome.Failed>(h.editing.accept(acceptance, AssistantSavePermit()))
            assertEquals(AssistantAcceptanceFailure.NotReady, duplicate.reason)
            assertEquals(writes, h.files.writes.size)
        }
    }

    @Test fun viewerCreatesOnlyFreshRootCopyAndLiveDowngradeRefusesOverwrite() = runTest {
        val h = Harness(this)
        h.configure()
        h.access = AssistantAccessState.GROUP_EDITOR
        h.open("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nOriginal", "Groups/Team/a.md")
        val overwrite = h.prepared(AssistantSaveDestination.IMPROVE)
        h.state.onWrite = { path -> if (path.endsWith(".md")) h.access = AssistantAccessState.GROUP_VIEWER }
        val refused = assertIs<AssistantAcceptanceOutcome.Failed>(h.editing.accept(overwrite, AssistantSavePermit()))
        assertEquals(AssistantAcceptanceFailure.AccessDenied, refused.reason)
        assertTrue(h.state.bytesSnapshot().isEmpty())
        h.state.onWrite = null
        val copy = h.prepared(AssistantSaveDestination.PRIVATE_COPY)
        val entry = assertNotNull(h.editing.accept(copy, AssistantSavePermit()).committed).entry
        assertEquals("Candidate.md", entry.relativePath)
        assertNotEquals(h.context.editor?.loadedID, entry.document.frontMatter.id)
        assertEquals("Original", h.library.load("Groups/Team/a.md").document.body)
        assertContentEquals(copy.candidate.content.canonicalBytes, h.files.read(entry.relativePath))
    }

    @Test fun createdDestinationReplacementFailsWithoutOpeningSourceConflict() = runTest {
        val h = Harness(this)
        h.configure()
        h.open()
        val acceptance = h.prepared()
        h.files.onRead = { path -> if (path == "Candidate.md" && path in h.files.writes) {
            h.files.onRead = null
            h.files.put("External copy", path)
        } }
        assertIs<AssistantAcceptanceOutcome.Failed>(h.editing.accept(acceptance, AssistantSavePermit()))
        assertEquals("Original", h.files.text("a.md"))
        assertEquals("External copy", h.files.text("Candidate.md"))
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun deletionAfterVerifiedCommitRetainsActualOutcomeWithoutResurrectingIndex() = runTest {
        val h = Harness(this)
        h.configure()
        val acceptance = h.prepared()
        h.state.onWrite = { path -> if (path.endsWith("/head.json")) h.files.delete("Candidate.md") }
        assertNotNull(h.editing.accept(acceptance, AssistantSavePermit()).committed)
        assertNull(h.files.stamp("Candidate.md"))
        assertTrue(h.library.index.snapshot().prompts.isEmpty())
    }

    @Test fun cancellationAndStaleProfileAreCheckedAfterWaitingForMutation() = runTest {
        for (stale in listOf(false, true)) {
            val h = Harness(this)
            h.configure()
            val acceptance = h.prepared()
            val permit = AssistantSavePermit { !stale }
            if (!stale) permit.invalidate(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Cancelled))
            val outcome = assertIs<AssistantAcceptanceOutcome.Failed>(h.editing.accept(acceptance, permit))
            assertEquals(if (stale) AssistantAcceptanceFailure.StaleContext else AssistantAcceptanceFailure.Cancelled, outcome.reason)
            assertTrue(h.files.bytesSnapshot().isEmpty())
            assertTrue(h.state.bytesSnapshot().isEmpty())
        }
    }

    @Test fun exclusivePublicationAttemptsAreBounded() = runTest {
        val h = Harness(this)
        h.configure()
        val acceptance = h.prepared()
        var attempts = 0
        h.files.onCreate = { path -> attempts++; h.files.put("Racer", path) }
        val failure = assertIs<AssistantAcceptanceOutcome.Failed>(h.editing.accept(acceptance, AssistantSavePermit()))
        assertEquals(LibraryError.CopyLimitReached, assertIs<AssistantAcceptanceFailure.Editing>(failure.reason).error)
        assertEquals(Limits.libraryCreateAttemptCap, attempts)
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }
}
