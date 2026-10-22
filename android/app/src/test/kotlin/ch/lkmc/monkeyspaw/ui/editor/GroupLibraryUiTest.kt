@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.ui.editor

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.Role
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.library.*
import ch.lkmc.monkeyspaw.ui.fill.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

internal class GroupLibraryUiTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val applicationScope = CoroutineScope(SupervisorJob() + dispatcher)
    private val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
    private val groupID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAY")!!
    private val promptID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!!
    private val userID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAX")!!
    private val otherGroupID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAW")!!
    private val groupPath = "Groups/Team/a.md"
    private val original = "---\nid: '${promptID.rawValue}'\ntitle: Shared\n---\nOriginal\r\n"

    @BeforeTest fun mainDispatcher() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clearModels() { models.clear(); applicationScope.cancel(); Dispatchers.resetMain() }

    private inner class Rig(role: Role = Role.EDITOR, io: CoroutineDispatcher = dispatcher) {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val files = AndroidStateStore(stateDir.toFile(), isMainThread = { false }, io = JvmCheckedSyncIO())
        val library = library(files, prompts)
        val editing = EditingService(library)
        val states = SyncStateStore(files, files.syncOperations)
        val accounts = SyncAccountStore(files, files.syncOperations)
        val binding = SyncLibraryIdentity(SyncAccountIdentity("https://example.test", userID), SyncLibraryRoot(libraryDir.toString()))
        val identity = PromptIdentity.Assigned(promptID)
        val access: GroupAccessService
        val repository: LibraryRepository
        val editor: EditorViewModel
        val browser: LibraryViewModel

        init {
            put(libraryDir.resolve(groupPath), original.encodeToByteArray())
            states.update(binding) { it.copy(groups = mapOf(groupID to SyncGroupState("Team", "Team", role)),
                prompts = mapOf(identity to SyncPromptState(SyncScopeKey.Group(groupID), "a.md", 1,
                    SyncHash.of(CanonicalForm.group(original.encodeToByteArray(), "a.md").bytes)))) }
            accounts.setAccount(SyncAccount(binding.account, "person", userID, "Android", UUID.randomUUID()))
            access = GroupAccessService(library, states, accounts, libraryDir.toString())
            repository = LibraryRepository(library, editing, prompts, io)
            editor = EditorViewModel(repository, dispatcher, clock, applicationScope)
            browser = LibraryViewModel(repository, dispatcher)
            models.put("editor", editor)
            models.put("browser", browser)
            editor.onSelectionChanged = browser::selectFromEditor
        }

        fun open() = editor.open(LibrarySelection(identity, groupPath))
        fun role(role: Role) = states.update(binding) { it.copy(groups = mapOf(groupID to SyncGroupState("Team", "Team", role))) }
        fun bytes(path: String = groupPath) = Files.readAllBytes(libraryDir.resolve(path))
        fun revision(): HistoryRevision = library.history.snapshot("Previous\r\n".encodeToByteArray(), identity, clock.now())
    }

    @Test fun `access-only downgrade makes dirty editor read-only without losing draft`() = runTest {
        val r = Rig()
        r.open()
        runCurrent()
        r.editor.edit(original + "Mine")
        r.role(Role.VIEWER)
        r.repository.publishProjection()
        runCurrent()
        assertEquals(SourceReadOnlyReason.GROUP_VIEWER, r.editor.state.value.readOnlyReason)
        assertFalse(r.editor.state.value.canEdit)
        assertFalse(r.editor.state.value.canSave)
        assertFalse(r.editor.state.value.canCommand)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        r.role(Role.EDITOR)
        r.repository.publishProjection()
        runCurrent()
        assertTrue(r.editor.state.value.canSave)
        assertEquals(original + "Mine", r.editor.state.value.source)
    }

    @Test fun `save queued before downgrade and upgrade cannot use new authority`() = runTest {
        val held = HeldDispatcher()
        val r = Rig(io = held)
        r.open()
        runCurrent()
        held.releaseAll()
        runCurrent()
        r.editor.edit(original + "Mine")
        r.editor.save()
        runCurrent()
        r.role(Role.VIEWER)
        r.role(Role.EDITOR)
        held.releaseAll()
        runCurrent()
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertTrue(r.editor.state.value.dirty)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertNotNull(r.editor.state.value.failure)
    }

    @Test fun `restore queued before downgrade and upgrade cannot use new authority`() = runTest {
        val held = HeldDispatcher()
        val r = Rig(io = held)
        val revision = r.revision()
        r.open()
        runCurrent(); held.releaseAll(); runCurrent()
        r.editor.restore(revision)
        runCurrent()
        r.role(Role.VIEWER)
        r.role(Role.EDITOR)
        held.releaseAll(); runCurrent()
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertEquals(EditorFailure.ACCESS_CHANGED, r.editor.state.value.failure)
        assertEquals(original, r.editor.state.value.source)
    }

    @Test fun `move queued before downgrade and upgrade cannot use new authority`() = runTest {
        val held = HeldDispatcher()
        val r = Rig(io = held)
        r.open()
        runCurrent(); held.releaseAll(); runCurrent()
        r.editor.move(EditorMoveTarget(null, "Private"))
        runCurrent()
        r.role(Role.VIEWER)
        r.role(Role.EDITOR)
        held.releaseAll(); runCurrent()
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertFalse(Files.exists(libraryDir.resolve("Private/a.md")))
        assertEquals(EditorFailure.ACCESS_CHANGED, r.editor.state.value.failure)
    }

    @Test fun `downgrade invalidates pending dirty restore without discarding draft`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.editor.edit(original + "Mine")
        r.editor.restore(r.revision())
        val decision = checkNotNull(r.editor.state.value.pendingDecision)
        r.role(Role.VIEWER)
        r.repository.publishProjection(); runCurrent()
        assertNull(r.editor.state.value.pendingDecision)
        r.editor.resolveDecision(decision.id, EditorDecision.DISCARD)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertEquals(EditorFailure.ACCESS_CHANGED, r.editor.state.value.failure)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
    }

    @Test fun `viewer favourite is private and dirty editor does not save or conflict`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.editor.edit(original + "Mine")
        r.role(Role.VIEWER)
        r.repository.publishProjection(); runCurrent()
        val row = r.browser.state.value.rows.single()
        assertTrue(row.isReadOnly)
        assertTrue(row.canFavorite)
        assertEquals(Role.VIEWER, row.group?.role)
        val version = r.library.sourceChanges.value
        r.browser.toggleFavorite(row.selection)
        runCurrent()
        assertTrue(r.browser.state.value.rows.single().favorite)
        r.browser.setFilter(LibraryFilter.Favourites); runCurrent()
        assertEquals(1, r.browser.state.value.rows.size)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertEquals(version, r.library.sourceChanges.value)
        assertTrue(r.library.history.revisions(r.identity).isEmpty())
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertNull(r.editor.state.value.conflict)
        assertTrue(r.editor.state.value.dirty)
        r.browser.toggleFavorite(row.selection); runCurrent()
        assertTrue(r.browser.state.value.rows.isEmpty())
        assertTrue(r.states.load(r.binding)!!.favorites.isEmpty())
    }

    @Test fun `viewer Fill and Copy remain usable without changing shared bytes`() = runTest {
        val r = Rig(Role.VIEWER)
        var copied: String? = null
        var reads = 0
        val clipboard = object : Clipboard {
            override fun writeText(text: String) { copied = text }
            override fun readText(completion: (String?) -> Unit) { reads++; completion(null) }
        }
        val fill = FillViewModel(r.repository, FillService(r.library, clipboard) { ZoneId.of("UTC") },
            CopyTextDelivery(clipboard))
        models.put("fill", fill)
        fill.setForeground(true)
        fill.open(groupPath); runCurrent()
        assertTrue(fill.state.value.copyEnabled)
        fill.copy(); runCurrent()
        assertEquals("Original\r\n", copied)
        assertEquals(0, reads)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertTrue(r.library.history.revisions(r.identity).isEmpty())
    }

    @Test fun `dirty downgraded editor saves validated private copy with fresh identity`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.editor.edit(original + "Mine")
        r.role(Role.VIEWER)
        r.repository.publishProjection(); runCurrent()
        assertTrue(r.editor.state.value.canPrivateCopy)
        r.editor.privateCopy("Private/mine.md"); runCurrent()
        val copy = r.library.load("Private/mine.md")
        assertNotEquals(r.identity, copy.identity)
        assertIs<PromptIdentity.Assigned>(copy.identity)
        assertEquals(SyncPromptOrigin.ConflictOf(promptID), copy.syncOrigin)
        assertEquals("Original\r\nMine", copy.document.body)
        assertEquals(PromptAccessState.Local, copy.access)
        assertTrue(r.editor.state.value.canEdit)
        assertFalse(r.editor.state.value.dirty)
        assertEquals("Private/mine.md", r.editor.state.value.relativePath)
        assertEquals(copy.identity, r.browser.state.value.selectedPrompt?.selection?.identity)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertTrue(r.library.history.revisions(r.identity).isEmpty())
    }

    @Test fun `private copy refusals preserve draft and existing destinations`() = runTest {
        val r = Rig(Role.VIEWER)
        r.open(); runCurrent()
        put(libraryDir.resolve("taken.md"), "Occupied".encodeToByteArray())
        val cases = listOf("Groups/Team/new.md" to EditorFailure.INVALID_PATH,
            "gRoUpS/Team/new.md" to EditorFailure.INVALID_PATH,
            "../outside.md" to EditorFailure.INVALID_PATH,
            "taken.md" to EditorFailure.OCCUPIED)
        for ((path, expected) in cases) {
            r.editor.privateCopy(path); runCurrent()
            assertEquals(expected, r.editor.state.value.failure, path)
            assertEquals(original, r.editor.state.value.source)
            assertEquals(groupPath, r.editor.state.value.relativePath)
            assertContentEquals(original.encodeToByteArray(), r.bytes())
        }
        assertEquals("Occupied", r.bytes("taken.md").decodeToString())
        assertFalse(Files.exists(filesDir.resolve("outside.md")))
        r.editor.privateCopy("mine.md"); runCurrent()
        assertNull(r.editor.state.value.failure)
        assertEquals("Original\r\n", r.library.load("mine.md").document.body)
    }

    @Test fun `invalid private-copy draft cannot create a file`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.editor.edit("{{unclosed"); runCurrent()
        r.role(Role.VIEWER)
        r.repository.publishProjection(); runCurrent()
        assertFalse(r.editor.state.value.canPrivateCopy)
        r.editor.privateCopy("mine.md"); runCurrent()
        assertFalse(Files.exists(libraryDir.resolve("mine.md")))
        assertEquals("{{unclosed", r.editor.state.value.source)
        assertTrue(r.editor.state.value.issues.any { it.code == PromptIssueCode.UNBALANCED_OPENER })
    }

    @Test fun `commands queued for shared source cannot act on adopted private copy`() = runTest {
        val held = HeldDispatcher()
        val r = Rig(Role.VIEWER, held)
        r.open(); runCurrent(); held.releaseAll(); runCurrent()
        r.editor.privateCopy("mine.md")
        r.editor.move("Other")
        r.editor.delete()
        runCurrent()
        repeat(5) { held.releaseAll(); runCurrent() }
        assertTrue(Files.exists(libraryDir.resolve("mine.md")))
        assertFalse(Files.exists(libraryDir.resolve("Other/mine.md")))
        assertEquals("mine.md", r.editor.state.value.relativePath)
        assertTrue(r.editor.state.value.queuedActions.isEmpty())
        assertContentEquals(original.encodeToByteArray(), r.bytes())
    }

    @Test fun `group rename follows stable filter selection and dirty editor path`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.browser.setFilter(LibraryFilter.Group(groupID)); runCurrent()
        r.editor.edit(original + "Mine")
        Files.move(libraryDir.resolve("Groups/Team"), libraryDir.resolve("Groups/Renamed"))
        r.states.update(r.binding) { it.copy(groups = mapOf(groupID to SyncGroupState("New team name", "Renamed", Role.EDITOR))) }
        r.repository.refresh(); runCurrent()
        assertEquals(LibraryFilter.Group(groupID), r.browser.state.value.filter)
        assertEquals("New team name", r.browser.state.value.sections.single { it.filter == LibraryFilter.Group(groupID) }.title)
        assertEquals("Groups/Renamed/a.md", r.browser.state.value.selectedPrompt?.selection?.relativePath)
        assertEquals("Groups/Renamed/a.md", r.editor.state.value.relativePath)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertNull(r.editor.state.value.conflict)
        r.editor.save(); runCurrent()
        assertEquals("Original\r\nMine", r.library.load("Groups/Renamed/a.md").document.body)
        assertFalse(Files.exists(libraryDir.resolve(groupPath)))
    }

    @Test fun `group removal drops filter and keeps missing draft available for private copy`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.browser.setFilter(LibraryFilter.Group(groupID)); runCurrent()
        r.editor.edit(original + "Mine")
        Files.delete(libraryDir.resolve(groupPath))
        r.states.update(r.binding) { it.copy(groups = emptyMap(), prompts = emptyMap()) }
        r.repository.refresh(); runCurrent()
        assertEquals(LibraryFilter.All, r.browser.state.value.filter)
        assertNull(r.browser.state.value.selectedPrompt)
        assertTrue(r.editor.state.value.isOpen)
        assertEquals(SourceReadOnlyReason.GROUP_UNAVAILABLE, r.editor.state.value.readOnlyReason)
        assertTrue(r.editor.state.value.conflict?.deleted == true)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertTrue(r.editor.state.value.canPrivateCopy)
        r.editor.privateCopy("kept.md"); runCurrent()
        assertEquals("Original\r\nMine", r.library.load("kept.md").document.body)
        assertFalse(Files.exists(libraryDir.resolve(groupPath)))
    }

    @Test fun `remote rename follows original identity when another prompt takes the old path`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.editor.edit(original + "Mine")
        val movedPath = "Groups/Team/renamed.md"
        Files.move(libraryDir.resolve(groupPath), libraryDir.resolve(movedPath))
        val replacementID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        val replacement = "---\nid: '$replacementID'\n---\nOther prompt"
        put(libraryDir.resolve(groupPath), replacement.encodeToByteArray())
        r.states.update(r.binding) { it.copy(prompts = it.prompts + (r.identity to it.prompts.getValue(r.identity).copy(path = "renamed.md"))) }
        r.repository.refresh(); runCurrent()
        assertEquals(movedPath, r.editor.state.value.relativePath)
        assertEquals(movedPath, r.browser.state.value.selectedPrompt?.selection?.relativePath)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertNull(r.editor.state.value.conflict)
        r.editor.save(); runCurrent()
        assertEquals("Original\r\nMine", r.library.load(movedPath).document.body)
        assertContentEquals(replacement.encodeToByteArray(), r.bytes())
    }

    @Test fun `chooser guards source destination and occupied paths while preserving drafts`() = runTest {
        val r = Rig()
        r.open(); runCurrent()
        r.editor.edit(original + "Mine")
        put(libraryDir.resolve("Private/a.md"), "Occupied".encodeToByteArray())
        r.editor.move(EditorMoveTarget(null, "Private"))
        r.editor.resolveDecision(r.editor.state.value.pendingDecision!!.id, EditorDecision.DISCARD)
        runCurrent()
        assertEquals(EditorFailure.OCCUPIED, r.editor.state.value.failure)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertEquals("Occupied", r.bytes("Private/a.md").decodeToString())
        r.editor.move(EditorMoveTarget(null, "../outside"))
        r.editor.resolveDecision(r.editor.state.value.pendingDecision!!.id, EditorDecision.DISCARD)
        runCurrent()
        assertEquals(EditorFailure.INVALID_PATH, r.editor.state.value.failure)
        assertTrue(r.editor.state.value.dirty)
        r.role(Role.VIEWER)
        r.repository.publishProjection(); runCurrent()
        r.editor.move(EditorMoveTarget(null, "Safe"))
        r.editor.resolveDecision(r.editor.state.value.pendingDecision!!.id, EditorDecision.DISCARD)
        runCurrent()
        assertEquals(EditorFailure.READ_ONLY, r.editor.state.value.failure)
        assertTrue(r.editor.state.value.dirty)
        assertContentEquals(original.encodeToByteArray(), r.bytes())
    }

    @Test fun `new prompt uses editable group and viewer group falls back to private root`() = runTest {
        val r = Rig()
        r.repository.refresh(); runCurrent()
        r.browser.setFilter(LibraryFilter.Group(groupID)); runCurrent()
        assertEquals("Groups/Team", r.browser.newPromptFolder())
        r.editor.createDraft(folder = r.browser.newPromptFolder()); runCurrent()
        assertEquals("Groups/Team/Untitled.md", r.editor.state.value.relativePath)
        assertFalse(Files.exists(libraryDir.resolve("Groups/Team/Untitled.md")))
        r.editor.edit("New group body"); r.editor.save(); runCurrent()
        assertEquals("New group body", r.library.load("Groups/Team/Untitled.md").document.body)
        r.role(Role.VIEWER)
        assertEquals("", r.browser.newPromptFolder(), "Use current access even before the browser refreshes")
        r.browser.setFilter(LibraryFilter.Folder("Groups/Team")); runCurrent()
        assertEquals("", r.browser.newPromptFolder())
        r.editor.createDraft(folder = r.browser.newPromptFolder()); runCurrent()
        assertEquals("Untitled.md", r.editor.state.value.relativePath)
        assertTrue(r.editor.state.value.canEdit)
        assertFalse(Files.exists(libraryDir.resolve("Untitled.md")))
    }

    @Test fun `group destination captured before downgrade cannot save after access changes`() = runTest {
        val r = Rig(Role.OWNER)
        r.repository.refresh(); runCurrent()
        r.browser.setFilter(LibraryFilter.Group(groupID)); runCurrent()
        val folder = r.browser.newPromptFolder()
        r.editor.createDraft(folder = folder); runCurrent()
        r.editor.edit("Keep this draft")
        r.role(Role.VIEWER)
        r.repository.publishProjection(); runCurrent()
        r.editor.save(); runCurrent()
        assertEquals("Groups/Team/Untitled.md", r.editor.state.value.relativePath)
        assertEquals("Keep this draft", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertFalse(r.editor.state.value.canSave)
        assertFalse(Files.exists(libraryDir.resolve("Groups/Team/Untitled.md")))
    }

    @Test fun `Personal writes remain usable with viewer groups and chooser refuses viewer destination`() = runTest {
        val r = Rig(Role.VIEWER)
        r.editor.createDraft("personal.md")
        r.editor.edit("Personal body")
        r.editor.save(); runCurrent()
        assertNull(r.editor.state.value.failure)
        assertTrue(r.editor.state.value.canEdit)
        assertFalse(r.editor.state.value.dirty)
        assertEquals("Personal body", r.library.load("personal.md").document.body)
        assertFalse(r.editor.state.value.destinations.single { it.group?.id == groupID }.canWrite)
        r.editor.move(EditorMoveTarget(groupID, "")); runCurrent()
        assertEquals(EditorFailure.READ_ONLY, r.editor.state.value.failure)
        assertTrue(Files.exists(libraryDir.resolve("personal.md")))
        assertFalse(Files.exists(libraryDir.resolve("Groups/Team/personal.md")))
        r.editor.edit(r.editor.state.value.source + " edited")
        r.editor.save(); runCurrent()
        assertEquals("Personal body edited", r.library.load("personal.md").document.body)
    }

    @Test fun `chooser performs Personal to group between group and back through guarded moves`() = runTest {
        val r = Rig(Role.OWNER)
        r.states.update(r.binding) { it.copy(groups = it.groups + (otherGroupID to SyncGroupState("Other", "Other", Role.EDITOR))) }
        r.editor.createDraft("personal.md"); r.editor.edit("Body"); r.editor.save(); runCurrent()
        val identity = r.editor.state.value.selection!!.identity
        r.editor.move(EditorMoveTarget(groupID, "Nested")); runCurrent()
        assertEquals("Groups/Team/Nested/personal.md", r.editor.state.value.relativePath)
        r.editor.move(EditorMoveTarget(otherGroupID, "")); runCurrent()
        assertEquals("Groups/Other/personal.md", r.editor.state.value.relativePath)
        r.editor.move(EditorMoveTarget(null, "Private")); runCurrent()
        assertEquals("Private/personal.md", r.editor.state.value.relativePath)
        assertEquals(identity, r.editor.state.value.selection?.identity)
        assertEquals("Body", r.library.load("Private/personal.md").document.body)
        assertNull(r.editor.state.value.failure)
    }

    @Test fun `changed recorded server ownership invalidates queued write despite writable path`() = runTest {
        val held = HeldDispatcher()
        val r = Rig(io = held)
        r.open(); runCurrent(); held.releaseAll(); runCurrent()
        r.editor.edit(original + "Mine"); r.editor.save(); runCurrent()
        r.states.update(r.binding) { it.copy(groups = it.groups + (otherGroupID to SyncGroupState("Other", "Other", Role.VIEWER)),
            prompts = mapOf(r.identity to it.prompts.getValue(r.identity).copy(scope = SyncScopeKey.Group(otherGroupID)))) }
        held.releaseAll(); runCurrent()
        assertContentEquals(original.encodeToByteArray(), r.bytes())
        assertEquals(SourceReadOnlyReason.GROUP_VIEWER, r.editor.state.value.readOnlyReason)
        assertEquals(Role.VIEWER, r.editor.state.value.group?.role)
        assertEquals(otherGroupID, r.editor.state.value.group?.id)
        assertEquals(original + "Mine", r.editor.state.value.source)
        assertTrue(r.editor.state.value.dirty)
        assertEquals(EditorFailure.ACCESS_CHANGED, r.editor.state.value.failure)
    }

    @Test fun `group sections include empty memberships and conflict filter uses typed private markers anywhere`() = runTest {
        val r = Rig(Role.VIEWER)
        r.states.update(r.binding) { it.copy(groups = it.groups + (otherGroupID to SyncGroupState("Empty", "Empty", Role.OWNER))) }
        val copyID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        put(libraryDir.resolve("Elsewhere/copy.md"), "---\nid: '$copyID'\nx-monkeyspaw-conflict-of: '${promptID.rawValue}'\n---\nMine".encodeToByteArray())
        put(libraryDir.resolve("rescued.md"), "---\nx-monkeyspaw-rescued: true\n---\nRescue".encodeToByteArray())
        put(libraryDir.resolve("Conflicts/name (conflict device).md"), "Ordinary".encodeToByteArray())
        put(libraryDir.resolve("bad.md"), "---\nx-monkeyspaw-conflict-of: bad\n---\nInvalid marker".encodeToByteArray())
        put(libraryDir.resolve("both.md"), "---\nx-monkeyspaw-conflict-of: '${promptID.rawValue}'\nx-monkeyspaw-rescued: true\n---\nInvalid pair".encodeToByteArray())
        put(libraryDir.resolve("self.md"), "---\nid: '$copyID'\nx-monkeyspaw-conflict-of: '$copyID'\n---\nInvalid self".encodeToByteArray())
        put(libraryDir.resolve("Groups/Team/marked.md"), "---\nx-monkeyspaw-rescued: true\n---\nGroup metadata".encodeToByteArray())
        r.repository.refresh(); runCurrent()
        val sections = r.browser.state.value.sections
        assertEquals(0, sections.single { it.filter == LibraryFilter.Group(otherGroupID) }.count)
        assertEquals(2, sections.single { it.filter == LibraryFilter.Group(groupID) }.count)
        assertEquals(2, sections.single { it.filter == LibraryFilter.Conflicts }.count)
        r.browser.setFilter(LibraryFilter.Conflicts); runCurrent()
        assertEquals(setOf("Elsewhere/copy.md", "rescued.md"), r.browser.state.value.rows.map { it.selection.relativePath }.toSet())
        assertEquals(SyncPromptOrigin.ConflictOf(promptID), r.browser.state.value.rows.single { it.selection.relativePath == "Elsewhere/copy.md" }.syncOrigin)
        r.browser.setQuery("nothing"); runCurrent()
        assertTrue(r.browser.state.value.rows.isEmpty())
        assertEquals(2, r.browser.state.value.sections.single { it.filter == LibraryFilter.Conflicts }.count)
    }

    private class HeldDispatcher : CoroutineDispatcher() {
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.addLast(block) }
        fun releaseAll() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }
}
