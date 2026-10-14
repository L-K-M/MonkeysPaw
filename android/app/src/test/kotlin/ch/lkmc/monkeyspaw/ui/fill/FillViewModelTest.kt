package ch.lkmc.monkeyspaw.ui.fill

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.entry.EntrySource
import ch.lkmc.monkeyspaw.entry.FillRoute
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class FillViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val clipboard = TestClipboard()
    private val events = mutableListOf<String>()
    private var now = Instant.parse("2021-01-01T00:30:00Z")
    private var zone = ZoneId.of("America/New_York")
    private var clockSamples = 0
    private var zoneSamples = 0
    private var modelNumber = 0
    private var failRemember = false
    private var failUsage = false
    private var failZone = false
    private lateinit var core: LibraryService
    private lateinit var repository: LibraryRepository
    private lateinit var fill: FillService

    @BeforeTest
    fun setMain() { Dispatchers.setMain(dispatcher) }

    @AfterTest
    fun clearModels() {
        models.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `fields retain body order metadata defaults and remembered empty values`() = runTest {
        putPrompt("""
            ---
            fields:
              choice:
                type: choice
                label: Language
                description: Pick a language.
                options: [{label: Rust label, value: Rust}, Python]
                default: Rust
              first:
                type: multiline
                optional: true
                default: fallback
              fresh:
                default: new
                remember: false
            ---
            {{first}}/{{implicit}}/{{choice}}/{{fresh}}/{{first}}
        """.trimIndent())
        graph()
        val identity = core.load("a.md").identity
        core.values.record(identity, mapOf("first" to "", "choice" to "Python", "fresh" to "old", "stale" to "retained"))
        val model = openModel()
        val fields = model.state.value.fields
        assertEquals(listOf("first", "implicit", "choice", "fresh"), fields.map { it.field.name })
        assertEquals(listOf(FieldKind.MULTILINE, FieldKind.TEXT, FieldKind.CHOICE, FieldKind.TEXT), fields.map { it.field.kind })
        assertTrue(fields.map { it.value } == listOf("", "", "Python", "new"))
        assertEquals("Language", fields[2].field.label)
        assertEquals("Pick a language.", fields[2].field.description)
        assertEquals("Rust label", fields[2].field.options.first().label)
        assertTrue(fields[0].field.optional)
        assertFalse(fields[3].field.remember)
        assertFalse(model.state.value.copyEnabled)
        assertTrue(core.usage.useEvents(identity).isEmpty())
        assertEquals(0, clipboard.reads)
    }

    @Test
    fun `required nontrimmed text choices and explicit empty override gate every copy`() = runTest {
        putPrompt("---\nfields:\n  f:\n    default: fallback\n  c:\n    type: choice\n    options: [one, two]\n---\n{{f}} {{c}}")
        graph()
        val model = openModel()
        assertIs<PromptRenderError.MissingRequiredValue>(blocked(model))
        model.copy()
        model.setValue("f", " ")
        model.setValue("c", "bad")
        assertIs<PromptRenderError.InvalidChoiceValue>(blocked(model))
        assertFalse(model.state.value.copyEnabled)
        model.copy()
        model.setValue("c", "two")
        assertTrue(model.state.value.copyEnabled)
        assertPreview(model, "  two")
        val before = model.state.value
        model.setValue("unknown", "ignored")
        assertEquals(before, model.state.value)
        model.setValue("f", "")
        assertIs<PromptRenderError.MissingRequiredValue>(blocked(model))
        model.copy()
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `optional empty choice is copied and remembered ahead of its default on reopening`() = runTest {
        putPrompt("---\nfields:\n  c:\n    type: choice\n    options: [one, two]\n    default: one\n    optional: true\n---\nA{{c}}B")
        graph()
        val model = openModel()
        model.setValue("c", "")
        assertTrue(model.state.value.copyEnabled)
        model.copy()
        runCurrent()
        assertTrue(clipboard.text == "AB")
        assertTrue(core.values.rememberedValues(core.load("a.md").identity)["c"] == "")
        val reopened = openModel()
        assertTrue(reopened.state.value.fields.single().value.isEmpty())
        assertPreview(reopened, "AB")
    }

    @Test
    fun `invalid future and forensic prompts expose issues and never write or learn`() = runTest {
        val prompts = listOf(
            "---\ntitle: [\n---\nbody".encodeToByteArray(),
            "---\nformat: 2\n---\nbody".encodeToByteArray(),
            byteArrayOf(0xff.toByte()),
            ByteArray(Limits.maxPromptBytes + 1) { 'a'.code.toByte() },
        )
        for ((index, bytes) in prompts.withIndex()) put(libraryDir.resolve("$index.md"), bytes)
        graph()
        for (index in prompts.indices) {
            val model = openModel("$index.md")
            assertTrue(model.state.value.issues.isNotEmpty())
            assertFalse(model.state.value.canRender)
            assertFalse(model.state.value.copyEnabled)
            assertIs<FillPreview.Blocked>(model.state.value.preview)
            model.copy()
        }
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `warning-only and fieldless prompts always show preview and wait for a copy intent`() = runTest {
        putPrompt("---\nfields:\n  unused:\n    default: value\n---\nPlain text")
        graph()
        val model = openModel()
        assertEquals(FillPhase.EDITING, model.state.value.phase)
        assertTrue(model.state.value.fields.isEmpty())
        assertTrue(model.state.value.issues.all { it.severity == PromptIssueSeverity.WARNING })
        assertPreview(model, "Plain text")
        assertTrue(model.state.value.copyEnabled)
        assertEquals(0, clipboard.writes)
        assertFalse(model.state.value.shouldFinish)
        model.copy()
        runCurrent()
        assertTrue(model.state.value.shouldFinish)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertFalse(Files.exists(stateDir.resolve("values.json")))
    }

    @Test
    fun `pending snapshot permits edits and retains one local clock zone and clipboard sample`() = runTest {
        val locale = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("th-TH"))
            putPrompt("{{f}}/{{clipboard}}/{{date}}/{{time}}/{{clipboard}}")
            graph()
            clipboard.deferred = true
            val model = openModel()
            assertFalse(model.state.value.builtinsResolved)
            model.setValue("f", "typed")
            assertIs<PromptRenderError.MissingBuiltin>(blocked(model))
            model.copy()
            assertEquals(0, clipboard.writes)
            assertEquals(1, clipboard.reads)
            assertEquals(1, clockSamples)
            assertEquals(1, zoneSamples)
            now = Instant.parse("2022-02-02T03:00:00Z")
            zone = ZoneId.of("Asia/Tokyo")
            model.setForeground(false)
            model.setForeground(true)
            repository.refresh()
            model.setValue("f", "edited")
            clipboard.complete("snapshot")
            runCurrent()
            assertPreview(model, "edited/snapshot/2020-12-31/19:30/snapshot")
            assertTrue(model.state.value.copyEnabled)
            assertEquals(1, clipboard.reads)
            assertEquals(1, clockSamples)
            assertEquals(1, zoneSamples)
        } finally { Locale.setDefault(locale) }
    }

    @Test
    fun `preparation completing in background waits for foreground before snapshot and copy`() = runTest {
        putPrompt("{{clipboard}}")
        graph()
        val model = model()
        model.setForeground(true)
        model.open("a.md")
        model.setForeground(false)
        runCurrent()
        assertEquals(FillPhase.EDITING, model.state.value.phase)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clockSamples)
        assertFalse(model.state.value.copyEnabled)
        model.copy()
        model.setForeground(true)
        runCurrent()
        assertEquals(1, clipboard.reads)
        assertTrue(model.state.value.copyEnabled)
        model.setForeground(false)
        model.copy()
        assertEquals(0, clipboard.writes)
        model.setForeground(true)
        runCurrent()
        assertEquals(1, clipboard.reads)
    }

    @Test
    fun `clock zone failure is visible keeps the form editable and prevents copy without learning`() = runTest {
        putPrompt("{{f}}/{{date}}")
        graph()
        failZone = true
        val model = openModel()
        assertEquals(FillPhase.EDITING, model.state.value.phase)
        assertEquals(FillFailure.SNAPSHOT, model.state.value.failure)
        model.setValue("f", "draft")
        assertTrue(model.state.value.values["f"] == "draft")
        assertEquals(FillFailure.SNAPSHOT, model.state.value.failure)
        model.copy()
        model.setForeground(false)
        model.setForeground(true)
        runCurrent()
        assertFalse(model.state.value.builtinsResolved)
        assertEquals(1, zoneSamples)
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
        model.cancel()
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
    }

    @Test
    fun `snapshot callback reaches state only through the Main dispatcher`() = runTest {
        putPrompt("{{clipboard}}")
        graph()
        clipboard.deferred = true
        val model = openModel()
        Thread { clipboard.complete("snapshot") }.apply { start(); join() }
        assertFalse(model.state.value.builtinsResolved)
        runCurrent()
        assertTrue(model.state.value.builtinsResolved)
        assertPreview(model, "snapshot")
    }

    @Test
    fun `null empty and failed clipboard reads resolve to empty and allow copy`() = runTest {
        putPrompt("A{{clipboard}}B")
        graph()
        for (mode in listOf("null", "empty", "failure")) {
            clipboard.text = if (mode == "empty") "" else null
            clipboard.failRead = mode == "failure"
            val model = openModel()
            assertTrue(model.state.value.builtinsResolved)
            assertTrue(model.state.value.copyEnabled)
            assertPreview(model, "AB")
            model.copy()
            runCurrent()
            assertTrue(clipboard.text == "AB")
        }
        assertEquals(3, clipboard.reads)
        assertEquals(3, clipboard.writes)
    }

    @Test
    fun `browsing and forms without clipboard never read clipboard and preparation learns nothing`() = runTest {
        putPrompt("{{f}}/{{date}}/{{time}}")
        graph()
        val browser = LibraryViewModel(repository, dispatcher).also { models.put("browser", it) }
        browser.refresh()
        runCurrent()
        browser.select(browser.state.value.rows.single().selection)
        browser.setQuery("f")
        runCurrent()
        val before = stateBytes()
        val model = openModel()
        model.setValue("f", "raw")
        model.cancel()
        runCurrent()
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertTrue(before == stateBytes())
        val reopened = openModel()
        reopened.setValue("f", "raw")
        reopened.copy()
        runCurrent()
        assertEquals(0, clipboard.reads)
        assertEquals(1, clipboard.writes)
    }

    @Test
    fun `preview and copy insert raw values in one pass using the held clipboard snapshot`() = runTest {
        putPrompt("{{f}}|{{f}}|{{clipboard}}|\\{{literal}}")
        graph()
        clipboard.text = "{{f}}"
        val model = openModel()
        model.setValue("f", "{{clipboard}}\n")
        val expected = "{{clipboard}}\n|{{clipboard}}\n|{{f}}|{{literal}}"
        assertPreview(model, expected)
        clipboard.text = "changed elsewhere"
        model.copy()
        runCurrent()
        assertTrue(clipboard.text == expected)
        assertEquals(1, clipboard.reads)
    }

    @Test
    fun `successful copy writes then remembers then records usage before finishing`() = runTest {
        putPrompt("---\nfields:\n  fresh:\n    remember: false\n---\n{{keep}} {{fresh}}")
        graph()
        val model = openModel()
        model.setValue("keep", "remembered")
        model.setValue("fresh", "session only")
        clipboard.onWrite = {
            assertEquals(FillPhase.COPYING, model.state.value.phase)
            assertFalse(model.state.value.shouldFinish)
            assertTrue(core.values.rememberedValues(core.load("a.md").identity).isEmpty())
            assertTrue(core.usage.useEvents(core.load("a.md").identity).isEmpty())
        }
        model.copy()
        assertEquals(listOf("write"), events)
        assertEquals(FillPhase.COPYING, model.state.value.phase)
        assertFalse(model.state.value.shouldFinish)
        runCurrent()
        assertEquals(listOf("write", "remember", "usage"), events)
        assertTrue(model.state.value.shouldFinish)
        events.add("finish")
        assertEquals(listOf("write", "remember", "usage", "finish"), events)
        val identity = core.load("a.md").identity
        assertTrue(core.values.rememberedValues(identity) == mapOf("keep" to "remembered"))
        assertEquals(listOf(now), core.usage.useEvents(identity))
        assertEquals(1, repository.state.value.snapshot.prompts.single().useEvents.size)
    }

    @Test
    fun `failed write keeps draft and snapshot teaches nothing and retries once`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        graph()
        val identity = core.load("a.md").identity
        core.values.record(identity, mapOf("f" to "prior"))
        core.usage.recordUse(identity)
        events.clear()
        clipboard.text = "opening snapshot"
        val model = openModel()
        val before = stateBytes()
        model.setValue("f", "draft")
        val preview = model.state.value.preview
        clipboard.failWrite = true
        model.copy()
        runCurrent()
        assertEquals(FillPhase.EDITING, model.state.value.phase)
        assertEquals(FillFailure.CLIPBOARD, model.state.value.failure)
        assertTrue(model.state.value.values["f"] == "draft")
        assertEquals(preview, model.state.value.preview)
        assertTrue(before == stateBytes())
        assertFalse(model.state.value.shouldFinish)
        assertTrue(events.isEmpty())
        clipboard.failWrite = false
        model.copy()
        model.copy()
        runCurrent()
        assertEquals(listOf("write", "remember", "usage"), events)
        assertEquals(1, clipboard.reads)
        assertEquals(2, clipboard.writes)
        assertEquals(2, core.usage.useEvents(identity).size)
    }

    @Test
    fun `remember failure still records usage and leaves a post-copy warning until Done`() = runTest {
        putPrompt("{{f}}")
        graph()
        val model = openModel()
        model.setValue("f", "copied")
        failRemember = true
        model.copy()
        runCurrent()
        assertEquals(FillPhase.COPIED, model.state.value.phase)
        assertEquals(listOf(FillWarning.REMEMBERED_VALUES_NOT_SAVED), model.state.value.warnings)
        assertFalse(model.state.value.shouldFinish)
        assertTrue(clipboard.text == "copied")
        assertTrue(core.values.rememberedValues(core.load("a.md").identity).isEmpty())
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        model.copy()
        model.setValue("f", "late")
        assertEquals(1, clipboard.writes)
        model.cancel()
        assertTrue(model.state.value.shouldFinish)
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
    }

    @Test
    fun `usage failure keeps successfully remembered values and reports its own warning`() = runTest {
        putPrompt("{{f}}")
        graph()
        val model = openModel()
        model.setValue("f", "copied")
        failUsage = true
        model.copy()
        runCurrent()
        assertEquals(listOf(FillWarning.USAGE_NOT_SAVED), model.state.value.warnings)
        assertTrue(core.values.rememberedValues(core.load("a.md").identity)["f"] == "copied")
        assertTrue(core.usage.useEvents(core.load("a.md").identity).isEmpty())
        assertTrue(repository.state.value.snapshot.prompts.single().useEvents.isEmpty())
        assertFalse(model.state.value.shouldFinish)
    }

    @Test
    fun `corrupt remembered state uses defaults without reset and both learning failures warn`() = runTest {
        putPrompt("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        graph()
        val rejected = "{\"version\":99,\"values\":{}}".encodeToByteArray()
        put(stateDir.resolve("values.json"), rejected)
        val model = openModel()
        assertEquals(listOf(FillWarning.REMEMBERED_VALUES_UNAVAILABLE), model.state.value.warnings)
        assertPreview(model, "fallback")
        failUsage = true
        model.copy()
        runCurrent()
        assertTrue(Files.readAllBytes(stateDir.resolve("values.json")).contentEquals(rejected))
        assertEquals(listOf(FillWarning.REMEMBERED_VALUES_UNAVAILABLE, FillWarning.REMEMBERED_VALUES_NOT_SAVED,
            FillWarning.USAGE_NOT_SAVED), model.state.value.warnings)
        assertTrue(clipboard.text == "fallback")
    }

    @Test
    fun `a post-copy unavailable library reports persistence warning without repeating copy`() = runTest {
        putPrompt("{{f}}")
        graph()
        val model = openModel()
        model.setValue("f", "copied")
        clipboard.onWrite = { Files.move(libraryDir, filesDir.resolve("unavailable")) }
        model.copy()
        runCurrent()
        assertEquals(FillPhase.COPIED, model.state.value.phase)
        assertEquals(listOf(FillWarning.REMEMBERED_VALUES_NOT_SAVED, FillWarning.USAGE_NOT_SAVED), model.state.value.warnings)
        model.copy()
        assertEquals(1, clipboard.writes)
        assertTrue(events == listOf("write"))
    }

    @Test
    fun `reentrant copy cancel open and edits are ignored while copying captured fields`() = runTest {
        putPrompt("{{f}}")
        graph()
        val model = openModel()
        model.setValue("f", "captured")
        clipboard.onWrite = {
            model.copy()
            model.cancel()
            model.open("other.md")
            model.setValue("f", "late")
        }
        model.copy()
        model.copy()
        model.cancel()
        model.setValue("f", "later")
        assertEquals(FillPhase.COPYING, model.state.value.phase)
        runCurrent()
        assertTrue(clipboard.text == "captured")
        assertTrue(core.values.rememberedValues(core.load("a.md").identity)["f"] == "captured")
        assertEquals(1, clipboard.writes)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertTrue(model.state.value.shouldFinish)
    }

    @Test
    fun `cancelled snapshot cannot update a closed form or the new form snapshot`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.deferred = true
        val old = openModel()
        old.setValue("f", "cancelled")
        old.cancel()
        val closed = old.state.value
        val reopened = openModel()
        reopened.setValue("f", "new")
        clipboard.complete("late old")
        runCurrent()
        assertEquals(closed, old.state.value)
        assertFalse(reopened.state.value.builtinsResolved)
        clipboard.complete("new snapshot")
        runCurrent()
        assertPreview(reopened, "new/new snapshot")
        assertTrue(reopened.state.value.copyEnabled)
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `duplicate snapshot completion and completion after copy cannot change the result`() = runTest {
        putPrompt("{{clipboard}}")
        graph()
        clipboard.deferred = true
        val model = openModel()
        val completion = clipboard.pending.single()
        completion("snapshot")
        runCurrent()
        val before = model.state.value
        completion("duplicate")
        runCurrent()
        assertEquals(before, model.state.value)
        model.copy()
        runCurrent()
        val copied = model.state.value
        completion("late")
        runCurrent()
        assertEquals(copied, model.state.value)
        assertTrue(clipboard.text == "snapshot")
        assertEquals(1, clipboard.writes)
    }

    @Test
    fun `late load after cancellation stays closed and duplicate opens do not queue another load`() = runTest {
        putPrompt("{{clipboard}}")
        val worker = QueuedDispatcher()
        graph(worker)
        val model = model()
        model.setForeground(true)
        model.open("a.md")
        model.open("other.md")
        model.copy()
        runCurrent()
        assertEquals(1, worker.pending)
        worker.runAll() // Complete IO, but leave its reply queued on Main.
        model.cancel()
        runCurrent()
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `load failures and malformed paths expose retry and never read clipboard`() = runTest {
        putPrompt("{{clipboard}}")
        graph()
        val model = model()
        model.setForeground(true)
        model.open("missing.md")
        runCurrent()
        assertEquals(FillPhase.FAILED, model.state.value.phase)
        assertEquals(FillFailure.LOAD, model.state.value.failure)
        model.copy()
        putPrompt("{{clipboard}}", "missing.md")
        model.retry()
        model.retry()
        runCurrent()
        assertTrue(model.state.value.copyEnabled)
        assertEquals(1, clipboard.reads)
        assertEquals(0, clipboard.writes)
        val invalid = model()
        invalid.setForeground(true)
        invalid.open("../outside.md")
        runCurrent()
        assertEquals(FillPhase.FAILED, invalid.state.value.phase)
        assertEquals(1, clipboard.reads)
    }

    @Test
    fun `destruction after a successful write still learns once and rejects the late finish`() = runTest {
        putPrompt("{{f}}")
        val worker = QueuedDispatcher()
        graph(worker)
        val model = model()
        model.setForeground(true)
        model.open("a.md")
        runCurrent()
        worker.runAll()
        runCurrent()
        model.setValue("f", "copied")
        model.copy()
        assertEquals(FillPhase.COPYING, model.state.value.phase)
        assertEquals(1, worker.pending)
        models.clear()
        val retired = model.state.value
        worker.runAll()
        runCurrent()
        assertEquals(retired, model.state.value)
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertEquals(listOf("write", "remember", "usage"), events)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertTrue(core.values.rememberedValues(core.load("a.md").identity)["f"] == "copied")
    }

    @Test
    fun `repeated open while editing retains fields path and the opening clipboard snapshot`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        putPrompt("Other", "b.md")
        clipboard.text = "opening sample"
        graph()
        val model = openModel()
        model.setValue("f", "held draft")
        val held = model.state.value
        clipboard.text = "changed clipboard"
        repeat(3) {
            model.open("a.md")
            model.open("b.md")
        }
        runCurrent()
        assertEquals(held, model.state.value)
        assertEquals(1, clipboard.reads)
        assertPreview(model, "held draft/opening sample")
        model.copy()
        runCurrent()
        assertEquals("held draft/opening sample", clipboard.text)
        assertEquals(1, clipboard.writes)
        assertTrue(model.state.value.shouldFinish)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertTrue(core.usage.useEvents(core.load("b.md").identity).isEmpty())
    }

    @Test
    fun `Back from picker or form finishes without clipboard publication and a new session can open`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        graph()
        val picker = model()
        picker.setForeground(true)
        picker.cancel()
        assertTrue(picker.state.value.shouldFinish)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)

        val form = openModel()
        form.setValue("f", "discarded draft")
        form.cancel()
        runCurrent()
        assertTrue(form.state.value.shouldFinish)
        assertEquals(0, clipboard.writes)
        val identity = core.load("a.md").identity
        assertTrue(core.values.rememberedValues(identity).isEmpty())
        assertTrue(core.usage.useEvents(identity).isEmpty())

        val next = openModel()
        assertEquals(FillPhase.EDITING, next.state.value.phase)
        assertFalse(next.state.value.shouldFinish)
        assertEquals("", next.state.value.values["f"])
        assertEquals(2, clipboard.reads)
    }

    @Test
    fun `warm library selection opens a held picker and external reentry preserves its form`() = runTest {
        putPrompt("{{f}}/{{clipboard}}", "b.md")
        graph()
        val held = model()
        assertEquals(FillPhase.PICKING, held.state.value.phase)
        FillRoute.sanitize(null, "b.md").promptPath?.let(held::open)
        runCurrent()
        assertEquals(FillPhase.EDITING, held.state.value.phase)
        assertEquals(0, clipboard.reads, "A background Library activation cannot sample the clipboard")
        clipboard.text = "opening sample"
        held.setForeground(true)
        runCurrent()
        held.setValue("f", "selected from Library")
        val draft = held.state.value
        for (source in listOf(EntrySource.TILE, EntrySource.SHORTCUT, EntrySource.WIDGET)) {
            FillRoute.sanitize(source.action, "ignored.md").promptPath?.let(held::open)
        }
        FillRoute.sanitize(null, "ignored.md").promptPath?.let(held::open)
        runCurrent()
        assertEquals(draft, held.state.value)
        assertEquals(1, clipboard.reads)
        held.copy()
        runCurrent()
        assertTrue(held.state.value.shouldFinish)
        assertEquals("selected from Library/opening sample", clipboard.text)
        assertEquals(1, core.usage.useEvents(core.load("b.md").identity).size)
    }

    private fun putPrompt(source: String, path: String = "a.md") = put(libraryDir.resolve(path), source.encodeToByteArray())

    private fun graph(worker: CoroutineDispatcher = dispatcher) {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val state = AndroidStateStore(stateDir.toFile())
        val recordingState = object : StateStore by state {
            override fun writePrivate(bytes: ByteArray, path: String) {
                if (failRemember) throw StoreError.IOFailure
                events.add("remember")
                state.writePrivate(bytes, path)
            }
            override fun write(bytes: ByteArray, path: String) {
                if (failUsage && path.startsWith("usage/")) throw StoreError.IOFailure
                events.add("usage")
                state.write(bytes, path)
            }
        }
        val clock = AndroidClock({ clockSamples++; now }, {
            zoneSamples++
            if (failZone) throw IllegalStateException("private zone error")
            zone
        })
        core = LibraryService(prompts, recordingState, clock, Entropy { count -> ByteArray(count) })
        repository = LibraryRepository(core, EditingService(core), prompts, worker)
        fill = FillService(core, clipboard, clock::zone)
        clipboard.events = events
    }

    private fun model(): FillViewModel = FillViewModel(repository, fill).also { models.put("fill-${modelNumber++}", it) }

    private fun TestScope.openModel(path: String = "a.md"): FillViewModel = model().also {
        it.setForeground(true)
        it.open(path)
        runCurrent()
    }

    private fun blocked(model: FillViewModel) = assertIs<FillPreview.Blocked>(model.state.value.preview).error
    private fun assertPreview(model: FillViewModel, expected: String) {
        assertTrue(assertIs<FillPreview.Rendered>(model.state.value.preview).text == expected, "Rendered preview differs")
    }

    private fun stateBytes(): Map<String, List<Byte>> {
        if (!Files.exists(stateDir)) return emptyMap()
        return Files.walk(stateDir).use { paths -> paths.filter { Files.isRegularFile(it) }.toList()
            .associate { stateDir.relativize(it).toString() to Files.readAllBytes(it).toList() } }
    }

    private class TestClipboard : Clipboard {
        var text: String? = null
        var reads = 0
        var writes = 0
        var deferred = false
        var failRead = false
        var failWrite = false
        var onWrite: (() -> Unit)? = null
        var events: MutableList<String> = mutableListOf()
        val pending = mutableListOf<(String?) -> Unit>()
        override fun readText(completion: (String?) -> Unit) {
            reads++
            if (failRead) throw IllegalStateException("private service error")
            if (deferred) pending.add(completion) else completion(text)
        }
        override fun writeText(text: String) {
            writes++
            if (failWrite) throw StoreError.IOFailure
            this.text = text
            events.add("write")
            onWrite?.invoke()
        }
        fun complete(text: String?) { pending.removeAt(0)(text) }
    }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val tasks = mutableListOf<Runnable>()
        val pending: Int get() = tasks.size
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.add(block) }
        fun runAll() { while (tasks.isNotEmpty()) tasks.removeAt(0).run() }
    }
}
