package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.Role
import kotlinx.coroutines.Job
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.UUID
import kotlin.concurrent.thread
import kotlin.test.*

private class AccessHarness(role: Role = Role.EDITOR, extra: String = "", tracked: Boolean = true,
                            source: ByteArray = ScanHarness.bytes(id = SyncTestValues.groupPrompt, extra = extra)) {
    val scan = ScanHarness()
    val local get() = scan.rig.local
    val library get() = local.library
    val states get() = scan.states
    val accounts get() = scan.rig.accounts
    val path = "Groups/Team/a.md"
    val binding = scan.binding
    val access: GroupAccessService
    val identity: PromptIdentity
    init {
        local.prompts.put(source, path)
        identity = library.load(path).identity
        val hash = runCatching { SyncHash.of(CanonicalForm.group(source, "a.md").bytes) }.getOrElse { SyncHash.of(source) }
        scan.state(ScanHarness.groups(role), if (tracked) mapOf(identity to
            SyncPromptState(SyncTestValues.groupScope, "a.md", if (identity is PromptIdentity.Local) 0 else 1,
                hash.takeIf { identity is PromptIdentity.Assigned })) else emptyMap())
        accounts.setAccount(SyncTestValues.account())
        accounts.updateBinding(binding.root) {
            SyncLibraryBinding(binding.root, binding.account, mapOf(SyncTestValues.group to SyncManagedFolder(binding.account, "Team")))
        }
        access = GroupAccessService(library, states, accounts, binding.root.path)
    }

    fun entry() = library.load(path)
    fun role(role: Role) = states.update(binding) { it.copy(groups = ScanHarness.groups(role)) }
    fun favorite(value: Boolean) = states.update(binding) { it.applyGroupFavorite(value, identity) }

    fun acceptance(destination: AssistantSaveDestination): AssistantAcceptance {
        val loaded = library.loadForEditing(path)
        val artifact = LlmArtifact("Candidate", "", emptyList(), emptyList(), "Improved", "")
        val content = if (destination == AssistantSaveDestination.IMPROVE) {
            assertIs<ArtifactMergeResult.Ready>(ArtifactMerge.improve(artifact, loaded.entry.document)).candidate
        } else {
            assertIs<ArtifactMergeResult.Ready>(ArtifactMerge.write(artifact, SyncTestValues.personal)).candidate
        }
        val profile = ProviderProfile(ProviderProfileID(), "Test", ProviderKind.ANTHROPIC,
            "https://example.test", "model")
        // Composition still supplies LOCAL until Z24; committed service access must suffice.
        val context = AssistantContext(UUID.randomUUID(), profile, AssistantEditorSnapshot(loaded.source,
            path, 1, 1, loaded.entry.stamp, loaded.entry.document.frontMatter.id))
        return AssistantAcceptance(AssistantCandidate(content, ArtifactDiff.compare(loaded.entry.document, content),
            context, context.access.mutationAccess), destination, null)
    }
}

class GroupAccessServiceTest {
    private val v = SyncTestValues

    @Test fun assistantLocalPolicyCannotWriteViewerGroupButAllowsFreshPrivateCopy() {
        for (destination in AssistantSaveDestination.entries) {
            val h = AccessHarness(Role.VIEWER)
            val acceptance = h.acceptance(destination)
            val before = h.local.prompts.bytesSnapshot()
            val outcome = h.local.editing.accept(acceptance, AssistantSavePermit())
            if (destination == AssistantSaveDestination.PRIVATE_COPY) {
                val entry = assertNotNull(outcome.committed).entry
                assertEquals("Candidate.md", entry.relativePath)
                assertNotEquals(h.identity, entry.identity)
                assertContentEquals(acceptance.candidate.content.canonicalBytes, h.local.prompts.read(entry.relativePath))
                assertEquals(before[h.path], h.local.prompts.bytesSnapshot()[h.path])
                assertTrue(h.local.history.revisions(h.identity).isEmpty())
            } else {
                assertIs<AssistantAcceptanceOutcome.Failed>(outcome)
                assertEquals(before, h.local.prompts.bytesSnapshot())
            }
        }
    }

    @Test fun assistantPermitRejectsInterveningDowngradeAndCancellationForEveryDestination() {
        for (destination in AssistantSaveDestination.entries) for (cancel in listOf(false, true)) {
            val h = AccessHarness()
            val acceptance = h.acceptance(destination)
            val permit = h.library.captureWritePermit()
            if (cancel) permit.cancel() else {
                h.role(Role.VIEWER)
                h.role(Role.EDITOR)
            }
            val before = h.local.prompts.bytesSnapshot() to h.local.state.bytesSnapshot()
            val outcome = assertIs<AssistantAcceptanceOutcome.Failed>(
                h.local.editing.accept(acceptance, AssistantSavePermit(), permit))
            if (cancel) assertEquals(AssistantAcceptanceFailure.Cancelled, outcome.reason)
            else assertSame(LibraryError.AccessChanged, assertIs<AssistantAcceptanceFailure.Editing>(outcome.reason).error)
            assertEquals(before, h.local.prompts.bytesSnapshot() to h.local.state.bytesSnapshot())
        }
    }

    @Test fun assistantImproveRechecksCommittedAccessAfterHistoryStagingAndRollsBack() {
        val h = AccessHarness()
        val acceptance = h.acceptance(AssistantSaveDestination.IMPROVE)
        val before = h.local.prompts.bytesSnapshot()
        var staged = false
        h.local.state.onWrite = { path ->
            if (!staged && path.startsWith("history/")) {
                staged = true
                h.role(Role.VIEWER)
            }
        }
        val outcome = h.local.editing.accept(acceptance, AssistantSavePermit())
        assertTrue(staged)
        assertIs<AssistantAcceptanceOutcome.Failed>(outcome)
        assertEquals(before, h.local.prompts.bytesSnapshot())
        assertTrue(h.local.history.revisions(h.identity).isEmpty())
    }

    @Test fun assistantPrivateCopyCannotReuseCommittedIdentityMissingFromDisk() {
        val h = AccessHarness(Role.VIEWER)
        val acceptance = h.acceptance(AssistantSaveDestination.PRIVATE_COPY)
        h.states.update(h.binding) { state -> state.copy(prompts = state.prompts +
            (v.personalID to SyncPromptState(v.userScope, "Missing.md", 1, v.hash))) }
        val before = h.local.prompts.bytesSnapshot()
        val outcome = assertIs<AssistantAcceptanceOutcome.Failed>(h.local.editing.accept(acceptance, AssistantSavePermit()))
        assertSame(LibraryError.IdentityMismatch, assertIs<AssistantAcceptanceFailure.Editing>(outcome.reason).error)
        assertEquals(before, h.local.prompts.bytesSnapshot())
    }

    @Test fun everyLibraryMutationGuardsViewerSourceAndDestinationBeforeWriting() {
        val h = AccessHarness(Role.VIEWER)
        val entry = h.entry()
        val draft = h.local.draft("Draft retained by caller")
        val revision = h.local.history.snapshot(entry.document.source.encodeToByteArray(), entry.identity, h.local.clock.date)
        val bytes = h.local.prompts.bytesSnapshot()
        val state = h.local.state.bytesSnapshot()
        val actions = listOf<() -> Any?>(
            { h.library.create(draft, "Groups/Team/new.md") },
            { h.library.save(draft, h.path, entry.stamp) },
            { h.library.save(draft, h.path) },
            { h.library.assignIdentity(h.path, entry.stamp) },
            { h.library.move(h.path, "Groups/Team/new.md", entry.stamp) },
            { h.library.move(h.path, "Private.md", entry.stamp) },
            { h.library.delete(h.path, entry.stamp) },
            { h.library.delete(h.path) },
            { h.library.restore(revision, h.path, entry.stamp) },
            { h.library.restore(revision, "Private.md") },
            { h.library.create(entry.document, "Private.md") },
        )
        actions.forEachIndexed { index, action ->
            assertFailsWith<LibraryError.AccessDenied>("route $index") { action() }
            assertEquals(bytes, h.local.prompts.bytesSnapshot())
            assertEquals(state, h.local.state.bytesSnapshot())
        }
        val private = h.local.put("Private", "Private.md")
        assertFailsWith<LibraryError.AccessDenied> { h.library.move("Private.md", "Groups/Team/private.md", private.stamp) }
        assertFailsWith<LibraryError.AccessDenied> { h.library.create(draft, "gRoUpS/tEaM/new.md") }
        assertFailsWith<LibraryError.AccessDenied> { h.library.create(draft, "Groups/Unknown/new.md") }
    }

    @Test fun groupSaveAndRestoreKeepProvenanceBehindAccessChecks() {
        val h = AccessHarness()
        val provenance = PromptProvenance(h.local.clock.date, "example.test", "model", null)
        val generated = h.library.save(h.local.draft("Generated"), h.path, h.entry().stamp, provenance,
            permit = h.library.captureWritePermit()).entry
        assertEquals(provenance, h.library.provenance(h.path))
        val manual = h.library.save(h.local.draft("Manual"), h.path, generated.stamp).entry
        assertNull(h.library.provenance(h.path))
        val revision = h.local.history.revisions(generated.identity).single { h.library.provenance(it) == provenance }

        h.role(Role.VIEWER)
        val files = h.local.prompts.bytesSnapshot()
        val state = h.local.state.bytesSnapshot()
        assertFailsWith<LibraryError.AccessDenied> { h.library.restore(revision, h.path, manual.stamp) }
        assertEquals(files, h.local.prompts.bytesSnapshot())
        assertEquals(state, h.local.state.bytesSnapshot())

        h.role(Role.EDITOR)
        val restored = h.library.restore(revision, h.path, manual.stamp)
        assertFalse(restored.provenanceMaintenanceFailed)
        assertEquals(provenance, h.library.provenance(h.path))
    }

    @Test fun editingCommandsCannotBypassViewerAndRetainSourceForFillAndCopy() {
        val h = AccessHarness(Role.VIEWER)
        val entry = h.entry()
        val revision = h.local.history.snapshot(entry.document.source.encodeToByteArray(), entry.identity, h.local.clock.date)
        val loaded = assertIs<PromptLoadResult.Loaded>(h.local.editing.load(h.path)).prompt
        assertEquals(SourceReadOnlyReason.GROUP_VIEWER, loaded.readOnlyReason)
        assertEquals(entry.document.source, loaded.source)
        val before = h.local.prompts.bytesSnapshot()
        val outcomes = listOf(h.local.editing.create("New", "Groups/Team/new.md"),
            h.local.editing.save("Draft", h.path, entry.stamp), h.local.editing.rename(h.path, "renamed.md", entry.stamp),
            h.local.editing.move(h.path, "", entry.stamp), h.local.editing.delete(h.path, entry.stamp),
            h.local.editing.restore(revision, h.path, entry.stamp))
        outcomes.forEach { assertTrue(it is EditResult.ReadOnly || it is EditResult.Failed) }
        assertEquals(before, h.local.prompts.bytesSnapshot())
        assertEquals(entry.document.body, h.local.fill.copy(entry.document, emptyMap(), ch.lkmc.monkeyspaw.core.domain.format.PromptBuiltinValues()))
        assertEquals(entry.document.body, h.local.clipboard.text)
    }

    @Test fun recordedSourceAndActualDestinationBothGuardExternalMoves() {
        for (viewerSource in listOf(true, false)) {
            val h = AccessHarness(if (viewerSource) Role.VIEWER else Role.EDITOR)
            val destination = if (viewerSource) "Private.md" else "Groups/ReadOnly/a.md"
            if (!viewerSource) h.states.update(h.binding) {
                it.copy(groups = it.groups + (v.otherUser to SyncGroupState("ReadOnly", "ReadOnly", Role.VIEWER)))
            }
            h.local.prompts.move(h.path, destination)
            val entry = h.library.load(destination)
            assertEquals(SourceReadOnlyReason.GROUP_VIEWER, entry.access.readOnlyReason)
            assertFailsWith<LibraryError.AccessDenied> { h.library.save(h.local.draft("Draft"), destination, entry.stamp) }
            assertFailsWith<LibraryError.AccessDenied> { h.library.delete(destination, entry.stamp) }
            assertFailsWith<LibraryError.AccessDenied> { h.library.move(destination, "Elsewhere.md", entry.stamp) }
        }
    }

    @Test fun neverBoundGroupsStayLocalAndSignedOutManagedGroupsStayUnavailableAfterRestart() {
        val local = ServiceHarness()
        val states = SyncStateStore(local.state, SyncFlushes())
        val accounts = SyncAccountStore(local.state, SyncFlushes())
        val access = GroupAccessService(local.library, states, accounts, "/library")
        val entry = local.library.create(local.draft("Local"), "Groups/Local/a.md").entry
        assertEquals(PromptAccessState.Local, entry.access)
        assertTrue(access.snapshot.groups.isEmpty())
        val h = AccessHarness()
        val stale = h.entry()
        h.states.clear()
        h.accounts.setAccount(null)
        assertEquals(PromptAccessState.Unavailable, h.library.load(h.path).access)
        assertEquals(PromptAccessState.Unavailable, h.access.snapshot.access("Private.md", stale.identity))
        val restarted = ServiceHarness(prompts = h.local.prompts, state = h.local.state)
        GroupAccessService(restarted.library, SyncStateStore(h.local.state, SyncFlushes()),
            SyncAccountStore(h.local.state, SyncFlushes()), "/library")
        assertFailsWith<LibraryError.AccessDenied> { restarted.library.create(restarted.draft("Denied"), h.path) }
        assertIs<EditResult.Saved>(restarted.editing.create("Still local", "Private.md"))
    }

    @Test fun editorAndOwnerCommandsKeepIdentityHistoryAndServerTransferAuthority() {
        for (role in listOf(Role.EDITOR, Role.OWNER)) {
            val h = AccessHarness(role)
            val entry = h.entry()
            val saved = assertIs<EditResult.Saved>(h.local.editing.save(entry.document.source + "\nEdited", h.path, entry.stamp)).commit.entry
            assertEquals(entry.identity, saved.identity)
            assertEquals(1, h.local.history.revisions(entry.identity).size)
            val moved = assertIs<EditResult.Saved>(h.local.editing.move(h.path, "", saved.stamp)).commit.entry
            assertEquals(entry.identity, moved.identity)
            assertEquals("a.md", moved.relativePath)
            // Local editor rights do not guess immutable created_by; /move is still server-authorized.
            assertIs<PromptAccessState.Group>(moved.access)
        }
    }

    @Test fun viewerFavoritesNeverWriteSourceModesHistoryOrDraftAndProjectIntoRanking() {
        for (source in listOf(ScanHarness.bytes(id = v.groupPrompt),
            "---\nid: ${v.groupPrompt.rawValue}\nformat: 2\n---\nFuture".encodeToByteArray(), byteArrayOf(-1, -2))) {
            val h = AccessHarness(Role.VIEWER, source = source)
            h.local.put("---\ntitle: Alpha\n---\nBody", "Private.md")
            h.library.index.rebuild()
            val before = h.local.prompts.bytesSnapshot()
            val history = h.local.history.revisions(h.identity)
            h.local.prompts.fault = { op, _ -> if (op in setOf(MemoryStore.Operation.WRITE, MemoryStore.Operation.CREATE,
                    MemoryStore.Operation.MOVE, MemoryStore.Operation.DELETE)) StoreError.IOFailure else null }
            val generation = h.access.snapshot.generation
            val saved = h.library.toggleFavorite(h.entry()).entry
            assertTrue(saved.favorite)
            assertEquals(generation, saved.accessGeneration)
            assertEquals(before, h.local.prompts.bytesSnapshot())
            assertEquals(history, h.local.history.revisions(h.identity))
            assertTrue(h.library.index.snapshot().prompts.first { it.entry.identity == saved.identity }.entry.favorite)
            if (saved.document.canRender) assertEquals(h.path, h.library.index.search("").first().entry.relativePath)
            assertFalse(h.library.toggleFavorite(saved).entry.favorite)
        }
    }

    @Test fun personalFavoriteKeepsItsFileKeyAndOrdinaryHistory() {
        val h = AccessHarness(Role.VIEWER)
        val entry = h.local.put("Personal", "Private.md")
        val states = h.states.snapshot.value
        val saved = h.library.toggleFavorite(entry).entry
        assertTrue(saved.favorite)
        assertTrue(saved.document.frontMatter.favorite)
        assertEquals(1, h.local.history.revisions(saved.identity).size)
        assertEquals(states, h.states.snapshot.value)
    }

    @Test fun unrecordedViewerFavoriteUsesRevZeroStateWithoutAssigningAnID() {
        val h = AccessHarness(Role.VIEWER, tracked = false, source = "Body".encodeToByteArray())
        val entry = h.entry()
        val saved = h.library.toggleFavorite(entry).entry
        assertEquals(entry.stamp, saved.stamp)
        assertNull(saved.document.frontMatter.id)
        assertTrue(saved.favorite)
        val record = assertNotNull(h.states.snapshot.value?.prompts?.get(entry.identity))
        assertEquals(0, record.rev)
        assertNull(record.canonicalHash)
        assertEquals(SyncFavoriteInput(null), record.favoriteInput)
        assertTrue(h.scan.scan().changes.isEmpty())
        assertEquals("Body", h.local.prompts.text(h.path))
    }

    @Test fun newerOverlaySurvivesRawTrueFalseAbsentCanonicalRewriteAndRestart() {
        for (raw in listOf(true, false, null)) {
            val h = AccessHarness(Role.VIEWER, extra = raw?.let { "favorite: $it\n" }.orEmpty())
            h.favorite(raw == true)
            val expected = raw != true
            assertEquals(expected, h.library.toggleFavorite(h.entry()).entry.favorite)
            val pending = h.states.snapshot.value!!.prompts.getValue(h.identity).favoriteInput
            assertEquals(SyncFavoriteInput(raw), pending)
            val restarted = ScanHarness(h.scan.rig.restart())
            val local = restarted.rig.local
            GroupAccessService(local.library, restarted.states, restarted.rig.accounts, h.binding.root.path)
            assertEquals(expected, local.library.load(h.path).favorite)
            restarted.prepare()
            assertEquals(expected, restarted.states.snapshot.value!!.favorites[h.identity] == true)
            assertEquals(expected, local.library.load(h.path).favorite)
            assertNull(CanonicalForm.group(local.prompts.read(h.path), "a.md").favorite)
            assertNull(restarted.states.snapshot.value!!.prompts.getValue(h.identity).favoriteInput)
            val twice = restarted.rig.restart()
            GroupAccessService(twice.local.library, twice.states, twice.accounts, h.binding.root.path)
            assertEquals(expected, twice.local.library.load(h.path).favorite)
            assertTrue(ScanHarness(twice).prepare().changes.isEmpty())
        }
    }

    @Test fun adoptionConsumesTheRawKeyWithoutUndoingTheNewerOverlay() {
        val h = AccessHarness(Role.VIEWER, extra = "favorite: true\n")
        h.favorite(true)
        assertFalse(h.library.toggleFavorite(h.entry()).entry.favorite)
        val snapshot = h.scan.scan().snapshot
        val bytes = CanonicalForm.group(h.local.prompts.read(h.path), "a.md").bytes
        val remote = SyncReconciliationRemote(v.groupPrompt, v.groupScope, "a.md", h.path, 2, bytes,
            SyncHash.of(bytes), SyncFileMode.READ_ONLY)
        val state = h.states.snapshot.value!!
        val decision = SyncAdoption.match(remote, snapshot, state.groups)
        val plan = SyncAdoption.application(decision, state, snapshot, state.groups, "Local", h.local.clock.date,
            { v.device }, h.scan.mutations)
        assertEquals(SyncApplyOutcome.Committed, h.scan.journal.apply(plan))
        assertFalse(h.entry().favorite)
        assertNull(h.states.snapshot.value!!.prompts.getValue(h.identity).favoriteInput)
        assertContentEquals(bytes, h.local.prompts.read(h.path))
    }

    @Test fun dirtyViewerSourceKeepsFavoriteInputUntilTheSourceCanActuallyBeCanonicalized() {
        val h = AccessHarness(Role.VIEWER, extra = "favorite: true\n")
        h.favorite(true)
        val dirty = ScanHarness.bytes("Dirty source", v.groupPrompt, "favorite: true\n")
        h.local.prompts.put(dirty, h.path)
        assertFalse(h.library.toggleFavorite(h.entry()).entry.favorite)
        assertTrue(h.scan.prepare().changes.isEmpty())
        assertFalse(h.states.snapshot.value!!.favorites[h.identity] == true)
        assertEquals(SyncFavoriteInput(true), h.states.snapshot.value!!.prompts.getValue(h.identity).favoriteInput)
        val restarted = ScanHarness(h.scan.rig.restart())
        assertTrue(restarted.prepare().changes.isEmpty())
        assertFalse(restarted.states.snapshot.value!!.favorites[h.identity] == true)
        assertContentEquals(dirty, h.local.prompts.read(h.path))
    }

    @Test fun committedDowngradeIsSeenEvenBeforeItsNotificationCanRun() {
        val scan = ScanHarness()
        scan.put(ScanHarness.bytes(id = v.groupPrompt), "Groups/Team/a.md")
        scan.state(ScanHarness.groups(), mapOf(v.groupID to ScanHarness.record(ScanHarness.bytes(id = v.groupPrompt), v.groupScope)))
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        scan.states.observeChanges { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        GroupAccessService(scan.rig.local.library, scan.states, scan.rig.accounts, "/library")
        val failure = AtomicReference<Throwable?>()
        val updater = thread {
            try { scan.states.update(scan.binding) { it.copy(groups = ScanHarness.groups(Role.VIEWER)) } }
            catch (error: Throwable) { failure.set(error) }
        }
        try {
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            assertFailsWith<LibraryError.AccessChanged> { scan.rig.local.library.save(scan.rig.local.draft("Queued"), "Groups/Team/a.md") }
        } finally { release.countDown(); updater.join(10_000) }
        assertFalse(updater.isAlive)
        assertNull(failure.get())
    }

    @Test fun queuedWriteAndAssistantAcceptancePermitRejectDowngradeThenUpgrade() {
        val h = AccessHarness()
        val original = h.entry()
        val permit = h.local.editing.captureWritePermit()
        val queued = CountDownLatch(1)
        val result = AtomicReference<EditResult>()
        lateinit var writer: Thread
        h.library.withSyncLock {
            writer = thread {
                queued.countDown()
                result.set(h.local.editing.save(original.document.source + "Draft", h.path, original.stamp, permit))
            }
            assertTrue(queued.await(10, TimeUnit.SECONDS))
            h.role(Role.VIEWER)
            h.role(Role.EDITOR)
        }
        writer.join(10_000)
        assertFalse(writer.isAlive)
        assertEquals(EditResult.Failed(LibraryError.AccessChanged), result.get())
        assertFailsWith<LibraryError.AccessChanged> {
            h.library.createPrivateCopy(h.local.draft("Assistant candidate"), original, "Accepted.md", permit)
        }
        assertEquals(original.stamp, h.entry().stamp)
        assertNull(h.local.prompts.stamp("Accepted.md"))
    }

    @Test fun intermediateDowngradeInvalidatesPermitsEvenWhenBothNotificationsWaitForTheLibrary() {
        val scan = ScanHarness()
        val path = "Groups/Team/a.md"
        scan.put(ScanHarness.bytes(id = v.groupPrompt), path)
        scan.state(ScanHarness.groups(), mapOf(v.groupID to ScanHarness.record(ScanHarness.bytes(id = v.groupPrompt), v.groupScope)))
        val viewer = CountDownLatch(1)
        val editor = CountDownLatch(1)
        scan.states.observeChanges {
            if (scan.states.snapshot.value!!.groups.getValue(v.group).role == Role.VIEWER) viewer.countDown() else editor.countDown()
        }
        val library = scan.rig.local.library
        GroupAccessService(library, scan.states, scan.rig.accounts, "/library")
        val permit = library.captureWritePermit()
        val failures = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        val workers = mutableListOf<Thread>()
        try {
            library.withSyncLock {
                workers.add(thread {
                    try { scan.states.update(scan.binding) { it.copy(groups = ScanHarness.groups(Role.VIEWER)) } }
                    catch (error: Throwable) { failures.add(error) }
                })
                assertTrue(viewer.await(10, TimeUnit.SECONDS))
                workers.add(thread {
                    try { scan.states.update(scan.binding) { it.copy(groups = ScanHarness.groups(Role.EDITOR)) } }
                    catch (error: Throwable) { failures.add(error) }
                })
                assertTrue(editor.await(10, TimeUnit.SECONDS))
                assertFailsWith<LibraryError.AccessChanged> { library.create(scan.rig.local.draft("Queued"), "Groups/Team/new.md", permit = permit) }
            }
        } finally { workers.forEach { it.join(10_000) } }
        assertTrue(workers.none { it.isAlive })
        assertTrue(failures.isEmpty())
        assertNull(scan.files.stamp("Groups/Team/new.md"))
    }

    @Test fun cancellationAndOtherGraphsRejectPermitsBeforeAnyFilePublication() {
        val h = AccessHarness()
        for (cancelJob in listOf(true, false)) {
            val job = Job()
            val permit = h.library.captureWritePermit(job)
            if (cancelJob) job.cancel() else permit.cancel()
            val before = h.local.prompts.bytesSnapshot()
            assertFailsWith<CancellationException> { h.local.editing.create("Candidate", "Accepted.md", permit) }
            assertEquals(before, h.local.prompts.bytesSnapshot())
        }
        val other = ServiceHarness()
        assertFailsWith<LibraryError.AccessChanged> { other.library.create(other.draft("Candidate"), "Other.md", permit = h.library.captureWritePermit()) }
    }

    @Test fun cancellationAfterQueueingRejectsTheWriteAtTheMutationBoundary() {
        val h = AccessHarness()
        val job = Job()
        val permit = h.library.captureWritePermit(job)
        val queued = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        lateinit var writer: Thread
        h.library.withSyncLock {
            writer = thread {
                queued.countDown()
                try { h.local.editing.create("Queued candidate", "Accepted.md", permit) }
                catch (error: Throwable) { failure.set(error) }
            }
            assertTrue(queued.await(10, TimeUnit.SECONDS))
            job.cancel()
        }
        writer.join(10_000)
        assertFalse(writer.isAlive)
        assertIs<CancellationException>(failure.get())
        assertNull(h.local.prompts.stamp("Accepted.md"))
    }

    @Test fun uncertainFavoritePublicationBlocksThenRecoversTheDurableOverlay() {
        val h = AccessHarness(Role.VIEWER)
        val original = h.local.prompts.bytesSnapshot()
        h.scan.rig.dataOperations.failAt = h.scan.rig.dataOperations.calls.size + 1
        assertFailsWith<SyncError.DurabilityUncertain> { h.library.toggleFavorite(h.entry()) }
        assertTrue(h.access.snapshot.isBlocked)
        assertFailsWith<LibraryError.RecoveryRequired> { h.library.load(h.path) }
        h.scan.rig.dataOperations.failAt = null
        h.states.recover(h.binding)
        assertFalse(h.access.snapshot.isBlocked)
        assertTrue(h.entry().favorite)
        assertEquals(original, h.local.prompts.bytesSnapshot())
    }

    @Test fun indexProjectsNewAccessWithoutMutatingPreviouslyPublishedSnapshots() {
        val h = AccessHarness()
        h.library.index.rebuild()
        val before = h.library.index.snapshot()
        val policy = h.access.snapshot
        h.role(Role.VIEWER)
        val after = h.library.index.snapshot()
        assertTrue(after.version > before.version)
        assertNull(before.prompts.single().entry.access.readOnlyReason)
        assertEquals(SourceReadOnlyReason.GROUP_VIEWER, after.prompts.single().entry.access.readOnlyReason)
        assertEquals(Role.EDITOR, policy.groups.getValue(v.group).role)
        assertTrue(policy.generation < h.access.snapshot.generation)
        assertFailsWith<UnsupportedOperationException> { (policy.groups as MutableMap).clear() }
        assertEquals(before.prompts.single().entry.document.source, after.prompts.single().entry.document.source)
    }

    @Test fun downgradeDuringHistoryStagingRollsBackTheUnpublishedSave() {
        val h = AccessHarness()
        val entry = h.entry()
        val before = h.local.state.bytesSnapshot().filterKeys { !it.startsWith("sync/") }
        h.local.state.onCreate = { path -> if (path.startsWith("history/")) h.role(Role.VIEWER) }
        assertEquals(EditResult.Failed(LibraryError.AccessChanged), h.local.editing.save(entry.document.source + "Draft", h.path, entry.stamp))
        assertEquals(entry.stamp, h.entry().stamp)
        assertEquals(before, h.local.state.bytesSnapshot().filterKeys { !it.startsWith("sync/") })
    }

    @Test fun privateCopiesValidateTargetsAllocateFreshIDsAndKeepDraftsSeparate() {
        val h = AccessHarness(Role.VIEWER)
        val entry = h.entry()
        val draft = entry.document.source + "\nUnsaved"
        val source = h.local.prompts.bytesSnapshot()
        val copied = assertIs<EditResult.Saved>(h.local.editing.createPrivateCopy(draft, entry, "Conflicts/My copy.md")).commit.entry
        assertEquals(PromptAccessState.Local, copied.access)
        assertNotEquals(entry.identity, copied.identity)
        assertTrue(copied.document.body.endsWith("Unsaved"))
        assertEquals(SyncPromptOrigin.ConflictOf(v.groupPrompt), SyncConflictMetadata.origin(copied.document))
        assertEquals(source[h.path], h.local.prompts.bytesSnapshot()[h.path])
        assertTrue(h.local.history.revisions(entry.identity).isEmpty())
        assertIs<EditResult.Invalid>(h.local.editing.createPrivateCopy("{{broken", entry, "Invalid.md"))
        for (target in listOf("Groups/Team/copy.md", "groups/Other/copy.md", "../escape.md", "README.md")) {
            assertIs<EditResult.Failed>(h.local.editing.createPrivateCopy(draft, entry, target))
            assertNull(h.local.prompts.stamp(target.takeUnless { it.startsWith("..") } ?: "escape.md"))
        }
        h.local.clock.date = h.local.clock.date.plusSeconds(1)
        assertEquals(EditResult.DestinationOccupied, h.local.editing.createPrivateCopy(draft, entry, copied.relativePath))
        assertEquals(copied.stamp, h.library.load(copied.relativePath).stamp)
    }

    @Test fun privateCopyCannotReuseAKnownIdentityWhoseFileIsCurrentlyMissing() {
        val h = AccessHarness(Role.VIEWER)
        val id = ULID.generate(h.local.clock.date, h.local.entropy.value)
        h.states.update(h.binding) { it.copy(prompts = it.prompts +
            (PromptIdentity.Assigned(id) to SyncPromptState(v.userScope, "Missing.md", 1, v.hash))) }
        val before = h.local.prompts.bytesSnapshot()
        assertFailsWith<LibraryError.IdentityMismatch> {
            h.library.createPrivateCopy(h.local.draft("Draft"), h.entry(), "Copy.md")
        }
        assertEquals(before, h.local.prompts.bytesSnapshot())
    }

    @Test fun staleFavoriteAndFailedStatePublicationPreserveSourceAndOverlay() {
        val h = AccessHarness(Role.VIEWER)
        val entry = h.entry()
        val before = h.local.prompts.bytesSnapshot()
        val state = h.states.snapshot.value
        h.local.state.fault = { op, path -> if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/state.json") StoreError.IOFailure else null }
        assertFailsWith<SyncError.WriteFailed> { h.library.toggleFavorite(entry) }
        assertEquals(state, h.states.snapshot.value)
        assertFalse(h.entry().favorite)
        assertEquals(before, h.local.prompts.bytesSnapshot())
        h.local.state.fault = null
        h.role(Role.EDITOR)
        assertFailsWith<LibraryError.AccessChanged> { h.library.toggleFavorite(entry) }
        val fresh = h.entry()
        h.local.prompts.put(fresh.document.source, h.path)
        assertFailsWith<LibraryError.Conflict> { h.library.toggleFavorite(fresh) }
    }

    @Test fun metadataErrorsWrongRootsAndAccountSwitchesBlockWritesUntilRecovery() {
        for (fault in listOf("root", "account", "state", "ownership")) {
            val h = AccessHarness()
            val permit = h.library.captureWritePermit()
            when (fault) {
                "root" -> h.states.reset(v.binding("/other"))
                "account" -> h.accounts.setAccount(v.account().copy(identity = v.accountIdentity(userID = v.otherUser)))
                "state" -> {
                    h.local.state.put("broken", "sync/state.json")
                    assertFailsWith<SyncError.CorruptFile> { h.states.load(h.binding) }
                }
                else -> {
                    h.local.state.put("broken", "sync/binding.json")
                    assertFailsWith<SyncError.CorruptFile> { h.accounts.binding(h.binding.root) }
                }
            }
            assertTrue(h.access.snapshot.isBlocked)
            assertFailsWith<LibraryError> { h.library.create(h.local.draft("Denied"), "Personal.md", permit = permit) }
            assertNull(h.local.prompts.stamp("Personal.md"))
        }
    }
}
