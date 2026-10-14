package ch.lkmc.monkeyspaw.ui.library

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.ports.PromptStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class LibraryViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private lateinit var repository: LibraryRepository

    @BeforeTest
    fun setMain() { Dispatchers.setMain(dispatcher) }

    @AfterTest
    fun clearModels() {
        models.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `search uses Core fuzzy ranking and exact normalized tag filters`() = runTest {
        fixtures()
        val model = model()
        assertEquals(LibraryContent.LOADING, model.state.value.content)
        model.refresh()
        runCurrent()
        assertEquals(LibraryContent.READY, model.state.value.content)
        assertEquals(listOf("Work/code/review.md", "Work2/strasse.md", "Work/notes.md", "plain.md"), paths(model))
        for (query in listOf("rvw changes", "code", "#CODE", "#strasse", "notes code", "\u00a0code\u00a0")) {
            model.setQuery(query)
            runCurrent()
            val expected = repository.withLibrary { library, _ -> library.index.search(query).map { it.entry.relativePath } }
            assertEquals(expected, paths(model), query)
        }
        model.setQuery("rvw changes")
        runCurrent()
        assertEquals(listOf("Work/code/review.md"), paths(model))
        model.setQuery("#STRASSE")
        runCurrent()
        assertEquals(listOf("Work2/strasse.md"), paths(model))
        model.setQuery("#")
        runCurrent()
        assertEquals(LibraryContent.NO_MATCH, model.state.value.content)
        model.clearFilters()
        runCurrent()
        assertEquals(4, model.state.value.rows.size)
    }

    @Test
    fun `counts include descendants and each normalized tag once regardless of search`() = runTest {
        fixtures()
        val model = loadedModel()
        val counts = model.state.value.sections.associate { it.filter to it.count }
        assertEquals(4, counts[LibraryFilter.All])
        assertEquals(1, counts[LibraryFilter.Favourites])
        assertEquals(0, counts[LibraryFilter.Recent])
        assertEquals(2, counts[LibraryFilter.Folder("Work")])
        assertEquals(1, counts[LibraryFilter.Folder("Work/code")])
        assertEquals(1, counts[LibraryFilter.Folder("Work2")])
        assertEquals(2, counts[LibraryFilter.Tag("code")])
        assertEquals(1, counts[LibraryFilter.Tag("strasse")])
        assertEquals("#Code", model.state.value.sections.single { it.filter == LibraryFilter.Tag("code") }.title)
        assertTrue(model.state.value.sections.none { it.filter == LibraryFilter.Tag("") })
        model.setFilter(LibraryFilter.Folder("Work"))
        runCurrent()
        assertEquals(listOf("Work/code/review.md", "Work/notes.md"), paths(model))
        model.setQuery("notes")
        runCurrent()
        assertEquals(listOf("Work/notes.md"), paths(model))
        assertEquals(counts, model.state.value.sections.associate { it.filter to it.count })
        model.clearFilters()
        model.setFilter(LibraryFilter.Tag("CoDe"))
        runCurrent()
        assertEquals(LibraryFilter.Tag("code"), model.state.value.filter)
        assertEquals(listOf("Work/code/review.md", "Work/notes.md"), paths(model))
        model.setFilter(LibraryFilter.Favourites)
        runCurrent()
        assertEquals(listOf("Work/code/review.md"), paths(model))
    }

    @Test
    fun `selection survives a hidden row and browsing never reads disk or learns values`() = runTest {
        fixtures()
        var reads = 0
        val model = loadedModel(wrap = { prompts -> object : PromptStore by prompts {
            override fun read(path: String): ByteArray { reads++; return prompts.read(path) }
        } })
        val selection = model.state.value.rows.single { it.selection.relativePath == "plain.md" }.selection
        model.select(selection)
        val afterLoad = reads
        model.setFilter(LibraryFilter.Favourites)
        model.setQuery("nomatch")
        runCurrent()
        assertEquals(selection, model.state.value.selectedPrompt?.selection)
        assertTrue(model.state.value.rows.isEmpty())
        assertEquals(afterLoad, reads)
        assertFalse(Files.exists(stateDir.resolve("values.json")))
        assertTrue(repository.state.value.snapshot.prompts.all { it.useEvents.isEmpty() })
        model.select(model.state.value.selectedPrompt!!.selection.copy(relativePath = "missing.md"))
        assertEquals(selection, model.state.value.selectedPrompt?.selection)
        model.select(null)
        assertNull(model.state.value.selectedPrompt)
    }

    @Test
    fun `favourite saves through Core once and rebinds first-save identity without losing body or metadata`() = runTest {
        val source = "---\ntitle: Alpha\nmodel: retained\n---\nExact body\r\n"
        put(libraryDir.resolve("a.md"), source.encodeToByteArray())
        val model = loadedModel()
        val old = model.state.value.rows.single()
        model.select(old.selection)
        model.toggleFavorite(old.selection)
        model.toggleFavorite(old.selection)
        assertEquals(old.selection, model.state.value.favoritePending)
        runCurrent()
        val saved = model.state.value.rows.single()
        assertTrue(saved.favorite)
        assertIs<PromptIdentity.Assigned>(saved.selection.identity)
        assertNotEquals(old.selection.identity, saved.selection.identity)
        assertEquals(saved.selection, model.state.value.selectedPrompt?.selection)
        assertNull(model.state.value.favoritePending)
        assertNull(model.state.value.failure)
        assertEquals(1, model.state.value.sections.single { it.filter == LibraryFilter.Favourites }.count)
        repository.withLibrary { library, _ ->
            val entry = library.load("a.md")
            assertTrue(entry.document.source.contains("model: retained"))
            assertEquals("Exact body\r\n", entry.document.body)
            assertEquals(1, library.history.revisions(saved.selection.identity).size)
            assertTrue(library.usage.useEvents(saved.selection.identity).isEmpty())
        }
        model.toggleFavorite(saved.selection)
        runCurrent()
        assertFalse(model.state.value.rows.single().favorite)
        assertEquals(saved.selection.identity, model.state.value.selectedPrompt?.selection?.identity)
    }

    @Test
    fun `a favourite completion never selects a different row over the user's newer choice`() = runTest {
        fixtures()
        val model = loadedModel()
        val first = model.state.value.rows.first()
        val other = model.state.value.rows.last()
        model.select(first.selection)
        model.toggleFavorite(first.selection)
        model.select(other.selection)
        model.setQuery("notes")
        runCurrent()
        assertEquals(other.selection, model.state.value.selectedPrompt?.selection)
        assertEquals("notes", model.state.value.query)
        assertEquals(listOf("Work/notes.md"), paths(model))
    }

    @Test
    fun `stale stamped favourite fails without overwriting and a refresh permits retry`() = runTest {
        put(libraryDir.resolve("a.md"))
        val model = loadedModel()
        val row = model.state.value.rows.single()
        model.select(row.selection)
        val external = "Externally changed body".encodeToByteArray()
        put(libraryDir.resolve("a.md"), external)
        model.toggleFavorite(row.selection)
        runCurrent()
        assertEquals(LibraryFailure.CHANGED, model.state.value.failure)
        assertFalse(model.state.value.rows.single().favorite)
        assertContentEquals(external, Files.readAllBytes(libraryDir.resolve("a.md")))
        model.refresh()
        runCurrent()
        assertNull(model.state.value.failure)
        model.toggleFavorite(model.state.value.rows.single().selection)
        runCurrent()
        assertTrue(model.state.value.rows.single().favorite)
    }

    @Test
    fun `failed favourite publication preserves the prompt and controls remain usable`() = runTest {
        put(libraryDir.resolve("a.md"))
        var failWrites = true
        val model = loadedModel(wrap = { prompts -> object : PromptStore by prompts {
            override fun write(bytes: ByteArray, path: String) {
                if (failWrites) throw StoreError.IOFailure
                prompts.write(bytes, path)
            }
        } })
        val row = model.state.value.rows.single()
        model.select(row.selection)
        model.toggleFavorite(row.selection)
        runCurrent()
        assertEquals(LibraryFailure.FAVOURITE, model.state.value.failure)
        assertEquals(row, model.state.value.rows.single())
        assertNull(model.state.value.favoritePending)
        assertContentEquals("body".encodeToByteArray(), Files.readAllBytes(libraryDir.resolve("a.md")))
        model.setQuery("unmatched")
        runCurrent()
        assertEquals(LibraryContent.NO_MATCH, model.state.value.content)
        model.clearFilters()
        runCurrent()
        failWrites = false
        model.toggleFavorite(row.selection)
        runCurrent()
        assertTrue(model.state.value.rows.single().favorite)
        assertNull(model.state.value.failure)
    }

    @Test
    fun `invalid and future entries stay visible selectable and read-only with their issues`() = runTest {
        val files = mapOf(
            "malformed.md" to "---\ntitle: [\n---\nbody".encodeToByteArray(),
            "future.md" to "---\nformat: 2\ntitle: Future\ntags: [future]\n---\nbody".encodeToByteArray(),
            "bytes.md" to byteArrayOf(0xff.toByte()),
            "oversized.md" to ByteArray(Limits.maxPromptBytes + 1) { 'a'.code.toByte() },
        )
        for ((path, bytes) in files) put(libraryDir.resolve(path), bytes)
        val model = loadedModel()
        assertEquals(files.size, model.state.value.rows.size)
        val issues = model.state.value.rows.associate { it.selection.relativePath to it.issues.map { issue -> issue.code } }
        assertContains(issues.getValue("malformed.md"), PromptIssueCode.INVALID_YAML)
        assertContains(issues.getValue("future.md"), PromptIssueCode.UNSUPPORTED_FORMAT)
        assertContains(issues.getValue("bytes.md"), PromptIssueCode.INVALID_UTF8)
        assertContains(issues.getValue("oversized.md"), PromptIssueCode.SOURCE_TOO_LARGE)
        val version = repository.state.value.snapshot.version
        for (row in model.state.value.rows) {
            assertTrue(row.isReadOnly)
            model.select(row.selection)
            assertEquals(row, model.state.value.selectedPrompt)
            model.toggleFavorite(row.selection)
            runCurrent()
            assertNull(model.state.value.favoritePending)
            assertContentEquals(files.getValue(row.selection.relativePath), Files.readAllBytes(libraryDir.resolve(row.selection.relativePath)))
        }
        assertEquals(version, repository.state.value.snapshot.version)
        model.setFilter(LibraryFilter.Tag("future"))
        runCurrent()
        assertEquals(listOf("future.md"), paths(model))
    }

    @Test
    fun `ordinary Groups and Conflicts folders and warning-only prompts remain local entries`() = runTest {
        put(libraryDir.resolve("Groups/example/a.md"), "literal {{bad.name}}".encodeToByteArray())
        put(libraryDir.resolve("Conflicts/b.md"))
        val model = loadedModel()
        assertEquals(1, model.state.value.sections.single { it.filter == LibraryFilter.Folder("Groups") }.count)
        assertEquals(1, model.state.value.sections.single { it.filter == LibraryFilter.Folder("Conflicts") }.count)
        val warning = model.state.value.rows.single { it.selection.relativePath.endsWith("a.md") }
        assertContains(warning.issues.map { it.code }, PromptIssueCode.INVALID_PLACEHOLDER)
        assertFalse(warning.isReadOnly)
        model.toggleFavorite(warning.selection)
        runCurrent()
        assertTrue(model.state.value.rows.single { it.selection.relativePath.endsWith("a.md") }.favorite)
    }

    @Test
    fun `Recent updates after recorded copies using Core usage and orders by latest use rather than frecency`() = runTest {
        put(libraryDir.resolve("older.md"))
        put(libraryDir.resolve("latest.md"))
        val model = loadedModel()
        model.setFilter(LibraryFilter.Recent)
        runCurrent()
        assertEquals(LibraryContent.NO_MATCH, model.state.value.content)
        val now = Instant.parse("2026-10-14T00:00:00Z")
        repository.withLibrary { library, _ ->
            val older = library.load("older.md").identity
            repeat(4) { library.usage.recordUse(older, now.minusSeconds(60)) }
            val latest = library.load("latest.md").identity
            library.index.recordUse(latest) // The same learning API K15 uses after a successful copy.
            library.usage.recordUse(latest, now.minusSeconds(120)) // Clock reversal must not hide its latest use.
        }
        runCurrent()
        assertEquals(listOf("latest.md", "older.md"), paths(model))
        assertEquals(2, model.state.value.sections.single { it.filter == LibraryFilter.Recent }.count)
        assertEquals(now, model.state.value.rows.first().lastUsedAt)
        model.setFilter(LibraryFilter.All)
        runCurrent()
        assertEquals(listOf("older.md", "latest.md"), paths(model))
    }

    @Test
    fun `Recent caps before filtering`() = runTest {
        val total = Limits.libraryRecentCap + 2
        repeat(total) { index -> put(libraryDir.resolve("p%03d.md".format(index))) }
        val model = loadedModel()
        repository.withLibrary { library, _ ->
            for ((index, entry) in library.entries().withIndex()) {
                library.usage.recordUse(entry.identity, Instant.ofEpochSecond(index.toLong()))
            }
        }
        runCurrent()
        model.setFilter(LibraryFilter.Recent)
        runCurrent()
        assertEquals(Limits.libraryRecentCap, model.state.value.rows.size)
        assertEquals("p101.md", paths(model).first())
        assertEquals("p002.md", paths(model).last())
        model.setQuery("p000")
        runCurrent()
        assertEquals(LibraryContent.NO_MATCH, model.state.value.content)
        assertEquals(Limits.libraryRecentCap, model.state.value.sections.single { it.filter == LibraryFilter.Recent }.count)
        model.setFilter(LibraryFilter.All)
        runCurrent()
        assertEquals(listOf("p000.md"), paths(model))
    }

    @Test
    fun `Recent ties and folder sections use raw UTF-8 order and folders group their descendants`() = runTest {
        val paths = listOf("a-/x.md", "a/z/x.md", "a/x.md", "\uD800\uDC00/x.md", "\uE000/x.md", "e\u0301/x.md", "é/x.md")
        for (path in paths) put(libraryDir.resolve(path), "---\ntitle: Same\n---\nbody".encodeToByteArray())
        val model = loadedModel()
        assertEquals(listOf("a", "a/z", "a-", "e\u0301", "é", "\uE000", "\uD800\uDC00"),
            model.state.value.sections.mapNotNull { (it.filter as? LibraryFilter.Folder)?.path })
        repository.withLibrary { library, _ ->
            for (entry in library.entries()) library.usage.recordUse(entry.identity, Instant.EPOCH)
        }
        runCurrent()
        model.setFilter(LibraryFilter.Recent)
        runCurrent()
        assertEquals(listOf("a-/x.md", "a/x.md", "a/z/x.md", "e\u0301/x.md", "é/x.md", "\uE000/x.md", "\uD800\uDC00/x.md"),
            paths(model))
    }

    @Test
    fun `empty no-match and initial data failure support retry and clearing filters`() = runTest {
        var failScan = true
        val model = model(wrap = { prompts -> object : PromptStore by prompts {
            override fun listFiles() = if (failScan) throw StoreError.IOFailure else prompts.listFiles()
        } })
        model.refresh()
        runCurrent()
        assertEquals(LibraryContent.FAILED, model.state.value.content)
        assertEquals(LibraryFailure.DATA, model.state.value.failure)
        model.setQuery("no match")
        runCurrent()
        assertEquals("no match", model.state.value.query)
        assertEquals(LibraryContent.FAILED, model.state.value.content)
        failScan = false
        model.refresh()
        runCurrent()
        assertEquals(LibraryContent.EMPTY, model.state.value.content)
        assertNull(model.state.value.failure)
        model.clearFilters()
        runCurrent()
        assertEquals(LibraryFilter.All, model.state.value.filter)
        assertEquals(0, model.state.value.sections.single { it.filter == LibraryFilter.All }.count)
        put(libraryDir.resolve("new.md"))
        model.refresh()
        runCurrent()
        model.setQuery("no match")
        runCurrent()
        assertEquals(LibraryContent.NO_MATCH, model.state.value.content)
        model.clearFilters()
        runCurrent()
        assertEquals(listOf("new.md"), paths(model))
    }

    @Test
    fun `failed foreground rescan keeps cached search filters counts and selection usable`() = runTest {
        fixtures()
        val model = loadedModel()
        val selected = model.state.value.rows.first()
        model.select(selected.selection)
        Files.move(libraryDir, filesDir.resolve("unavailable-library"))
        model.refresh()
        runCurrent()
        assertEquals(LibraryContent.READY, model.state.value.content)
        assertEquals(LibraryFailure.DATA, model.state.value.failure)
        assertEquals(4, model.state.value.rows.size)
        assertFalse(model.state.value.refreshing)
        // StateFlow can conflate the transient busy state and the same final error on retry.
        model.refresh()
        runCurrent()
        assertEquals(LibraryFailure.DATA, model.state.value.failure)
        assertEquals(4, model.state.value.rows.size)
        model.setQuery("rvw")
        model.setFilter(LibraryFilter.Favourites)
        runCurrent()
        assertEquals(listOf("Work/code/review.md"), paths(model))
        assertEquals(selected, model.state.value.selectedPrompt)
        assertNotNull(repository.state.value.error) // Memory search must not erase the failed disk operation.
        Files.move(filesDir.resolve("unavailable-library"), libraryDir)
        model.refresh()
        runCurrent()
        assertNull(model.state.value.failure)
    }

    @Test
    fun `an older async projection cannot replace a newer completed load or its selection`() = runTest {
        fixtures()
        val worker = QueuedDispatcher()
        val model = model(worker = worker)
        model.refresh()
        runCurrent()
        worker.runAll()
        runCurrent()
        val selection = model.state.value.rows.first().selection
        model.select(selection)
        model.setQuery("notes")
        runCurrent()
        model.setQuery("rvw")
        runCurrent()
        assertEquals(2, worker.pending)
        worker.runLast()
        runCurrent()
        assertEquals(listOf("Work/code/review.md"), paths(model))
        worker.runAll()
        runCurrent()
        assertEquals("rvw", model.state.value.query)
        assertEquals(listOf("Work/code/review.md"), paths(model))
        assertEquals(selection, model.state.value.selectedPrompt?.selection)
    }

    @Test
    fun `selection follows an unambiguous assigned rename and a removed folder falls back to All`() = runTest {
        put(libraryDir.resolve("Old/a.md"))
        val model = loadedModel()
        model.select(model.state.value.rows.single().selection)
        model.toggleFavorite(model.state.value.rows.single().selection)
        runCurrent()
        val row = model.state.value.rows.single()
        model.setFilter(LibraryFilter.Folder("Old"))
        runCurrent()
        repository.withLibrary { _, editing -> assertIs<EditResult.Saved>(editing.move("Old/a.md", "New", row.stamp)) }
        runCurrent()
        assertEquals(LibraryFilter.All, model.state.value.filter)
        assertEquals(row.selection.identity, model.state.value.selectedPrompt?.selection?.identity)
        assertEquals("New/a.md", model.state.value.selectedPrompt?.selection?.relativePath)
    }

    private fun fixtures() {
        put(libraryDir.resolve("Work/code/review.md"), "---\ntitle: Review a diff\ndescription: Inspect changes\ntags: [Code, CODE, '']\nfavorite: true\n---\nShow the diff".encodeToByteArray())
        put(libraryDir.resolve("Work/notes.md"), "---\ntitle: Zulu notes\ntags: [code]\n---\nnotes".encodeToByteArray())
        put(libraryDir.resolve("Work2/strasse.md"), "---\ntitle: Straße\ntags: [Straße]\n---\nbody".encodeToByteArray())
        put(libraryDir.resolve("plain.md"), "---\ntitle: plain\n---\nbody".encodeToByteArray())
    }

    private fun model(worker: CoroutineDispatcher = dispatcher,
        wrap: (AndroidPromptStore) -> PromptStore = { it }): LibraryViewModel {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val library = library(prompts = wrap(prompts))
        repository = LibraryRepository(library, EditingService(library), prompts, dispatcher)
        return LibraryViewModel(repository, worker).also { models.put("library", it) }
    }

    private fun TestScope.loadedModel(wrap: (AndroidPromptStore) -> PromptStore = { it }): LibraryViewModel =
        model(wrap = wrap).also { it.refresh(); runCurrent() }

    private fun paths(model: LibraryViewModel) = model.state.value.rows.map { it.selection.relativePath }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val tasks = mutableListOf<Runnable>()
        val pending: Int get() = tasks.size
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.add(block) }
        fun runLast() { tasks.removeAt(tasks.lastIndex).run() }
        fun runAll() { while (tasks.isNotEmpty()) tasks.removeAt(0).run() }
    }
}
