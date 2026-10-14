package ch.lkmc.monkeyspaw.ui.editor

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneId
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class EditorViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
    private lateinit var repository: LibraryRepository
    private var modelCount = 0

    @BeforeTest
    fun setMain() { Dispatchers.setMain(dispatcher) }

    @AfterTest
    fun clearModels() { models.clear(); Dispatchers.resetMain() }

    private fun model(wrap: (PromptStore) -> PromptStore = { it },
        state: StateStore = AndroidStateStore(stateDir.toFile()),
        io: CoroutineDispatcher = dispatcher, worker: CoroutineDispatcher = dispatcher): EditorViewModel {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val library = library(state, wrap(prompts))
        repository = LibraryRepository(library, EditingService(library), prompts, io)
        return EditorViewModel(repository, worker, clock).also { models.put("editor-${modelCount++}", it) }
    }

    private fun open(model: EditorViewModel, path: String = "a.md") {
        model.open(LibrarySelection(PromptIdentity.at(path), path))
    }

    private fun decide(model: EditorViewModel, decision: EditorDecision) {
        model.resolveDecision(checkNotNull(model.state.value.pendingDecision).id, decision)
    }

    private fun bytes(path: String = "a.md") = Files.readAllBytes(libraryDir.resolve(path))
    private fun sourceIs(model: EditorViewModel, expected: String) = assertTrue(model.state.value.source == expected, "Draft source differs.")
    private fun bytesAre(expected: ByteArray, path: String = "a.md") = assertTrue(bytes(path).contentEquals(expected), "Disk bytes differ.")

    @Test
    fun `create commits exact body and unknown metadata before publishing index and favourite`() = runTest {
        val model = model()
        model.createDraft("Notes/new.md")
        val draft = "---\ntitle: Example\nfavorite: true\nmodel:\n  provider: custom\n  options: [one, two]\n---\n  Unicode e\u0301 {{x}}\r\n\r\n"
        model.edit(draft)
        model.save()
        model.save()
        assertTrue(model.state.value.writing)
        assertTrue(repository.state.value.snapshot.prompts.isEmpty())
        assertFalse(Files.exists(libraryDir.resolve("Notes/new.md")))
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertIs<PromptIdentity.Assigned>(model.state.value.selection?.identity)
        val entry = repository.state.value.snapshot.prompts.single().entry
        assertTrue(entry.document.frontMatter.favorite)
        assertTrue(entry.document.source.contains("model:\n  provider: custom\n  options:\n  - one\n  - two\n"))
        assertTrue(entry.document.body == "  Unicode e\u0301 {{x}}\r\n\r\n", "Body changed.")
        bytesAre(checkNotNull(model.state.value.source).encodeToByteArray(), "Notes/new.md")
        assertNull(model.state.value.failure)
        assertFalse(Files.exists(stateDir.resolve("values.json")))
        assertTrue(repository.state.value.snapshot.prompts.single().useEvents.isEmpty())
    }

    @Test
    fun `edit rename and move preserve title unknown keys and exact body across restart`() = runTest {
        val original = "---\ntitle: Keep title\nmodel: retained\n---\nBody\r\n"
        put(libraryDir.resolve("a.md"), original.encodeToByteArray())
        val model = model()
        open(model)
        runCurrent()
        model.edit(original.replace("Body", "  Edited e\u0301"))
        model.save()
        runCurrent()
        val committed = bytes()
        val identity = checkNotNull(model.state.value.selection).identity
        model.rename("renamed.md")
        runCurrent()
        bytesAre(committed, "renamed.md")
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
        model.move("Nested/新")
        runCurrent()
        bytesAre(committed, "Nested/新/renamed.md")
        assertEquals(identity, model.state.value.selection?.identity)
        assertEquals("Keep title", model.state.value.title)
        val restarted = library()
        val loaded = restarted.loadForEditing("Nested/新/renamed.md")
        assertEquals(identity, loaded.entry.identity)
        assertTrue(loaded.entry.document.body == "  Edited e\u0301\r\n", "Body changed.")
        assertTrue(loaded.entry.document.source.contains("model: retained"))
        assertEquals(1, restarted.history.revisions(identity).size)
        assertTrue(restarted.history.read(restarted.history.revisions(identity).single()).contentEquals(original.encodeToByteArray()))
    }

    @Test
    fun `idless rename and move retain raw bytes and migrate keyed state`() = runTest {
        val original = "Exact plain e\u0301\r\n"
        put(libraryDir.resolve("a.md"), original.encodeToByteArray())
        val model = model()
        open(model)
        runCurrent()
        val local = checkNotNull(model.state.value.selection).identity
        repository.withLibrary { library, _ ->
            library.values.record(local, mapOf("x" to "remembered"))
            library.usage.recordUse(local)
        }
        model.rename("é.md")
        runCurrent()
        model.move("e\u0301/sub")
        runCurrent()
        val destination = "e\u0301/sub/é.md"
        val current = checkNotNull(model.state.value.selection).identity
        assertIs<PromptIdentity.Local>(current)
        assertNotEquals(local, current)
        bytesAre(original.encodeToByteArray(), destination)
        repository.withLibrary { library, _ ->
            assertEquals(mapOf("x" to "remembered"), library.values.rememberedValues(current))
            assertTrue(library.values.rememberedValues(local).isEmpty())
            assertEquals(1, library.usage.useEvents(current).size)
            assertTrue(library.usage.useEvents(local).isEmpty())
        }
    }

    @Test
    fun `restore previews without applying then restores pre-id bytes and refreshes history`() = runTest {
        val original = "Old body\r\n\r\n"
        put(libraryDir.resolve("a.md"), original.encodeToByteArray())
        val model = model()
        open(model)
        runCurrent()
        model.edit("New body")
        model.save()
        runCurrent()
        val identity = model.state.value.selection?.identity
        val before = checkNotNull(model.state.value.source)
        model.setTab(EditorTab.HISTORY)
        runCurrent()
        val revision = model.state.value.history.revisions.single()
        assertTrue(revision.canRestore)
        assertTrue(revision.source == original, "History source changed.")
        model.selectRevision(revision.revision)
        sourceIs(model, before)
        bytesAre(before.encodeToByteArray())
        model.restore(revision.revision)
        runCurrent()
        assertEquals(identity, model.state.value.selection?.identity)
        assertFalse(model.state.value.dirty)
        assertEquals(2, model.state.value.history.revisions.size)
        assertEquals(revision.revision, model.state.value.history.selected)
        val restored = library().load("a.md")
        assertTrue(restored.document.body == original, "Restored body changed.")
    }

    @Test
    fun `live validation remains editable for repairable errors and typed future drafts`() = runTest {
        val broken = "---\ntitle: [broken\n---\n{{new}}"
        put(libraryDir.resolve("a.md"), broken.encodeToByteArray())
        val model = model()
        open(model)
        runCurrent()
        assertNull(model.state.value.readOnlyReason)
        assertTrue(model.state.value.canEdit)
        assertTrue(model.state.value.issues.any { it.code == PromptIssueCode.INVALID_YAML })
        assertEquals(listOf("new"), model.state.value.fields.map { it.name })
        assertFalse(model.state.value.previewAvailable)
        model.edit("{{unclosed")
        model.save()
        runCurrent()
        assertEquals(EditorFailure.INVALID, model.state.value.failure)
        assertTrue(model.state.value.issues.any { it.code == PromptIssueCode.UNBALANCED_OPENER })
        bytesAre(broken.encodeToByteArray())
        model.edit("---\nformat: 99999999999999999999\n---\nFuture draft")
        runCurrent()
        assertNull(model.state.value.readOnlyReason)
        assertTrue(model.state.value.canEdit)
        assertFalse(model.state.value.previewAvailable)
        model.edit("Fixed {{name}}")
        model.save()
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertTrue(model.state.value.issues.isEmpty())
        assertEquals(1, library().history.revisions(checkNotNull(model.state.value.selection).identity).size)
    }

    @Test
    fun `future invalid UTF8 and oversized files remain read-only with original bytes`() = runTest {
        val cases = listOf(
            "---\nformat: 999999999999999999999\ncustom: retained\n---\nExact\r\n".encodeToByteArray() to SourceReadOnlyReason.FUTURE_FORMAT,
            byteArrayOf(0xff.toByte(), 0xfe.toByte()) to SourceReadOnlyReason.INVALID_UTF8,
            ByteArray(Limits.maxPromptBytes + 1) { 65 } to SourceReadOnlyReason.SOURCE_TOO_LARGE,
        )
        for ((index, fixture) in cases.withIndex()) {
            val path = "readonly-$index.md"
            put(libraryDir.resolve(path), fixture.first)
            var mutations = 0
            val model = model(wrap = { prompts -> object : PromptStore by prompts {
                override fun write(bytes: ByteArray, path: String) { mutations++; prompts.write(bytes, path) }
                override fun move(source: String, destination: String) { mutations++; prompts.move(source, destination) }
                override fun delete(path: String) { mutations++; prompts.delete(path) }
            } })
            open(model, path)
            runCurrent()
            assertEquals(fixture.second, model.state.value.readOnlyReason)
            assertFalse(model.state.value.canEdit)
            assertFalse(model.state.value.canSave)
            if (fixture.second != SourceReadOnlyReason.FUTURE_FORMAT) assertNull(model.state.value.source)
            val original = model.state.value.source
            model.edit("Replacement")
            model.save()
            model.rename("different.md")
            model.move("Folder")
            model.delete()
            runCurrent()
            assertTrue(model.state.value.source == original, "Read-only draft changed.")
            bytesAre(fixture.first, path)
            assertEquals(0, mutations)
        }
    }

    @Test
    fun `preview uses defaults markers strict local dates and one-pass tokens without delivery`() {
        val source = "---\nfields:\n  unused:\n    description: Kept\n  a:\n    default: '{{clipboard}}'\n  choice:\n    type: choice\n    options: [one, two]\n  detail:\n    type: multiline\n    optional: true\n    remember: false\n---\n{{detail}} {{a}} {{choice}} {{missing}} {{date}} {{time}} {{clipboard}} \\{{literal}} {{#if x}}"
        val state = projectEditor(PromptCodec.parse(source, "a.md"), Instant.EPOCH, ZoneId.of("Asia/Kolkata"))
        assertEquals(listOf("detail", "a", "choice", "missing", "unused"), state.fields.map { it.name })
        assertTrue(state.fields[3].isImplicit)
        assertEquals(FieldKind.MULTILINE, state.fields.first().kind)
        assertTrue(state.fields.first().optional)
        assertFalse(state.fields.first().remember)
        assertTrue(state.preview == "{detail} {{clipboard}} {choice} {missing} 1970-01-01 05:30 {clipboard} {{literal}} {{#if x}}", "Preview differs.")
        assertTrue(state.previewAvailable)
        assertEquals(listOf(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNUSED_FIELD), state.issues.map { it.code })
    }

    @Test
    fun `failed save keeps draft stamp pending decision index and favourite unchanged until retry commits`() = runTest {
        val original = "---\nmodel: retained\n---\nOriginal"
        put(libraryDir.resolve("a.md"), original.encodeToByteArray())
        var fail = true
        var writes = 0
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) {
                writes++
                if (fail) throw StoreError.IOFailure
                prompts.write(bytes, path)
            }
        } })
        open(model)
        runCurrent()
        val oldStamp = model.state.value.stamp
        val oldVersion = repository.state.value.snapshot.version
        val draft = "---\nfavorite: true\nmodel: retained\n---\nMine"
        model.edit(draft)
        model.close()
        val decision = checkNotNull(model.state.value.pendingDecision)
        decide(model, EditorDecision.SAVE)
        decide(model, EditorDecision.DISCARD)
        runCurrent()
        assertEquals(decision, model.state.value.pendingDecision)
        sourceIs(model, draft)
        assertTrue(model.state.value.dirty)
        assertEquals(oldStamp, model.state.value.stamp)
        assertEquals(EditorFailure.DATA, model.state.value.failure)
        assertEquals(1, writes)
        bytesAre(original.encodeToByteArray())
        assertEquals(oldVersion, repository.state.value.snapshot.version)
        assertFalse(repository.state.value.snapshot.prompts.single().entry.document.frontMatter.favorite)
        fail = false
        decide(model, EditorDecision.SAVE)
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertTrue(repository.state.value.snapshot.prompts.single().entry.document.frontMatter.favorite)
        assertEquals(2, writes)
    }

    @Test
    fun `every destructive action uses Cancel without changing draft or selection`() = runTest {
        put(libraryDir.resolve("a.md"))
        put(libraryDir.resolve("b.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        val selection = model.state.value.selection
        val revision = HistoryRevision(checkNotNull(selection).identity, "20261014T000000.000Z-000000.md", clock.now())
        val actions: List<() -> Unit> = listOf(
            { model.open(LibrarySelection(PromptIdentity.at("b.md"), "b.md")) }, { model.close() },
            { model.createDraft() }, { model.reload() }, { model.rename("c.md") }, { model.move("Folder") },
            { model.delete() }, { model.restore(revision) },
        )
        for (action in actions) {
            action()
            assertNotNull(model.state.value.pendingDecision)
            decide(model, EditorDecision.CANCEL)
            runCurrent()
            assertEquals(selection, model.state.value.selection)
            sourceIs(model, "Mine")
            assertTrue(model.state.value.dirty)
            assertNull(model.state.value.pendingDecision)
        }
        bytesAre("body".encodeToByteArray())
    }

    @Test
    fun `Save and Discard navigation guard approve only the captured decision`() = runTest {
        put(libraryDir.resolve("a.md"))
        put(libraryDir.resolve("b.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        model.close()
        val old = checkNotNull(model.state.value.pendingDecision)
        decide(model, EditorDecision.CANCEL)
        model.open(LibrarySelection(PromptIdentity.at("b.md"), "b.md"))
        val next = checkNotNull(model.state.value.pendingDecision)
        assertNotEquals(old.id, next.id)
        model.resolveDecision(old.id, EditorDecision.DISCARD)
        assertEquals(next, model.state.value.pendingDecision)
        decide(model, EditorDecision.SAVE)
        runCurrent()
        assertEquals("b.md", model.state.value.relativePath)
        assertTrue(library().load("a.md").document.body == "Mine", "Saved body differs.")
        model.edit("Other draft")
        model.close()
        decide(model, EditorDecision.DISCARD)
        runCurrent()
        assertFalse(model.state.value.isOpen)
        bytesAre("body".encodeToByteArray(), "b.md")
    }

    @Test
    fun `newer edit during decision save retains decision and immutable snapshot`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("First")
        val captured = checkNotNull(model.snapshot())
        model.close()
        val decision = model.state.value.pendingDecision
        decide(model, EditorDecision.SAVE)
        model.edit("Newer")
        runCurrent()
        assertTrue(captured.source == "First", "Captured snapshot changed.")
        assertEquals(decision, model.state.value.pendingDecision)
        assertTrue(model.state.value.dirty)
        sourceIs(model, "Newer")
        assertTrue(library().load("a.md").document.body == "First", "Submitted save changed.")
        assertTrue(checkNotNull(model.snapshot()).revision > captured.revision)
        decide(model, EditorDecision.SAVE)
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertTrue(library().load("a.md").document.body == "Newer", "Second save differs.")
    }

    @Test
    fun `commands wait for save use its new stamp and navigation waits for command`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        model.save()
        model.rename("renamed.md")
        model.close()
        assertEquals(listOf(EditorAction.Rename("renamed.md"), EditorAction.Close), model.state.value.queuedActions)
        assertNull(model.state.value.pendingDecision)
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
        assertTrue(library().load("renamed.md").document.body == "Mine", "Moved save differs.")
    }

    @Test
    fun `queued command cannot mutate another session opened ahead of it`() = runTest {
        put(libraryDir.resolve("a.md"))
        put(libraryDir.resolve("b.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        model.save()
        model.open(LibrarySelection(PromptIdentity.at("b.md"), "b.md"))
        model.delete()
        runCurrent()
        assertEquals("b.md", model.state.value.relativePath)
        assertTrue(Files.exists(libraryDir.resolve("a.md")))
        bytesAre("body".encodeToByteArray(), "b.md")
        assertTrue(model.state.value.queuedActions.isEmpty())
    }

    @Test
    fun `stale save and another write before Keep mine retain draft and current disk bytes`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        put(libraryDir.resolve("a.md"), "Theirs".encodeToByteArray())
        model.save()
        runCurrent()
        assertNotNull(model.state.value.conflict)
        assertTrue(model.state.value.conflict?.source == "Theirs", "Conflict source differs.")
        sourceIs(model, "Mine")
        put(libraryDir.resolve("a.md"), "Newest".encodeToByteArray())
        model.resolveConflict(EditorConflictChoice.KEEP_MINE)
        runCurrent()
        sourceIs(model, "Mine")
        bytesAre("Newest".encodeToByteArray())
        assertTrue(model.state.value.conflict?.source == "Newest", "Conflict source differs.")
        model.resolveConflict(EditorConflictChoice.KEEP_MINE)
        runCurrent()
        assertNull(model.state.value.conflict)
        assertFalse(model.state.value.dirty)
        assertTrue(library().load("a.md").document.body == "Mine", "Resolved body differs.")
    }

    @Test
    fun `Take theirs reloads latest bytes and resumes a guarded command only after explicit choice`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        model.rename("renamed.md")
        put(libraryDir.resolve("a.md"), "Theirs".encodeToByteArray())
        decide(model, EditorDecision.SAVE)
        runCurrent()
        assertNotNull(model.state.value.pendingDecision)
        assertTrue(Files.exists(libraryDir.resolve("a.md")))
        put(libraryDir.resolve("a.md"), "Newest".encodeToByteArray())
        model.resolveConflict(EditorConflictChoice.TAKE_THEIRS)
        runCurrent()
        bytesAre("Newest".encodeToByteArray(), "renamed.md")
        assertNull(model.state.value.pendingDecision)
        assertNull(model.state.value.conflict)
    }

    @Test
    fun `deleted conflict can recreate only by explicit choice or discard without writing`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        model.edit("Mine")
        Files.delete(libraryDir.resolve("a.md"))
        model.save()
        runCurrent()
        assertEquals(true, model.state.value.conflict?.deleted)
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
        model.resolveConflict(EditorConflictChoice.KEEP_MINE)
        runCurrent()
        assertTrue(library().load("a.md").document.body == "Mine", "Recreated body differs.")
        model.edit("Again")
        Files.delete(libraryDir.resolve("a.md"))
        model.refresh()
        runCurrent()
        model.resolveConflict(EditorConflictChoice.DISCARD)
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
    }

    @Test
    fun `occupied create rename and move never overwrite and keep draft at original path`() = runTest {
        put(libraryDir.resolve("a.md"))
        put(libraryDir.resolve("b.md"), "Occupied".encodeToByteArray())
        put(libraryDir.resolve("Folder/a.md"), "Occupied folder".encodeToByteArray())
        val model = model()
        model.createDraft("b.md")
        model.edit("New")
        model.save()
        runCurrent()
        assertEquals(EditorFailure.OCCUPIED, model.state.value.failure)
        sourceIs(model, "New")
        assertTrue(model.state.value.isNew)
        assertTrue(model.state.value.dirty)
        bytesAre("Occupied".encodeToByteArray(), "b.md")
        model.setNewPath("created.md")
        model.save()
        runCurrent()
        assertFalse(model.state.value.isNew)
        model.close()
        open(model)
        runCurrent()
        model.rename("b.md")
        runCurrent()
        assertEquals(EditorFailure.OCCUPIED, model.state.value.failure)
        assertEquals("a.md", model.state.value.relativePath)
        model.move("Folder")
        runCurrent()
        assertEquals(EditorFailure.OCCUPIED, model.state.value.failure)
        assertEquals("a.md", model.state.value.relativePath)
        bytesAre("Occupied".encodeToByteArray(), "b.md")
        bytesAre("Occupied folder".encodeToByteArray(), "Folder/a.md")
        bytesAre("body".encodeToByteArray())
    }

    @Test
    fun `clean foreground changes reload but dirty foreground changes only open conflict`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        put(libraryDir.resolve("a.md"), "Clean refresh".encodeToByteArray())
        repository.refresh()
        runCurrent()
        sourceIs(model, "Clean refresh")
        assertFalse(model.state.value.dirty)
        model.edit("Mine")
        put(libraryDir.resolve("a.md"), "External".encodeToByteArray())
        repository.refresh()
        runCurrent()
        sourceIs(model, "Mine")
        assertTrue(model.state.value.dirty)
        assertTrue(model.state.value.conflict?.source == "External", "Conflict source differs.")
    }

    @Test
    fun `old load and validation replies cannot replace a later session or draft`() = runTest {
        put(libraryDir.resolve("a.md"), "A".encodeToByteArray())
        put(libraryDir.resolve("b.md"), "B".encodeToByteArray())
        val held = HeldDispatcher()
        val model = model(io = held, worker = held)
        open(model)
        runCurrent()
        held.release()
        model.open(LibrarySelection(PromptIdentity.at("b.md"), "b.md"))
        runCurrent()
        held.release()
        runCurrent()
        sourceIs(model, "B")
        model.edit("{{old}}")
        runCurrent()
        held.release()
        model.edit("{{new}}")
        runCurrent()
        held.release()
        runCurrent()
        sourceIs(model, "{{new}}")
        assertEquals(listOf("new"), model.state.value.fields.map { it.name })
        assertFalse(model.state.value.validating)
    }

    @Test
    fun `retirement cancels work not started and drops already queued replies`() = runTest {
        put(libraryDir.resolve("a.md"))
        val held = HeldDispatcher()
        val model = model(io = held)
        open(model)
        runCurrent()
        held.release()
        models.clear()
        runCurrent()
        model.edit("Late")
        model.save()
        model.createDraft("late.md")
        assertFalse(model.state.value.isOpen)
        bytesAre("body".encodeToByteArray())
        assertFalse(Files.exists(libraryDir.resolve("late.md")))
    }

    @Test
    fun `relocated move conflict uses destination and never recreates vacated source`() = runTest {
        val original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal"
        put(libraryDir.resolve("a.md"), original.encodeToByteArray())
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun move(source: String, destination: String) {
                prompts.move(source, destination)
                prompts.write("External destination".encodeToByteArray(), destination)
            }
        } })
        open(model)
        runCurrent()
        val identity = model.state.value.selection?.identity
        model.move("Dest")
        runCurrent()
        assertEquals("Dest/a.md", model.state.value.relativePath)
        assertNull(model.state.value.stamp)
        assertNotNull(model.state.value.conflict)
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
        model.resolveConflict(EditorConflictChoice.KEEP_MINE)
        runCurrent()
        assertEquals(identity, model.state.value.selection?.identity)
        assertTrue(library().load("Dest/a.md").document.body == "Original", "Destination body differs.")
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
        assertEquals(listOf("Dest/a.md"), repository.state.value.snapshot.prompts.map { it.entry.relativePath })
    }

    @Test
    fun `forensic history is inspectable without becoming a draft and restore fails safely`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        val identity = checkNotNull(model.state.value.selection).identity
        val fixtures = listOf(byteArrayOf(0xff.toByte()), "---\nformat: 2\n---\nFuture".encodeToByteArray(),
            "---\ntitle: [broken\n---\nBroken".encodeToByteArray(), ByteArray(Limits.maxPromptBytes + 1) { 65 })
        for ((index, bytes) in fixtures.withIndex()) put(stateDir.resolve("history/${identity.storageKey}/20261014T000000.000Z-00000$index.md"), bytes)
        model.loadHistory()
        runCurrent()
        assertEquals(4, model.state.value.history.revisions.size)
        for (entry in model.state.value.history.revisions) {
            assertFalse(entry.canRestore)
            model.selectRevision(entry.revision)
            sourceIs(model, "body")
            model.restore(entry.revision)
            runCurrent()
            assertEquals(EditorFailure.FORENSIC, model.state.value.failure)
            bytesAre("body".encodeToByteArray())
        }
        assertEquals(2, model.state.value.history.revisions.count { it.source == null })
    }

    @Test
    fun `committed history warning clears dirty state and never retries the save automatically`() = runTest {
        put(libraryDir.resolve("a.md"))
        val actual = AndroidStateStore(stateDir.toFile())
        var writes = 0
        val model = model(state = object : StateStore by actual {
            override fun listFiles(): List<StoredFile> {
                if (Files.readString(libraryDir.resolve("a.md")).contains("Committed")) throw StoreError.IOFailure
                return actual.listFiles()
            }
        }, wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) { writes++; prompts.write(bytes, path) }
        } })
        open(model)
        runCurrent()
        model.edit("Committed")
        model.save()
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertTrue(model.state.value.historyMaintenanceFailed)
        assertNull(model.state.value.failure)
        assertEquals(1, writes)
        assertEquals(AndroidPromptStore(libraryDir.toFile()).stamp("a.md"), model.state.value.stamp)
    }

    @Test
    fun `guard-approved selection follows editor commit and delete clears browser selection`() = runTest {
        put(libraryDir.resolve("a.md"))
        put(libraryDir.resolve("b.md"))
        val editor = model()
        val browser = LibraryViewModel(repository, dispatcher).also { models.put("browser", it) }
        editor.onSelectionChanged = browser::selectFromEditor
        browser.refresh()
        open(editor)
        runCurrent()
        editor.edit("Mine")
        editor.open(browser.state.value.rows.single { it.selection.relativePath == "b.md" }.selection)
        assertEquals("a.md", browser.state.value.selectedPrompt?.selection?.relativePath)
        decide(editor, EditorDecision.CANCEL)
        editor.save()
        runCurrent()
        assertEquals(editor.state.value.selection, browser.state.value.selectedPrompt?.selection)
        editor.rename("new.md")
        runCurrent()
        assertEquals(editor.state.value.selection, browser.state.value.selectedPrompt?.selection)
        val identity = checkNotNull(editor.state.value.selection).identity
        editor.delete()
        runCurrent()
        assertNull(browser.state.value.selectedPrompt)
        assertFalse(editor.state.value.isOpen)
        assertEquals(1, library().history.revisions(identity).size)
    }

    @Test
    fun `rename move delete and restore each obey Save Discard and Cancel on real files`() = runTest {
        var index = 0
        for (kind in listOf("rename", "move", "delete", "restore")) {
            for (decision in EditorDecision.entries) {
                val case = index++
                val path = "guard-$case.md"
                val id = ULID.generate(clock.now(), ByteArray(Limits.ulidEntropyBytes) { case.toByte() })
                val original = "---\nid: ${id.rawValue}\nmodel: retained\n---\nOriginal\r\n"
                put(libraryDir.resolve(path), original.encodeToByteArray())
                val model = model()
                open(model, path)
                runCurrent()
                val identity = checkNotNull(model.state.value.selection).identity
                val revision = HistoryRevision(identity, "20261014T000000.000Z-000000.md", clock.now())
                put(stateDir.resolve("history/${identity.storageKey}/${revision.filename}"), "Previous\r\n".encodeToByteArray())
                model.edit(original + "Mine")
                when (kind) {
                    "rename" -> model.rename("renamed-$case.md")
                    "move" -> model.move("folder-$case")
                    "delete" -> model.delete()
                    "restore" -> model.restore(revision)
                }
                assertNotNull(model.state.value.pendingDecision)
                decide(model, decision)
                runCurrent()
                assertNull(model.state.value.pendingDecision)
                if (decision == EditorDecision.CANCEL) {
                    sourceIs(model, original + "Mine")
                    bytesAre(original.encodeToByteArray(), path)
                    assertTrue(model.state.value.dirty)
                } else if (kind == "delete") {
                    assertFalse(model.state.value.isOpen)
                    assertFalse(Files.exists(libraryDir.resolve(path)))
                    assertTrue(library().history.revisions(identity).isNotEmpty())
                } else {
                    val destination = when (kind) {
                        "rename" -> "renamed-$case.md"
                        "move" -> "folder-$case/$path"
                        else -> path
                    }
                    val committed = library().load(destination)
                    val expected = if (kind == "restore") "Previous\r\n" else
                        if (decision == EditorDecision.SAVE) "Original\r\nMine" else "Original\r\n"
                    assertTrue(committed.document.body == expected, "Guarded command changed body.")
                    assertEquals(identity, committed.identity)
                    assertEquals(destination, model.state.value.relativePath)
                    assertFalse(model.state.value.dirty)
                    assertNull(model.state.value.failure)
                }
                models.clear()
                runCurrent()
            }
        }
    }

    @Test
    fun `a held file command blocks edits and duplicate writes while back waits for its commit`() = runTest {
        put(libraryDir.resolve("a.md"))
        var moves = 0
        val held = HeldDispatcher()
        val model = model(io = held, wrap = { prompts -> object : PromptStore by prompts {
            override fun move(source: String, destination: String) { moves++; prompts.move(source, destination) }
        } })
        open(model)
        runCurrent()
        held.release()
        runCurrent()
        model.rename("new.md")
        model.rename("new.md")
        model.edit("Blocked")
        model.save()
        model.close()
        sourceIs(model, "body")
        assertEquals(EditorStatus.COMMAND, model.state.value.status)
        assertEquals(listOf(EditorAction.Close), model.state.value.queuedActions)
        runCurrent()
        held.release()
        runCurrent()
        held.releaseAll()
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertEquals(1, moves)
        bytesAre("body".encodeToByteArray(), "new.md")
        assertFalse(Files.exists(libraryDir.resolve("a.md")))
    }

    @Test
    fun `history failure can retry and a retired history completion cannot reopen the editor`() = runTest {
        put(libraryDir.resolve("a.md"))
        var fail = false
        val actual = AndroidStateStore(stateDir.toFile())
        val held = HeldDispatcher()
        val model = model(io = held, state = object : StateStore by actual {
            override fun listFiles(): List<StoredFile> {
                if (fail) throw StoreError.IOFailure
                return actual.listFiles()
            }
        })
        open(model)
        runCurrent()
        held.release()
        runCurrent()
        val identity = checkNotNull(model.state.value.selection).identity
        put(stateDir.resolve("history/${identity.storageKey}/20261014T000000.000Z-000000.md"), "Previous".encodeToByteArray())
        fail = true
        model.loadHistory()
        runCurrent()
        held.release()
        runCurrent()
        assertEquals(EditorFailure.DATA, model.state.value.history.failure)
        assertFalse(model.state.value.history.loading)
        sourceIs(model, "body")
        fail = false
        model.loadHistory()
        runCurrent()
        held.release()
        runCurrent()
        assertNull(model.state.value.history.failure)
        assertEquals(1, model.state.value.history.revisions.size)
        model.loadHistory()
        runCurrent()
        held.release()
        model.close()
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertTrue(model.state.value.history.revisions.isEmpty())
    }

    @Test
    fun `stale restore and a newly read-only conflict never overwrite disk bytes`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = model()
        open(model)
        runCurrent()
        val identity = checkNotNull(model.state.value.selection).identity
        val revision = HistoryRevision(identity, "20261014T000000.000Z-000000.md", clock.now())
        put(stateDir.resolve("history/${identity.storageKey}/${revision.filename}"), "Previous".encodeToByteArray())
        put(libraryDir.resolve("a.md"), "Changed".encodeToByteArray())
        model.restore(revision)
        runCurrent()
        sourceIs(model, "body")
        bytesAre("Changed".encodeToByteArray())
        assertNotNull(model.state.value.conflict)
        model.resolveConflict(EditorConflictChoice.CANCEL)
        model.edit("Mine")
        val future = "---\nformat: 2\n---\nFuture\r\n".encodeToByteArray()
        put(libraryDir.resolve("a.md"), future)
        model.resolveConflict(EditorConflictChoice.REVIEW)
        runCurrent()
        assertEquals(SourceReadOnlyReason.FUTURE_FORMAT, model.state.value.conflict?.readOnlyReason)
        model.resolveConflict(EditorConflictChoice.KEEP_MINE)
        runCurrent()
        sourceIs(model, "Mine")
        bytesAre(future)
        model.resolveConflict(EditorConflictChoice.TAKE_THEIRS)
        runCurrent()
        assertEquals(SourceReadOnlyReason.FUTURE_FORMAT, model.state.value.readOnlyReason)
        assertFalse(model.state.value.dirty)
        assertFalse(model.state.value.canEdit)
    }

    @Test
    fun `unverified commit reports reload requirement and retains draft without publishing a false success`() = runTest {
        put(libraryDir.resolve("a.md"))
        var failVerification = false
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) { prompts.write(bytes, path); failVerification = true }
            override fun read(path: String): ByteArray {
                if (failVerification) { failVerification = false; throw StoreError.IOFailure }
                return prompts.read(path)
            }
        } })
        open(model)
        runCurrent()
        val stamp = model.state.value.stamp
        val version = repository.state.value.snapshot.version
        model.edit("Submitted")
        model.save()
        model.edit("Newer")
        runCurrent()
        assertEquals(EditorFailure.UNVERIFIED, model.state.value.failure)
        sourceIs(model, "Newer")
        assertTrue(model.state.value.dirty)
        assertEquals(stamp, model.state.value.stamp)
        assertEquals(version, repository.state.value.snapshot.version)
        assertTrue(library().load("a.md").document.body == "Submitted", "Unverified commit differs.")
    }

    @Test
    fun `invalid creation path keeps new draft and a corrected path can commit`() = runTest {
        val model = model()
        model.createDraft("../outside.md")
        model.edit("Draft")
        model.save()
        runCurrent()
        assertEquals(EditorFailure.INVALID_PATH, model.state.value.failure)
        sourceIs(model, "Draft")
        assertTrue(model.state.value.isNew)
        assertTrue(model.state.value.dirty)
        assertTrue(repository.state.value.snapshot.prompts.isEmpty())
        assertFalse(Files.exists(filesDir.resolve("outside.md")))
        model.setNewPath("Folder/safe.md")
        model.save()
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertEquals("Folder/safe.md", model.state.value.relativePath)
        assertTrue(library().load("Folder/safe.md").document.body == "Draft", "Created body differs.")
    }

    @Test
    fun `retired queued save performs no write and byte-distinct Unicode edits are dirty`() = runTest {
        val original = "e\u0301\r\n"
        put(libraryDir.resolve("a.md"), original.encodeToByteArray())
        var writes = 0
        val held = HeldDispatcher()
        val model = model(io = held, wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) { writes++; prompts.write(bytes, path) }
        } })
        open(model)
        runCurrent()
        held.release()
        runCurrent()
        model.edit("é\r\n")
        assertTrue(model.state.value.dirty)
        model.edit(original)
        assertFalse(model.state.value.dirty)
        model.edit("Changed")
        model.save()
        runCurrent()
        models.clear()
        held.releaseAll()
        runCurrent()
        assertEquals(0, writes)
        bytesAre(original.encodeToByteArray())
        assertFalse(model.state.value.isOpen)
    }

    @Test
    fun `cancelling a relocated conflict cannot authorize an unstamped save or lose the retained source`() = runTest {
        put(libraryDir.resolve("a.md"), "Original".encodeToByteArray())
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun move(source: String, destination: String) {
                prompts.move(source, destination)
                prompts.write("External".encodeToByteArray(), destination)
            }
        } })
        open(model)
        runCurrent()
        model.move("Dest")
        runCurrent()
        model.resolveConflict(EditorConflictChoice.CANCEL)
        model.save()
        runCurrent()
        bytesAre("External".encodeToByteArray(), "Dest/a.md")
        assertNotNull(model.state.value.conflict)
        assertFalse(model.state.value.canSave)
        model.refresh()
        runCurrent()
        sourceIs(model, "Original")
        assertNotNull(model.state.value.conflict)
    }

    @Test
    fun `late invalid save cannot replace live validation of a newer corrected draft`() = runTest {
        put(libraryDir.resolve("a.md"))
        val held = HeldDispatcher()
        val model = model(io = held)
        open(model)
        runCurrent()
        held.release()
        runCurrent()
        model.edit("{{unclosed")
        runCurrent()
        assertTrue(model.state.value.issues.any { it.code == PromptIssueCode.UNBALANCED_OPENER })
        model.save()
        runCurrent()
        model.edit("Corrected {{name}}")
        runCurrent()
        assertTrue(model.state.value.issues.isEmpty())
        held.release()
        runCurrent()
        sourceIs(model, "Corrected {{name}}")
        assertTrue(model.state.value.issues.isEmpty(), "An older save replaced current validation.")
        assertTrue(model.state.value.previewAvailable)
        assertTrue(model.state.value.dirty)
        bytesAre("body".encodeToByteArray())
    }

    private class HeldDispatcher : CoroutineDispatcher() {
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.addLast(block) }
        fun release() { if (tasks.isNotEmpty()) tasks.removeFirst().run() }
        fun releaseAll() { while (tasks.isNotEmpty()) release() }
    }
}
