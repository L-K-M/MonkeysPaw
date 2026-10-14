package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.Role
import kotlin.test.*

internal class ScanHarness(val rig: SyncJournalHarness = SyncJournalHarness(seed = false)) {
    val binding get() = rig.binding
    val files get() = rig.local.prompts
    val states get() = rig.states
    val mutations get() = rig.mutations
    val journal get() = rig.journal

    fun put(bytes: ByteArray = bytes(), path: String = "a.md") { files.put(bytes, path) }
    fun state(groups: Map<ULID, SyncGroupState> = emptyMap(), prompts: Map<PromptIdentity, SyncPromptState> = emptyMap(),
              favorites: Map<PromptIdentity, Boolean> = emptyMap()): SyncState =
        SyncState(binding, SyncTestValues.uuid, mapOf(SyncTestValues.userScope to "old opaque"), groups, prompts, favorites)
            .also { value -> states.update(binding) { value } }

    fun scan(ownership: SyncLibraryBinding? = null, retained: List<SyncRetainedRescue> = emptyList(),
             ids: List<ULID> = listOf(SyncTestValues.device)): SyncLocalScan {
        val iterator = ids.iterator()
        return SyncLocalScanner.scan(binding, states.load(binding), ownership, retained,
            SyncReconciliationSnapshot.Availability.AVAILABLE, freshID = {
                if (!iterator.hasNext()) throw SyncError.InvalidState
                iterator.next()
            }, mutations = mutations)
    }

    fun prepare(): SyncLocalScan {
        repeat(3) {
            val scan = scan()
            val plan = scan.preparation ?: return scan
            assertTrue(scan.changes.isEmpty())
            assertEquals(SyncApplyOutcome.Committed, journal.apply(plan))
        }
        error("Preparation did not settle")
    }

    companion object {
        fun bytes(body: String = "Body\r\n", id: ULID? = SyncTestValues.personal, extra: String = ""): ByteArray =
            ("---\n" + (id?.let { "id: '${it.rawValue}'\n" } ?: "") + "title: Exact\n" + extra + "---\n" + body).encodeToByteArray()
        fun groups(role: Role = Role.EDITOR): Map<ULID, SyncGroupState> =
            mapOf(SyncTestValues.group to SyncGroupState("Team", "Team", role))
        fun record(bytes: ByteArray = bytes(), scope: SyncScopeKey = SyncTestValues.userScope, path: String = "a.md", rev: Long = 3) =
            SyncPromptState(scope, path, rev, if (rev == 0L) null else SyncHash.of(SyncLocalScanner.canonical(bytes, path, scope).bytes))
    }
}

class SyncLocalScannerTest {
    private val v = SyncTestValues

    @Test fun copiedAssignedIDPreparesThenCreatesWithExactPrivateBytes() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes(extra = "# exact comment\nx-extra: [雪, true]\n")
        h.put(bytes)
        val initial = h.scan()
        assertTrue(initial.changes.isEmpty())
        assertTrue(assertNotNull(initial.preparation).edits.isEmpty())
        assertNull(initial.preparation.nextState.databaseID)
        assertTrue(initial.preparation.nextState.cursors.isEmpty())
        val prompt = assertIs<SyncLocalChange.Create>(h.prepare().changes.single()).prompt
        assertEquals(v.personalID, prompt.identity)
        assertContentEquals(bytes, prompt.canonical.bytes)
        assertContentEquals(bytes, h.files.read("a.md"))
    }

    @Test fun idlessGroupAssignmentMigratesHistoryUsageValuesAndFavorite() {
        val h = ScanHarness()
        val path = "Groups/Team/a.md"
        val local = PromptIdentity.at(path)
        val bytes = ScanHarness.bytes(id = null, extra = "favorite: true\nprivate: false\n")
        h.put(bytes, path)
        val old = h.state(ScanHarness.groups(), mapOf(local to ScanHarness.record(bytes, v.groupScope, rev = 0)), mapOf(local to true))
        h.rig.local.history.snapshot(bytes, local, h.rig.local.clock.date)
        h.rig.local.usage.recordUse(local)
        h.rig.local.values.record(local, mapOf("field" to "remembered"))
        val scan = h.scan()
        val plan = assertNotNull(scan.preparation)
        assertTrue(scan.changes.isEmpty())
        assertEquals(old.cursors, plan.nextState.cursors)
        assertEquals(old.databaseID, plan.nextState.databaseID)
        val assigned = PromptIdentity.Assigned(v.device)
        assertNull(plan.nextState.prompts[local])
        assertEquals(true, plan.nextState.favorites[assigned])
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertEquals(1, h.rig.local.history.revisions(assigned).size)
        assertTrue(h.rig.local.history.revisions(local).isEmpty())
        assertEquals(1, h.rig.local.usage.useEvents(assigned).size)
        assertTrue(h.rig.local.usage.useEvents(local).isEmpty())
        assertEquals(mapOf("field" to "remembered"), h.rig.local.values.rememberedValues(assigned))
        assertTrue(h.rig.local.values.rememberedValues(local).isEmpty())
        val rewritten = h.files.read(path)
        assertContentEquals(CanonicalForm.group(rewritten, "a.md").bytes, rewritten)
        assertNull(CanonicalForm.group(rewritten, "a.md").favorite)
        assertFalse(rewritten.decodeToString().contains("private:"))
        assertEquals(0, h.states.snapshot.value!!.prompts[assigned]!!.rev)
        assertNull(h.states.snapshot.value!!.prompts[assigned]!!.canonicalHash)
        assertNull(h.scan().preparation)
        assertEquals(assigned, assertIs<SyncLocalChange.Create>(h.scan().changes.single()).prompt.identity)
    }

    @Test fun reserveIDBeforeEarlierIdlessPathAndDetectRenameMoveAndEdit() {
        val h = ScanHarness()
        h.state(ScanHarness.groups(), mapOf(v.personalID to ScanHarness.record()))
        h.put(ScanHarness.bytes(id = null))
        h.put(path = "z.md")
        val scan = h.prepare()
        assertEquals(v.personalID, scan.changes.filterIsInstance<SyncLocalChange.Rename>().single().prompt.identity)
        assertEquals(v.device, (scan.changes.filterIsInstance<SyncLocalChange.Create>().single().prompt.identity as PromptIdentity.Assigned).id)
        h.files.move("z.md", "Groups/Team/new.md")
        h.put(ScanHarness.bytes("Moved and edited"), "Groups/Team/new.md")
        val moved = h.prepare()
        val move = moved.changes.filterIsInstance<SyncLocalChange.Move>().single()
        assertEquals(v.groupScope, move.prompt.scope)
        assertEquals("a.md", move.recorded.path)
        assertTrue(moved.changes.none { it is SyncLocalChange.Delete })
        h.files.move("Groups/Team/new.md", "edit.md")
        h.state(prompts = mapOf(v.personalID to ScanHarness.record(path = "edit.md")))
        assertEquals(v.personalID, h.prepare().changes.filterIsInstance<SyncLocalChange.Update>().single().prompt.identity)
    }

    @Test fun idlessRecordedPathRestoresIdentityAndBecomesUpdate() {
        val h = ScanHarness()
        h.state(prompts = mapOf(v.personalID to ScanHarness.record()))
        h.put(ScanHarness.bytes("Edited", id = null))
        val change = assertIs<SyncLocalChange.Update>(h.prepare().changes.single())
        assertEquals(v.personalID, change.prompt.identity)
    }

    @Test fun externallyAssignedIDMigratesExactPathKeyBeforeCreate() {
        val h = ScanHarness()
        val path = "Groups/Team/a.md"
        val local = PromptIdentity.at(path)
        val bytes = CanonicalForm.group(ScanHarness.bytes(id = v.groupPrompt), "a.md").bytes
        h.put(bytes, path)
        h.state(ScanHarness.groups(), mapOf(local to ScanHarness.record(bytes, v.groupScope, rev = 0)), mapOf(local to true))
        h.rig.local.history.snapshot(bytes, local, h.rig.local.clock.date)
        h.rig.local.usage.recordUse(local)
        h.rig.local.values.record(local, mapOf("field" to "remembered"))
        val plan = assertNotNull(h.scan().preparation)
        assertEquals(SyncLibraryEdit.Kind.ADOPT, plan.edits.single().kind)
        assertEquals(local.storageKey, plan.edits.single().transition?.source)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertContentEquals(bytes, h.files.read(path))
        assertEquals(true, h.states.snapshot.value!!.favorites[v.groupID])
        assertEquals(1, h.rig.local.history.revisions(v.groupID).size)
        assertEquals(1, h.rig.local.usage.useEvents(v.groupID).size)
        assertEquals(mapOf("field" to "remembered"), h.rig.local.values.rememberedValues(v.groupID))
        assertNull(h.scan().preparation)
        assertEquals(v.groupID, assertIs<SyncLocalChange.Create>(h.scan().changes.single()).prompt.identity)
    }

    @Test fun externalAssignmentAtDifferentSpellingIsHeldRatherThanMigratingWrongKey() {
        val h = ScanHarness()
        h.put(ScanHarness.bytes(id = v.groupPrompt), "A.md")
        h.state(prompts = mapOf(PromptIdentity.at("a.md") to ScanHarness.record(rev = 0)))
        val scan = h.scan(ids = emptyList())
        assertTrue(scan.changes.isEmpty())
        assertEquals(SyncIssueCode.IDMismatch, scan.issues["A.md"])
        assertTrue("A.md" in scan.snapshot.heldPaths)
        assertTrue(assertNotNull(scan.preparation).edits.isEmpty())
    }

    @Test fun duplicateWinnerUsesRawUnsignedUtf8AndKeepsSharedKeyedData() {
        for (paths in listOf(listOf("é.md", "e\u0301.md", "z.md"), listOf("🐾.md", "\uE000.md", "z.md"))) {
            val h = ScanHarness()
            paths.forEach { h.put(path = it) }
            h.rig.local.history.snapshot(ScanHarness.bytes(), v.personalID, h.rig.local.clock.date)
            h.rig.local.usage.recordUse(v.personalID)
            h.rig.local.values.record(v.personalID, mapOf("field" to "winner"))
            val plan = assertNotNull(h.scan(ids = listOf(v.device, v.groupPrompt)).preparation)
            assertEquals(if (paths[0] == "é.md") listOf("z.md", "é.md") else listOf("\uE000.md", "🐾.md"), plan.edits.map { it.path })
            assertTrue(plan.edits.all { it.kind == SyncLibraryEdit.Kind.REPAIR_DUPLICATE })
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            val winner = if (paths[0] == "é.md") "e\u0301.md" else "z.md"
            assertEquals(v.personalID, h.mutations.read(winner)!!.identity)
            assertEquals(mapOf("field" to "winner"), h.rig.local.values.rememberedValues(v.personalID))
            assertTrue(h.rig.local.values.rememberedValues(PromptIdentity.Assigned(v.device)).isEmpty())
            assertEquals(1, h.rig.local.usage.useEvents(v.personalID).size)
            assertEquals(1, h.rig.local.history.revisions(v.personalID).size)
            assertNull(ScanHarness(h.rig.restart()).scan().preparation)
        }
    }

    @Test fun invalidDuplicateCannotStealValidOwnerOrBaseline() {
        val h = ScanHarness()
        val old = h.state(prompts = mapOf(v.personalID to ScanHarness.record(path = "z.md")))
        h.put(ScanHarness.bytes(extra = "format: 999\n"), "A.md")
        h.put(path = "z.md")
        val scan = h.scan(ids = emptyList())
        val next = assertNotNull(scan.preparation).nextState
        assertTrue(scan.preparation.edits.isEmpty())
        assertEquals(old.prompts[v.personalID], next.prompts[v.personalID])
        assertEquals(SyncIssueCode.Content(PromptIssueCode.UNSUPPORTED_FORMAT), next.prompts[PromptIdentity.at("A.md")]?.lastError?.code)
    }

    @Test fun viewerDuplicateLoserIsHeldAndNeverRepairedOrPushed() {
        val h = ScanHarness()
        h.state(ScanHarness.groups(Role.VIEWER))
        h.put(path = "A.md")
        h.put(path = "Groups/Team/a.md")
        val scan = h.scan(ids = emptyList())
        assertTrue("Groups/Team/a.md" in scan.snapshot.heldPaths)
        assertEquals(SyncIssueCode.IDMismatch, scan.issues["Groups/Team/a.md"])
        assertTrue(assertNotNull(scan.preparation).edits.isEmpty())
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(scan.preparation))
        assertEquals("A.md", assertIs<SyncLocalChange.Create>(h.scan(ids = emptyList()).changes.single()).prompt.file.path)
    }

    @Test fun malformedFutureBinaryAndInvalidMarkersStayExactAndHeld() {
        val h = ScanHarness()
        val samples = mapOf("broken.md" to "---\ntitle: [\n---\nRaw".encodeToByteArray(),
            "future.md" to ScanHarness.bytes(extra = "format: 999\n"), "binary.md" to byteArrayOf(-1, 0),
            "marker.md" to ScanHarness.bytes(id = v.groupPrompt, extra = "x-monkeyspaw-rescued: 'true'\n"))
        samples.forEach { (path, bytes) -> h.put(bytes, path) }
        val scan = h.scan(ids = emptyList())
        assertEquals(samples.keys, scan.snapshot.heldPaths)
        assertTrue(scan.changes.isEmpty())
        assertTrue(assertNotNull(scan.preparation).edits.isEmpty())
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(scan.preparation))
        samples.forEach { (path, bytes) -> assertContentEquals(bytes, h.files.read(path)) }
        assertNull(h.scan(ids = emptyList()).preparation)
    }

    @Test fun orphanAndForeignGroupOwnershipRequireRescueBeforeAnyMatching() {
        for (foreign in listOf(false, true)) {
            val h = ScanHarness()
            val paths = if (foreign) listOf("Groups/Team/a.md") else listOf("Groups/Unknown/a.md", "Groups/loose.md", "groups/Team/a.bin")
            paths.forEach { h.put(path = it) }
            h.put(ScanHarness.bytes(id = null), "local.md")
            h.state(ScanHarness.groups())
            val ownership = if (foreign) SyncLibraryBinding(h.binding.root, h.binding.account,
                mapOf(v.group to SyncManagedFolder(v.accountIdentity(userID = v.otherUser), "Team"))) else null
            val scan = h.scan(ownership, ids = emptyList())
            assertEquals(paths.toSet(), scan.orphanFiles.map { it.path }.toSet())
            assertTrue(scan.changes.isEmpty())
            assertNull(scan.preparation)
            assertTrue(scan.snapshot.heldPaths.containsAll(paths))
        }
    }

    @Test fun fullIgnoredInventoryPreservesOccupantsAndNeverInfersBrowserDeletes() {
        val h = ScanHarness()
        val paths = listOf(".git/a.md", "_draft/a.md", "_a.md", "README.md")
        val records = paths.mapIndexed { i, path ->
            val id = SyncIdentifiers.ulid("0000000000000000000000001$i")
            val bytes = ScanHarness.bytes(id = id)
            h.put(bytes, path)
            (PromptIdentity.Assigned(id) as PromptIdentity) to ScanHarness.record(bytes, path = path, rev = if (i == 0) 0 else 3)
        }.toMap()
        h.state(prompts = records)
        h.put(path = ".prompt.md")
        h.put(ScanHarness.bytes(id = v.groupPrompt), "folder/README.md")
        val scan = h.prepare()
        assertEquals(6, scan.snapshot.files.size)
        assertEquals(2, scan.changes.size)
        assertTrue(scan.changes.none { it is SyncLocalChange.Delete })
        paths.forEach { assertEquals(SyncIssueCode.LocalVisibility, scan.issues[it]) }
        h.files.move(".prompt.md", "_hidden.md")
        h.state(prompts = mapOf(v.personalID to ScanHarness.record(path = ".prompt.md")))
        assertTrue(h.scan().changes.none { it is SyncLocalChange.Delete })
    }

    @Test fun trueAbsenceDeletesButReplacementOccupantDoesNot() {
        val h = ScanHarness()
        h.state(prompts = mapOf(v.personalID to ScanHarness.record()))
        assertEquals(v.personalID, assertIs<SyncLocalChange.Delete>(h.scan().changes.single()).identity)
        h.put(ScanHarness.bytes("Replacement", v.groupPrompt))
        assertEquals(v.groupID, assertIs<SyncLocalChange.Create>(h.prepare().changes.single()).prompt.identity)
    }

    @Test fun viewerFavoriteTrueFalseAbsentLiftAndRewriteExactlyOnce() {
        for (favorite in listOf("favorite: true\n", "favorite: false\n", "")) {
            val h = ScanHarness()
            val bytes = ScanHarness.bytes(extra = favorite + "private: false\n")
            val canonical = CanonicalForm.group(bytes, "a.md").bytes
            h.put(bytes, "Groups/Team/a.md")
            h.state(ScanHarness.groups(Role.VIEWER), mapOf(v.personalID to ScanHarness.record(canonical, v.groupScope)), mapOf(v.personalID to true))
            val plan = assertNotNull(h.scan().preparation)
            h.files.writes.clear()
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            assertEquals(listOf("Groups/Team/a.md"), h.files.writes)
            assertEquals(if (favorite == "favorite: false\n") null else true, h.states.snapshot.value!!.favorites[v.personalID])
            assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes["Groups/Team/a.md"])
            assertContentEquals(canonical, h.files.read("Groups/Team/a.md"))
            assertNull(h.scan().preparation)
            assertTrue(h.scan().changes.isEmpty())
        }
    }

    @Test fun transferRetainsPersonalKeysUntilMoveAcknowledges() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes(extra = "favorite: true\nprivate: false\n")
        h.put(bytes, "Groups/Team/a.md")
        h.state(ScanHarness.groups(), mapOf(v.personalID to ScanHarness.record(bytes)))
        val scan = h.scan()
        assertNull(scan.preparation)
        assertEquals(true, assertIs<SyncLocalChange.Move>(scan.changes.single()).prompt.canonical.favorite)
        assertContentEquals(bytes, h.files.read("Groups/Team/a.md"))
        h.state(ScanHarness.groups(), mapOf(v.personalID to ScanHarness.record(CanonicalForm.group(bytes, "a.md").bytes, v.groupScope)))
        assertTrue(h.prepare().changes.isEmpty())
        assertEquals(true, h.states.snapshot.value!!.favorites[v.personalID])
    }

    @Test fun accountHoldsPrecedeAssignmentDuplicateRepairAndDeleteAndSurviveRenameEdit() {
        val h = ScanHarness()
        val assigned = ScanHarness.bytes()
        val idless = ScanHarness.bytes(id = null)
        h.put(assigned, "held.md")
        h.put(assigned, "copy.md")
        h.put(idless, "renamed.md")
        val source = v.accountIdentity(userID = v.otherUser)
        val ownership = SyncLibraryBinding(h.binding.root, h.binding.account, holds = listOf(
            SyncHeldPrompt(v.personalID, "held.md", source, SyncHash.of(assigned)),
            SyncHeldPrompt(PromptIdentity.at("old.md"), "old.md", source, SyncHash.of(idless))))
        var scan = h.scan(ownership, ids = emptyList())
        assertNull(scan.preparation)
        assertTrue(scan.changes.isEmpty())
        assertEquals(setOf("held.md", "copy.md", "renamed.md"), scan.snapshot.heldPaths)
        h.files.move("copy.md", "edited.md")
        h.put(ScanHarness.bytes("Edited after rename"), "edited.md")
        h.state(prompts = mapOf(v.personalID to ScanHarness.record(path = "missing.md")))
        scan = h.scan(ownership, ids = emptyList())
        assertTrue("edited.md" in scan.snapshot.heldPaths)
        assertTrue(scan.changes.isEmpty())
        assertNull(scan.preparation)
        h.files.listFiles().forEach { h.files.delete(it.relativePath) }
        assertTrue(h.scan(ownership, ids = emptyList()).changes.isEmpty())
        assertFailsWith<SyncError.BindingMismatch> { h.scan(ownership.copy(owner = source)) }
        assertFailsWith<SyncError.BindingMismatch> { h.scan(ownership.copy(root = SyncLibraryRoot("/another"))) }
    }

    @Test fun retainedRawHoldFromPriorAccountSurvivesRestartAndCannotRepairSharedID() {
        val h = ScanHarness()
        val raw = ScanHarness.bytes(extra = "format: 999\n")
        h.put(raw)
        val file = h.mutations.read("a.md")!!
        val rescue = h.mutations.rescue(file, "Conflicts/raw.md", v.device)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(SyncApplyPlan(null, SyncState(h.binding), listOf(rescue, h.mutations.trash(file)))))
        val restarted = ScanHarness(h.rig.restart())
        restarted.put(path = "live.md")
        val retained = restarted.journal.heldRescues(h.binding.root)
        val scan = restarted.scan(retained = retained, ids = emptyList())
        assertTrue("Conflicts/raw.md" in scan.snapshot.heldPaths)
        assertFalse("live.md" in scan.snapshot.heldPaths)
        assertTrue(assertNotNull(scan.preparation).edits.isEmpty())
        assertContentEquals(raw, restarted.files.read("Conflicts/raw.md"))
    }

    @Test fun unavailablePartialAndRacingListingNeverProvideDeleteEvidence() {
        val h = ScanHarness()
        val old = h.state(prompts = mapOf(v.personalID to ScanHarness.record()))
        assertFailsWith<SyncReconciliationError.UnavailableLibrary> {
            SyncLocalScanner.scan(h.binding, old, availability = SyncReconciliationSnapshot.Availability.UNAVAILABLE,
                freshID = { v.device }, mutations = h.mutations)
        }
        h.put()
        h.rig.libraryOperations.inventory = { emptyList() }
        assertFailsWith<LibraryError.Conflict> { h.scan() }
        h.rig.libraryOperations.inventory = { throw StoreError.IOFailure }
        assertFailsWith<StoreError.IOFailure> { h.scan() }
        h.rig.libraryOperations.inventory = null
        h.files.onRead = { path -> h.files.onRead = null; h.put(ScanHarness.bytes("Raced"), path) }
        assertFailsWith<LibraryError.Conflict> { h.scan() }
        assertEquals(old, h.states.snapshot.value)
        assertNull(h.journal.pending)
    }

    @Test fun omittedSymlinkLeafOrParentIsHeldWithoutReadingOrDeleting() {
        for (error in listOf(StoreError.NotRegularFile, StoreError.OutsideRoot)) {
            val h = ScanHarness()
            h.state(prompts = mapOf(v.personalID to ScanHarness.record()))
            h.files.onStamp = { if (it == "a.md") throw error }
            h.files.onRead = { fail("Must not read a rejected link") }
            val scan = h.scan()
            assertTrue(scan.changes.isEmpty())
            assertEquals(SyncIssueCode.LocalVisibility, scan.issues["a.md"])
            assertTrue("a.md" in scan.snapshot.heldPaths)
        }
    }

    @Test fun freshIDsCannotReuseHeldOrRecordedIdentities() {
        val h = ScanHarness()
        h.put(ScanHarness.bytes(id = null), "new.md")
        h.put(ScanHarness.bytes(extra = "format: 999\n"), "held.md")
        assertFailsWith<SyncError.InvalidState> { h.scan(ids = listOf(v.personal)) }
        h.state(prompts = mapOf(v.groupID to ScanHarness.record(ScanHarness.bytes(id = v.groupPrompt), path = "missing.md")))
        assertFailsWith<SyncError.InvalidState> { h.scan(ids = listOf(v.groupPrompt)) }
    }

    @Test fun viewerCannotAssignIDCreateUpdateMoveOrDelete() {
        val h = ScanHarness()
        val groups = ScanHarness.groups(Role.VIEWER)
        h.state(groups)
        h.put(ScanHarness.bytes(id = null), "Groups/Team/idless.md")
        var scan = h.scan(ids = emptyList())
        assertTrue(scan.changes.isEmpty())
        assertEquals(SyncIssueCode.Forbidden, scan.issues["Groups/Team/idless.md"])
        assertTrue(assertNotNull(scan.preparation).edits.isEmpty())
        h.files.delete("Groups/Team/idless.md")
        val canonical = SyncLocalScanner.canonical(ScanHarness.bytes(), "a.md", v.groupScope).bytes
        h.state(groups, mapOf(v.personalID to ScanHarness.record(canonical, v.groupScope)))
        h.put(SyncLocalScanner.canonical(ScanHarness.bytes("Edited"), "a.md", v.groupScope).bytes, "Groups/Team/a.md")
        scan = h.scan(ids = emptyList())
        assertTrue(scan.changes.isEmpty())
        assertEquals(SyncIssueCode.Forbidden, scan.issues["Groups/Team/a.md"])
        h.files.move("Groups/Team/a.md", "private.md")
        assertTrue(h.scan(ids = emptyList()).changes.isEmpty())
        h.files.delete("private.md")
        assertTrue(h.scan(ids = emptyList()).changes.isEmpty())
    }

    @Test fun missingRawRescuePathCannotAuthorizeDelete() {
        val h = ScanHarness()
        h.state(prompts = mapOf(v.personalID to ScanHarness.record(path = "Conflicts/raw.md")))
        val retained = SyncRetainedRescue(java.util.UUID.randomUUID(),
            v.binding(account = v.accountIdentity(userID = v.otherUser)), "Conflicts/raw.md", "original.md", v.hash,
            SyncIssueCode.LocalVisibility, SyncPromptOrigin.Rescued)
        assertTrue(h.scan(retained = listOf(retained), ids = emptyList()).changes.isEmpty())
    }

    @Test fun completeMaximumGroupWrapperKeepsFullWirePath() {
        val h = ScanHarness()
        val folder = "g".repeat(255)
        val path = listOf("a".repeat(255), "b".repeat(255), "c".repeat(255), "d".repeat(251), "a.md").joinToString("/")
        h.state(mapOf(v.group to SyncGroupState("Team", folder, Role.EDITOR)))
        h.put(path = "Groups/$folder/$path")
        val prompt = assertIs<SyncLocalChange.Create>(h.prepare().changes.single()).prompt
        assertEquals(1024, prompt.path.encodeToByteArray().size)
        assertEquals(1287, prompt.file.path.encodeToByteArray().size)
    }
}
