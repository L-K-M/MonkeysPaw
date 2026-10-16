package ch.lkmc.monkeyspaw.ui.editor

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantTokenUsage
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.security.MessageDigest
import java.time.Instant
import kotlin.test.*

/** Real temporary roots exercise the M8 stores, worker seam and editor commit adoption. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class EditorProvenanceTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val applicationScope = CoroutineScope(SupervisorJob() + dispatcher)
    private lateinit var repository: LibraryRepository
    private var modelCount = 0

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clearModels() { models.clear(); applicationScope.cancel(); Dispatchers.resetMain() }

    private fun model(state: StateStore = AndroidStateStore(stateDir.toFile()),
        wrap: (PromptStore) -> PromptStore = { it }): EditorViewModel {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val library = library(state, wrap(prompts))
        repository = LibraryRepository(library, EditingService(library), prompts, dispatcher)
        return EditorViewModel(repository, dispatcher, Clock { Instant.parse("2026-10-14T00:00:00Z") }, applicationScope)
            .also { models.put("provenance-${modelCount++}", it) }
    }

    private fun open(model: EditorViewModel, path: String = "a.md") {
        model.open(LibrarySelection(PromptIdentity.at(path), path))
    }

    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun attribution(path: String, bytes: ByteArray) {
        // A Swift version-1 record; no assistant request or publication path is needed to render it.
        val record = """{"contentSHA256":"${hash(bytes)}","model":"model-1","origin":"llm","providerHost":"example.com","timestamp":"1970-01-01T00:00:01.234Z","usage":{"inputTokens":11,"outputTokens":7},"version":1}"""
        put(stateDir.resolve(path), record.encodeToByteArray())
    }

    private fun head(identity: PromptIdentity) = "history/${identity.storageKey}/head.json"
    private fun sidecar(revision: HistoryRevision) = "history/${revision.identity.storageKey}/${revision.filename}.json"
    private fun bytes(path: String = "a.md") = Files.readAllBytes(libraryDir.resolve(path))
    private fun generated(): LibraryEntry = library().create(PromptCodec.parse("Generated\r\n", "a.md"), "a.md").entry

    @Test fun `history displays current and archived attribution then restores it across graph restart`() = runTest {
        val generated = generated()
        attribution(head(generated.identity), bytes())
        val model = model()
        open(model)
        runCurrent()
        model.setTab(EditorTab.HISTORY)
        runCurrent()
        val current = assertNotNull(model.state.value.history.currentProvenance)
        assertEquals("example.com", current.providerHost)
        assertEquals("model-1", current.model)
        assertEquals(Instant.ofEpochMilli(1234), current.timestamp)
        assertEquals(AssistantTokenUsage(11, 7), current.usage)
        assertTrue(model.state.value.history.revisions.isEmpty())
        model.edit("Manual")
        // Attribution describes the saved head, not an unsaved draft.
        assertEquals(current, model.state.value.history.currentProvenance)
        model.save()
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertFalse(model.state.value.provenanceMaintenanceFailed)
        assertNull(model.state.value.history.currentProvenance)
        val revision = model.state.value.history.revisions.single()
        assertEquals(current, revision.provenance)
        assertTrue(Files.exists(stateDir.resolve(sidecar(revision.revision))))
        assertFalse(Files.exists(stateDir.resolve(head(generated.identity))))
        val saved = bytes()
        model.selectRevision(revision.revision)
        assertContentEquals(saved, bytes())
        model.restore(revision.revision)
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertEquals(current, model.state.value.history.currentProvenance)
        assertEquals(generated.identity, model.state.value.selection?.identity)
        assertEquals("Generated\r\n", library().load("a.md").document.body)
        assertEquals(current, library().provenance("a.md"))
        assertNull(model.state.value.history.revisions.first().provenance)
        assertEquals(current, EditingService(library()).history(generated.identity, "a.md").last().provenance)
    }

    @Test fun `local rename first-id save and file failure preserve or roll back private sidecars`() = runTest {
        val raw = "Original\r\n".encodeToByteArray()
        put(libraryDir.resolve("a.md"), raw)
        val local = PromptIdentity.at("a.md")
        attribution(head(local), raw)
        val oldRevision = HistoryRevision(local, "20261014T000000.000Z-000000.md", Instant.parse("2026-10-14T00:00:00Z"))
        val revisionPath = sidecar(oldRevision).removeSuffix(".json")
        put(stateDir.resolve(revisionPath), "Older".encodeToByteArray())
        attribution(sidecar(oldRevision), "Older".encodeToByteArray())
        var failWrite = true
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) {
                if (failWrite) throw StoreError.IOFailure
                prompts.write(bytes, path)
            }
        } })
        open(model)
        runCurrent()
        model.setTab(EditorTab.HISTORY)
        runCurrent()
        val origin = model.state.value.history.currentProvenance
        model.rename("renamed.md")
        runCurrent()
        model.move("folder")
        runCurrent()
        val path = "folder/renamed.md"
        val moved = assertNotNull(model.state.value.selection).identity
        assertIs<PromptIdentity.Local>(moved)
        assertNotEquals(local, moved)
        assertContentEquals(raw, bytes(path))
        assertEquals(origin, model.state.value.history.currentProvenance)
        model.edit("Manual")
        model.save()
        runCurrent()
        assertEquals(EditorFailure.DATA, model.state.value.failure)
        assertTrue(model.state.value.dirty)
        assertEquals(moved, model.state.value.selection?.identity)
        assertEquals(origin, library().provenance(path))
        assertEquals(1, library().history.revisions(moved).size)
        assertContentEquals(raw, bytes(path))
        failWrite = false
        model.save()
        runCurrent()
        val assigned = assertNotNull(model.state.value.selection).identity
        assertIs<PromptIdentity.Assigned>(assigned)
        assertNull(model.state.value.history.currentProvenance)
        assertEquals(listOf(origin, origin), model.state.value.history.revisions.map { it.provenance })
        assertFalse(Files.exists(stateDir.resolve(head(moved))))
        model.delete()
        runCurrent()
        assertFalse(model.state.value.isOpen)
        assertEquals(2, library().history.revisions(assigned).size)
    }

    @Test fun `corrupt head stays editable and committed warning survives reconciliation without a retry`() = runTest {
        val generated = generated()
        put(stateDir.resolve(head(generated.identity)), "Corrupt JSON".encodeToByteArray())
        var writes = 0
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) { writes++; prompts.write(bytes, path) }
        } })
        open(model)
        runCurrent()
        assertTrue(model.state.value.canEdit)
        model.setTab(EditorTab.HISTORY)
        runCurrent()
        assertNull(model.state.value.history.failure)
        assertNull(model.state.value.history.currentProvenance)
        model.edit("Manual")
        model.save()
        model.save()
        runCurrent()
        assertEquals(1, writes)
        assertFalse(model.state.value.dirty)
        assertNull(model.state.value.failure)
        assertTrue(model.state.value.provenanceMaintenanceFailed)
        assertFalse(model.state.value.historyMaintenanceFailed)
        assertEquals(model.state.value.stamp, library().load("a.md").stamp)
        assertEquals(model.state.value.stamp, repository.state.value.snapshot.prompts.single().entry.stamp)
        assertFalse(Files.exists(stateDir.resolve(head(generated.identity))))
        model.refresh()
        model.loadHistory()
        runCurrent()
        assertTrue(model.state.value.provenanceMaintenanceFailed)
        assertEquals(1, writes)
    }

    @Test fun `restore adopts a corrupt sidecar commit and both maintenance warnings`() = runTest {
        for (historyFailure in listOf(false, true)) {
            val generated = generated()
            attribution(head(generated.identity), bytes())
            val library = library()
            val manual = library.save(PromptCodec.parse("Manual", "a.md"), "a.md", generated.stamp).entry
            val revision = library.history.revisions(manual.identity).last()
            put(stateDir.resolve(sidecar(revision)), "Corrupt JSON".encodeToByteArray())
            if (historyFailure) for (sequence in 1 until Limits.historyCapPerPrompt) {
                val filename = "20261014T000000.000Z-" + sequence.toString().padStart(6, '0') + ".md"
                put(stateDir.resolve("history/${manual.identity.storageKey}/$filename"), "Older".encodeToByteArray())
            }
            var writes = 0
            val actual = AndroidStateStore(stateDir.toFile())
            val model = model(state = object : StateStore by actual {
                override fun delete(path: String) {
                    if (historyFailure && path.endsWith(".md")) throw StoreError.IOFailure
                    actual.delete(path)
                }
            }, wrap = { prompts -> object : PromptStore by prompts {
                override fun write(bytes: ByteArray, path: String) { writes++; prompts.write(bytes, path) }
            } })
            open(model)
            runCurrent()
            model.setTab(EditorTab.HISTORY)
            runCurrent()
            assertNull(model.state.value.history.revisions.first { it.revision == revision }.provenance)
            model.restore(revision)
            model.restore(revision)
            runCurrent()
            assertEquals(1, writes)
            assertFalse(model.state.value.dirty)
            assertNull(model.state.value.failure)
            assertTrue(model.state.value.provenanceMaintenanceFailed)
            assertEquals(historyFailure, model.state.value.historyMaintenanceFailed)
            assertEquals("Generated\r\n", library.load("a.md").document.body)
            assertContentEquals(assertNotNull(model.state.value.source).encodeToByteArray(), bytes())
            assertEquals(model.state.value.stamp, repository.state.value.snapshot.prompts.single().entry.stamp)
            model.close()
            runCurrent()
            Files.walk(stateDir).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
            Files.delete(libraryDir.resolve("a.md"))
        }
    }

    @Test fun `head publication and clear failures remain committed warnings with stale attribution suppressed`() = runTest {
        for (clear in listOf(false, true)) {
            val generated = generated()
            attribution(head(generated.identity), bytes())
            val before = library().provenance("a.md")
            val actual = AndroidStateStore(stateDir.toFile())
            var writes = 0
            val model = model(state = object : StateStore by actual {
                override fun writePrivate(bytes: ByteArray, path: String) {
                    if (!clear && path.endsWith("/head.json")) throw StoreError.IOFailure
                    actual.writePrivate(bytes, path)
                }
                override fun delete(path: String) {
                    if (clear && path.endsWith("/head.json")) throw StoreError.IOFailure
                    actual.delete(path)
                }
            }, wrap = { prompts -> object : PromptStore by prompts {
                override fun write(bytes: ByteArray, path: String) { writes++; prompts.write(bytes, path) }
            } })
            open(model)
            runCurrent()
            model.edit("Manual")
            model.save()
            runCurrent()
            val revision = library().history.revisions(generated.identity).single()
            if (!clear) {
                // Restore is the existing editor path that publishes a head record.
                model.restore(revision)
                runCurrent()
            }
            assertFalse(model.state.value.dirty)
            assertNull(model.state.value.failure)
            assertTrue(model.state.value.provenanceMaintenanceFailed)
            assertEquals(if (clear) 1 else 2, writes)
            assertNull(library().provenance("a.md"))
            assertEquals(before, library().provenance(revision))
            model.close()
            runCurrent()
            Files.walk(stateDir).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
            Files.delete(libraryDir.resolve("a.md"))
        }
    }

    @Test fun `head and revision IO errors fail history or restore without writing a file`() = runTest {
        val generated = generated()
        attribution(head(generated.identity), bytes())
        val manual = library().save(PromptCodec.parse("Manual", "a.md"), "a.md", generated.stamp).entry
        val revision = library().history.revisions(manual.identity).single()
        val actual = AndroidStateStore(stateDir.toFile())
        var unreadable = sidecar(revision)
        var writes = 0
        val model = model(state = object : StateStore by actual {
            override fun read(path: String): ByteArray {
                if (path == unreadable) throw StoreError.IOFailure
                return actual.read(path)
            }
        }, wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) { writes++; prompts.write(bytes, path) }
        } })
        open(model)
        runCurrent()
        model.loadHistory()
        runCurrent()
        assertEquals(EditorFailure.DATA, model.state.value.history.failure)
        model.restore(revision)
        runCurrent()
        assertEquals(EditorFailure.DATA, model.state.value.failure)
        assertEquals(0, writes)
        assertEquals(manual.stamp, library().load("a.md").stamp)
        unreadable = ""
        model.loadHistory()
        runCurrent()
        assertNull(model.state.value.history.failure)
        assertNotNull(model.state.value.history.revisions.single().provenance)
        attribution(head(manual.identity), bytes())
        unreadable = head(manual.identity)
        model.loadHistory()
        runCurrent()
        assertEquals(EditorFailure.DATA, model.state.value.history.failure)
        assertNull(model.state.value.history.currentProvenance)
        assertEquals(0, writes)
    }

    @Test fun `external change cannot keep current attribution or replace an unsaved draft`() = runTest {
        val generated = generated()
        attribution(head(generated.identity), bytes())
        val model = model()
        open(model)
        runCurrent()
        model.setTab(EditorTab.HISTORY)
        runCurrent()
        assertNotNull(model.state.value.history.currentProvenance)
        model.edit(assertNotNull(model.state.value.source) + "Unsaved")
        put(libraryDir.resolve("a.md"), (generated.document.source + "External").encodeToByteArray())
        model.refresh()
        runCurrent()
        assertTrue(model.state.value.dirty)
        assertTrue(assertNotNull(model.state.value.source).endsWith("Unsaved"))
        assertNotNull(model.state.value.conflict)
        assertNull(model.state.value.history.currentProvenance)
        model.resolveConflict(EditorConflictChoice.TAKE_THEIRS)
        runCurrent()
        assertFalse(model.state.value.dirty)
        assertNull(model.state.value.history.currentProvenance)
        assertNull(library().provenance("a.md"))
    }
}
