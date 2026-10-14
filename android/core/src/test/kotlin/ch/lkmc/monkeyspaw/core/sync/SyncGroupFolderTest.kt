package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.time.Instant
import kotlin.test.*

class SyncGroupFolderTest {
    @Test fun reservedPreflightIncludesEmptyCaseVariantsAndLooseRegularRoots() {
        for (path in listOf("Groups", "Conflicts", "GROUPS", "conflicts")) {
            val h = GroupFolderHarness()
            h.rig.libraryOperations.putDirectory(path)
            val error = assertFailsWith<SyncGroupFolderError.ReservedFolders> { SyncGroupFolders.preflight(h.inventory(), null) }
            assertEquals(listOf(path), error.paths)
            SyncGroupFolders.preflight(h.inventory(), SyncLibraryBinding(h.binding.root, h.binding.account))
        }
        val h = GroupFolderHarness()
        h.put("keep".encodeToByteArray(), "Groups")
        assertEquals(listOf("Groups"), assertFailsWith<SyncGroupFolderError.ReservedFolders> {
            SyncGroupFolders.preflight(h.inventory(), null)
        }.paths)
        assertEquals("keep", h.files.text("Groups"))
    }

    @Test fun allocationsSanitizeNormalizeFoldAndSurviveRestartWithoutCreatingDirectories() {
        val h = GroupFolderHarness()
        val names = listOf("A/B", "A\\B", "Straße", "STRASSE", "Cafe\u0301", "Café", "---_..", "\u001f")
        val members = names.mapIndexed { index, name -> h.member(name, folderID(index + 10)) }
        val plan = SyncGroupFolders.update(members.reversed(), null, null, h.inventory(), h.mutations)
        assertEquals(listOf("A-B", "A-B (2)", "Straße", "STRASSE (2)", "Café", "Café (2)", "Group", "Group (2)"),
            (10..17).map { plan.nextState.groups[folderID(it)]!!.folder })
        assertTrue(plan.directories.all { it.kind == SyncDirectoryEdit.Kind.RESERVE })
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertTrue(h.mutations.directoryIdentities().isEmpty())
        val restarted = GroupFolderHarness(h.rig.restart())
        val repeat = SyncGroupFolders.update(members, restarted.state(), restarted.ownership(), restarted.inventory(), restarted.mutations)
        assertEquals(plan.nextState, repeat.nextState)
        assertNull(repeat.bindingChange)
        assertTrue(repeat.edits.isEmpty())
        assertTrue(repeat.directories.isEmpty())
    }

    @Test fun suffixesReserveActualBytesBeyondTwentyAndKeepGraphemesWhole() {
        val occupied = mutableListOf<String>()
        for (number in 1..35) {
            val folder = SyncNaming.groupFolder("界".repeat(85), occupied)
            assertTrue(folder.encodeToByteArray().size <= Limits.syncPathSegmentMaxBytes)
            if (number > 1) assertTrue(folder.endsWith(" ($number)"))
            SyncIdentifiers.folder(folder)
            occupied.add(folder)
        }
        val base = "a".repeat(251)
        assertEquals(base + " (3)", SyncNaming.groupFolder(base + " (2)", listOf(base + " (2)")))
        assertEquals(base + " (4)", SyncNaming.groupFolder(base + " (2)", listOf(base + " (2)", base + " (3)")))
        val emoji = "👩🏽"
        val folder = SyncNaming.groupFolder(emoji.repeat(100), emptyList())
        assertEquals(emoji.repeat(31), folder)
        assertEquals("I (2)", SyncNaming.groupFolder("I", listOf("i")))
        assertEquals("İ", SyncNaming.groupFolder("İ", listOf("i")))
    }

    @Test fun occupiedUnownedEmptyFoldersFilesAndCaseDriftedRootChildrenAreNeverAdopted() {
        val h = GroupFolderHarness()
        val owned = h.seed(groups = emptyMap())
        h.rig.libraryOperations.putDirectory("Groups/Team")
        h.rig.libraryOperations.putDirectory("groups/Beta")
        h.put("unknown".encodeToByteArray(), "Groups/Other")
        val plan = SyncGroupFolders.update(listOf(h.member(), h.member("Other", folderID(20)), h.member("Beta", folderID(21))),
            h.state(), owned, h.inventory(), h.mutations)
        assertEquals("Team (2)", plan.nextState.groups[h.group]!!.folder)
        assertEquals("Other (2)", plan.nextState.groups[folderID(20)]!!.folder)
        assertEquals("Beta (2)", plan.nextState.groups[folderID(21)]!!.folder)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertEquals("unknown", h.files.text("Groups/Other"))
        assertNotNull(h.rig.libraryOperations.directoryIdentity("Groups/Team"))
    }

    @Test fun renamePreservesUnknownSubtreeMigratesIdlessKeysAndHoldsAndKeepsScopeRelativePaths() {
        val h = GroupFolderHarness()
        val source = "Groups/Alpha/sub/idless.md"
        val target = "Groups/Beta/sub/idless.md"
        h.put("{{name}}".encodeToByteArray(), source)
        val raw = byteArrayOf(-1, 0, 13, 10)
        h.put(raw, "Groups/Alpha/.hidden/_raw.bin")
        val oldKey = PromptIdentity.at(source)
        val newKey = PromptIdentity.at(target)
        h.rig.local.values.record(oldKey, mapOf("name" to "remembered"))
        h.rig.local.usage.recordUse(oldKey)
        h.rig.local.history.snapshot("previous".encodeToByteArray(), oldKey, h.date)
        val record = SyncPromptState(h.scope, "sub/idless.md", 0)
        val owned = h.seed(groups = mapOf(h.group to SyncGroupState("Alpha", "alpha", Role.EDITOR)),
            prompts = mapOf(oldKey to record), holds = listOf(SyncHeldPrompt(oldKey, source, h.binding.account, SyncHash.of("{{name}}".encodeToByteArray()))))
        val old = h.state()
        val plan = SyncGroupFolders.update(listOf(h.member("Beta", role = Role.VIEWER)), old, owned, h.inventory(), h.mutations)
        assertEquals("Groups/Alpha", plan.directories.single().source)
        assertEquals(old.cursors, plan.nextState.cursors)
        assertEquals(old.databaseID, plan.nextState.databaseID)
        assertEquals(record, plan.nextState.prompts[newKey])
        assertNull(plan.nextState.prompts[oldKey])
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertEquals("{{name}}", h.files.text(target))
        assertContentEquals(raw, h.files.read("Groups/Beta/.hidden/_raw.bin"))
        assertEquals(mapOf("name" to "remembered"), h.rig.local.values.rememberedValues(newKey))
        assertTrue(h.rig.local.values.rememberedValues(oldKey).isEmpty())
        assertEquals(1, h.rig.local.usage.useEvents(newKey).size)
        assertEquals(1, h.rig.local.history.revisions(newKey).size)
        assertEquals(target, h.ownership().holds.single().path)
        assertEquals(newKey, h.ownership().holds.single().identity)
        assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes[target])
        assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes["Groups/Beta/.hidden/_raw.bin"])
    }

    @Test fun containmentUsesFullFoldAndRelocationRetainsSuffixAcrossFoldLengthChanges() {
        assertTrue(SyncGroupFolders.contains("Groups/STRASSE/sub/A.md", "Groups/Straße"))
        assertFalse(SyncGroupFolders.contains("Groups/Team2/A.md", "Groups/Team"))
        assertEquals("Groups/New/sub/e\u0301.md", SyncGroupFolders.relocated("Groups/STRASSE/sub/e\u0301.md", "Groups/Straße", "Groups/New"))
        val h = GroupFolderHarness()
        h.put("idless".encodeToByteArray(), "Groups/STRASSE/A.md")
        val owned = h.seed(groups = mapOf(h.group to SyncGroupState("Straße", "Straße", Role.EDITOR)))
        val plan = SyncGroupFolders.update(listOf(h.member("New")), h.state(), owned, h.inventory(), h.mutations)
        assertEquals("Groups/STRASSE", plan.directories.single().source)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertEquals("idless", h.files.text("Groups/New/A.md"))
    }

    @Test fun caseOnlyRenameReplaysStableIntermediateAndRejectsReplacementIncarnation() {
        val h = GroupFolderHarness()
        val bytes = h.bytes("keep")
        h.put(bytes, "Groups/Team/A.md")
        val owned = h.seed()
        val plan = SyncGroupFolders.update(listOf(h.member("TEAM")), h.state(), owned, h.inventory(), h.mutations)
        val edit = plan.directories.single()
        val temporary = assertNotNull(edit.intermediate)
        h.rig.libraryOperations.onOperation = { name ->
            if (name == "rename-directory:$temporary") throw SyncFileOperationError(SyncFileFailureCode.IO_FAILURE)
        }
        assertFailsWith<SyncFileOperationError> { h.journal.apply(plan) }
        assertContentEquals(bytes, h.files.read("$temporary/A.md"))
        assertEquals("Team", h.state().groups[h.group]!!.folder)
        assertFailsWith<LibraryError.RecoveryRequired> { h.journal.replan(SyncApplyPlan(plan.expectedState, plan.nextState, emptyList())) }
        h.rig.libraryOperations.onOperation = null
        val restarted = GroupFolderHarness(h.rig.restart())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertContentEquals(bytes, restarted.files.read("Groups/TEAM/A.md"))
        assertEquals(edit.identity, restarted.rig.libraryOperations.directoryIdentity("Groups/TEAM"))
        assertNull(restarted.rig.libraryOperations.directoryIdentity(temporary))
    }

    @Test fun roleChangesRemodeEveryRegularFileWithoutRewritingAndViewerReplacementReplayRemodesAgain() {
        val h = GroupFolderHarness()
        val samples = mapOf("A.md" to h.bytes(), "future.md" to "---\nformat: 999\n---\nFuture".encodeToByteArray(), "_raw.bin" to byteArrayOf(-1, 0))
        samples.forEach { (name, bytes) -> h.put(bytes, "Groups/Team/$name") }
        h.seed()
        for (role in listOf(Role.VIEWER, Role.EDITOR, Role.VIEWER, Role.OWNER)) {
            val plan = SyncGroupFolders.update(listOf(h.member(role = role)), h.state(), h.ownership(), h.inventory(), h.mutations)
            assertEquals(samples.size, plan.edits.size)
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            samples.forEach { (name, bytes) ->
                assertContentEquals(bytes, h.files.read("Groups/Team/$name"))
                assertEquals(if (role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL, h.rig.libraryOperations.modes["Groups/Team/$name"])
            }
        }
        h.journal.apply(SyncGroupFolders.update(listOf(h.member(role = Role.VIEWER)), h.state(), h.ownership(), h.inventory(), h.mutations))
        val file = h.mutations.read("Groups/Team/A.md")!!
        val edit = h.mutations.publication(h.bytes("replacement"), file.path, file, SyncIdentityTransition(file.identity, file.identity),
            SyncGroupFolders.mode(h.scope, h.state().groups))
        h.rig.libraryOperations.onOperation = { if (it.startsWith("publish-file-flush:")) h.rig.libraryOperations.failAt = h.rig.libraryOperations.calls.size }
        assertFails { h.journal.apply(SyncApplyPlan(h.state(), h.state(), listOf(edit))) }
        h.rig.libraryOperations.onOperation = null
        h.rig.libraryOperations.failAt = null
        h.rig.libraryOperations.modes[file.path] = SyncFileMode.NORMAL
        assertEquals(SyncApplyOutcome.Committed, h.journal.replay())
        assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes[file.path])
        assertContentEquals(edit.bytes, h.files.read(file.path))
    }

    @Test fun allocationAndRenameRecheckLateUnownedOccupationBeforeOwnershipCommit() {
        for (rename in listOf(false, true)) {
            val h = GroupFolderHarness()
            if (rename) h.put(h.bytes(), "Groups/Team/A.md")
            val owned = h.seed(groups = if (rename) h.groups() else emptyMap())
            val old = h.state()
            val plan = SyncGroupFolders.update(listOf(h.member("New")), old, owned, h.inventory(), h.mutations)
            h.rig.libraryOperations.putDirectory("Groups/New")
            assertIs<SyncApplyOutcome.ReplanAsConflict>(h.journal.apply(plan))
            assertEquals(old, h.state())
            assertEquals(owned, h.ownership())
            assertNotNull(h.rig.libraryOperations.directoryIdentity("Groups/New"))
            if (rename) assertContentEquals(h.bytes(), h.files.read("Groups/Team/A.md"))
        }
    }

    @Test fun committedReservationToleratesArrivalsWhileJournalDeletionIsUncertain() {
        val h = GroupFolderHarness()
        val owned = h.seed(groups = emptyMap())
        val plan = SyncGroupFolders.update(listOf(h.member()), h.state(), owned, h.inventory(), h.mutations)
        h.rig.local.state.fault = { op, path -> if (op == MemoryStore.Operation.DELETE && path == "sync/apply.json") StoreError.IOFailure else null }
        assertFails { h.journal.apply(plan) }
        h.put("arrived".encodeToByteArray(), "Groups/Team/arrived.bin")
        h.rig.local.state.fault = null
        val restarted = GroupFolderHarness(h.rig.restart())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertEquals("arrived", restarted.files.text("Groups/Team/arrived.bin"))
        assertEquals(plan.nextState, restarted.state())
    }

    @Test fun invalidUnavailableDuplicateAndForeignInventoriesFailBeforeMutation() {
        val h = GroupFolderHarness()
        val file = h.put(h.bytes(), "a.md")
        val inventory = h.inventory()
        val unavailable = SyncGroupFolderInventory(SyncReconciliationSnapshot(h.binding, listOf(file), SyncReconciliationSnapshot.Availability.UNAVAILABLE), emptyMap())
        assertFailsWith<SyncReconciliationError.UnavailableLibrary> { SyncGroupFolders.preflight(unavailable, null) }
        val duplicate = SyncGroupFolderInventory(SyncReconciliationSnapshot(h.binding, listOf(file, file)), emptyMap())
        assertFailsWith<SyncGroupFolderError.InvalidInventory> { SyncGroupFolders.preflight(duplicate, null) }
        val foreign = SyncLibraryBinding(h.binding.root, SyncTestValues.accountIdentity(userID = SyncTestValues.otherUser))
        assertFailsWith<SyncError.BindingMismatch> { SyncGroupFolders.update(emptyList(), null, foreign, inventory, h.mutations) }
        assertFailsWith<SyncError.InvalidState> { SyncGroupFolders.update(listOf(h.member(), h.member()), null, null, inventory, h.mutations) }
        assertEquals(SyncFileMode.NORMAL, SyncGroupFolders.mode(SyncTestValues.userScope, emptyMap()))
        assertFailsWith<SyncError.InvalidScope> { SyncGroupFolders.mode(h.scope, emptyMap()) }
        assertNull(h.rig.local.state.stamp("sync/apply.json"))
    }
}

internal fun folderID(number: Int): ULID = SyncIdentifiers.ulid(number.toString().padStart(26, '0'))
internal fun folderIDs(first: Int = 100): () -> ULID { var next = first; return { folderID(next++) } }

internal class GroupFolderHarness(val rig: SyncJournalHarness = SyncJournalHarness(seed = false)) {
    val group = SyncTestValues.group
    val scope = SyncTestValues.groupScope
    val binding get() = rig.binding
    val files get() = rig.local.prompts
    val mutations get() = rig.mutations
    val journal get() = rig.journal
    val date = Instant.ofEpochSecond(1_791_936_000)
    fun bytes(body: String = "body", id: ULID = SyncTestValues.personal) = SyncJournalHarness.source(body, id.rawValue).encodeToByteArray()
    fun put(bytes: ByteArray, path: String): SyncLibraryFile { files.put(bytes, path); return mutations.read(path)!! }
    fun groups(role: Role = Role.EDITOR) = mapOf(group to SyncGroupState("Team", "Team", role))
    fun member(name: String = "Team", id: ULID = group, role: Role = Role.EDITOR) = GroupMembership(id.rawValue, name, role)
    fun record(path: String, bytes: ByteArray) = SyncPromptState(scope, path, 1, SyncHash(SyncLocalScanner.canonical(bytes, path, scope).canonicalHash))
    fun state(): SyncState = rig.states.load(binding)!!
    fun ownership(): SyncLibraryBinding = rig.accounts.binding(binding.root)!!
    fun seed(groups: Map<ULID, SyncGroupState> = groups(), prompts: Map<PromptIdentity, SyncPromptState> = emptyMap(),
             favorites: Map<PromptIdentity, Boolean> = emptyMap(), holds: List<SyncHeldPrompt> = emptyList()): SyncLibraryBinding {
        val cursors = mapOf(SyncTestValues.userScope to "private cursor") + groups.keys.associate { SyncScopeKey.Group(it) to "group cursor" }
        rig.states.update(binding) { SyncState(binding, SyncTestValues.uuid, cursors, groups, prompts, favorites) }
        val owned = SyncLibraryBinding(binding.root, binding.account, groups.mapValues { SyncManagedFolder(binding.account, it.value.folder) }, holds)
        rig.accounts.updateBinding(binding.root) { owned }
        return owned
    }
    fun inventory(held: Set<String> = emptySet()) = SyncGroupFolders.inventory(binding, SyncReconciliationSnapshot.Availability.AVAILABLE, held, mutations)
    fun scan(state: SyncState? = state(), ownership: SyncLibraryBinding = ownership(), account: SyncAccountIdentity = binding.account) =
        SyncLocalScanner.scan(SyncLibraryIdentity(account, binding.root), state, ownership, journal.heldRescues(binding.root),
            SyncReconciliationSnapshot.Availability.AVAILABLE, freshID = folderIDs(300), mutations = mutations)
}
