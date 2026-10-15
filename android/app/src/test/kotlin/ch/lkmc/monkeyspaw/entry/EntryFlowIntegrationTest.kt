package ch.lkmc.monkeyspaw.entry

import android.content.Intent.*
import android.text.InputType.TYPE_CLASS_TEXT
import android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ime.*
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModelFactory
import ch.lkmc.monkeyspaw.ui.fill.*
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.*

/** Executes shared models and real private stores; framework entry adapters remain device checks. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class EntryFlowIntegrationTest : EntryFlowFixture() {
    @Test fun `every entry picks the shared Fill and orders one effect before learning and finish`() = runTest {
        for (lane in Lane.entries) {
            prepare(lane.name)
            val form = start(lane, "{{literal}}\r\n雪")
            assertEquals(FillPhase.PICKING, form.state.value.phase)
            assertEquals(0, clipboard.reads)
            pick(lane, form)
            assertEquals(1, creations)
            assertEquals(1, clipboard.reads)
            assertTrue(effects.isEmpty())
            if (lane in listOf(Lane.EDITABLE_SELECTION, Lane.READ_ONLY_SELECTION, Lane.SHARE)) {
                assertEquals("keep", form.state.value.capturedText?.selectedField)
                form.selectCapturedField("once")
                assertEquals("ready", form.state.value.values["keep"])
                form.selectCapturedField(null)
            }
            form.setValue("keep", "{{literal}}\r\n雪")
            form.setValue("once", "session only")
            val preview = assertIs<FillPreview.Rendered>(form.state.value.preview).text
            clipboard.text = "changed after activation"
            beforeEffect = {
                assertTrue(core.values.rememberedValues(identity).isEmpty())
                assertTrue(core.usage.useEvents(identity).isEmpty())
                assertEquals(FillPhase.DELIVERING, form.state.value.phase)
            }
            tap(lane, form)
            tap(lane, form)
            assertEquals(listOf("effect"), events)
            assertFalse(form.state.value.shouldFinish)
            runCurrent()
            if (lane == Lane.IME) assertEquals(listOf("effect", "remember", "usage", "switch"), events)
            else assertEquals(listOf("effect", "remember", "usage"), events)
            assertTrue(form.state.value.shouldFinish)
            assertTrue(effects.single() == preview)
            assertTrue(core.values.rememberedValues(identity) == mapOf("keep" to "{{literal}}\r\n雪"))
            assertEquals(1, core.usage.useEvents(identity).size)
            assertEquals(if (lane == Lane.IME || lane == Lane.EDITABLE_SELECTION) 0 else 1, clipboard.writes)
            assertEquals(1, clipboard.reads)
            release()
        }
    }

    @Test fun `M8 repeated tile shortcut and widget entries preserve the held form and next entry is fresh`() = runTest {
        prepare("m8")
        val form = start(Lane.TILE)
        pick(Lane.TILE, form)
        form.setValue("keep", "held")
        val preview = form.state.value.preview
        for (source in listOf(EntrySource.TILE, EntrySource.SHORTCUT, EntrySource.WIDGET)) {
            val request = FillRoute.sanitize(source.action, "untrusted.md", "untrusted token")
            assertEquals(source, request.source)
            assertNull(request.promptPath)
            assertNull(request.handoffToken)
            // FillActivity's repeated-entry seam forwards only a permitted Library path.
            request.promptPath?.let(form::open)
            form.setForeground(false)
            form.setForeground(true)
        }
        form.open("another.md")
        runCurrent()
        assertEquals(preview, form.state.value.preview)
        assertEquals(1, clipboard.reads)
        form.copy()
        runCurrent()
        assertTrue(form.state.value.shouldFinish)
        form.endSession()
        val next = start(Lane.WIDGET)
        assertNotSame(form, next)
        assertEquals(FillPhase.PICKING, next.state.value.phase)
        pick(Lane.WIDGET, next)
        assertEquals("held", next.state.value.values["keep"])
        assertEquals(2, clipboard.reads)
        assertEquals(1, effects.size)
    }

    @Test fun `accepted IME effect survives owner destruction without switching a new target`() = runTest {
        prepare("retirement")
        val form = start(Lane.IME)
        pick(Lane.IME, form)
        form.setValue("keep", "accepted")
        beforeEffect = { controller!!.destroy() }
        tap(Lane.IME, form)
        runCurrent()
        assertEquals(FillPhase.CLOSED, form.state.value.phase)
        assertTrue(form.state.value.values.isEmpty())
        assertEquals(listOf("effect", "remember", "usage"), events)
        assertTrue(core.values.rememberedValues(identity) == mapOf("keep" to "accepted"))
        assertEquals(1, core.usage.useEvents(identity).size)
        assertEquals(1, effects.size)
    }
}

/** Shared only by the N8 integration/privacy tests. No Android service or Compose stubs execute. */
@OptIn(ExperimentalCoroutinesApi::class)
internal abstract class EntryFlowFixture : TemporaryFiles() {
    protected enum class Lane { IME, EDITABLE_SELECTION, READ_ONLY_SELECTION, SHARE, TILE, SHORTCUT, WIDGET }
    protected val worker = StandardTestDispatcher()
    protected lateinit var directory: Path
    protected lateinit var core: LibraryService
    protected lateinit var repository: LibraryRepository
    protected lateinit var factory: FillViewModelFactory
    protected lateinit var share: ShareEntry
    protected val identity get() = core.load("prompt.md").identity
    protected val clipboard = TestClipboard()
    protected val events = mutableListOf<String>()
    protected val effects = mutableListOf<String>()
    protected var creations = 0
    protected var failEffect = false
    protected var failLaunch = false
    protected var errorText = "Effect unavailable"
    protected var beforeEffect: () -> Unit = {}
    protected var editor = ImeEditor(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, 0, Any())
    protected var controller: ImeSessionController? = null
    protected val handoffs = FillHandoffStore()
    protected val tokens = mutableListOf<String>()
    private val owners = ViewModelStore()
    private var observer: CoroutineScope? = null
    private lateinit var picker: LibraryViewModel

    @BeforeTest fun installMain() { Dispatchers.setMain(worker) }
    @AfterTest fun dispose() { release(); Dispatchers.resetMain() }

    protected suspend fun prepare(name: String) {
        release()
        directory = temporary.resolve(name)
        put(directory.resolve("files/library/prompt.md"), ("---\ntitle: Integration\nfields:\n" +
            "  keep:\n    type: multiline\n    default: ready\n" +
            "  once:\n    remember: false\n    optional: true\n---\n{{keep}}|{{once}}|{{clipboard}}").encodeToByteArray())
        Files.createDirectories(directory.resolve("cache"))
        Files.createDirectories(directory.resolve("logs"))
        events.clear(); effects.clear(); tokens.clear()
        creations = 0
        failEffect = false
        failLaunch = false
        beforeEffect = {}
        clipboard.reads = 0; clipboard.writes = 0; clipboard.pending.clear(); clipboard.deferred = false
        clipboard.text = "opening clipboard"
        editor = ImeEditor(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, 0, Any())
        val prompts = AndroidPromptStore(directory.resolve("files/library").toFile())
        val state = AndroidStateStore(directory.resolve("files/state").toFile())
        val recording = object : StateStore by state {
            override fun writePrivate(bytes: ByteArray, path: String) {
                state.writePrivate(bytes, path)
                events += "remember"
            }
            override fun write(bytes: ByteArray, path: String) {
                state.write(bytes, path)
                events += "usage"
            }
        }
        val clock = AndroidClock({ Instant.parse("2026-10-15T12:00:00Z") }, { ZoneOffset.UTC })
        var draw = 0
        core = LibraryService(prompts, recording, clock, Entropy { count -> ByteArray(count) { (draw++).toByte() } })
        repository = LibraryRepository(core, EditingService(core), prompts, worker)
        factory = FillViewModelFactory(repository, FillService(core, clipboard, clock::zone), CopyTextDelivery(clipboard))
        share = ShareEntry(::createFill, CopyTextDelivery(clipboard), EditorViewModelFactory(repository, worker, clock))
        owners.put("share", share)
        val host = Any()
        share.attach(host)
        share.setForeground(host, true)
        repository.refresh()
    }

    protected fun shareRequest(text: String) = assertNotNull(ShareIntentDecoder.decode(ACTION_SEND, "text/plain") { text })

    protected fun start(lane: Lane, capture: String = "captured"): FillViewModel {
        picker = LibraryViewModel(repository, worker).also { owners.put("picker", it) }
        return when (lane) {
            Lane.IME -> {
                val root = object : ImeSessionRoot {
                    val models = ViewModelStore()
                    override fun show() = Unit
                    override fun hide() = Unit
                    override fun clearModels() = models.clear()
                    override fun destroy() = models.clear()
                }
                val active = ImeSessionController({ _, session ->
                    val gateway = object : ImeDeliveryGateway {
                        override fun editor() = editor
                        override fun commitText(editor: ImeEditor, text: String, newCursorPosition: Int): Boolean {
                            assertTrue(editor.matches(this@EntryFlowFixture.editor))
                            assertEquals(1, newCursorPosition)
                            effect(text)
                            return true
                        }
                    }
                    ImeModels(picker, createFill(session, ImeTextDelivery(gateway, session.isActive,
                        CopyTextDelivery(clipboard))).also { root.models.put("fill", it) })
                }, { editor }, { current ->
                    if (!current()) ImeSwitchBack.Result.STALE else {
                        events += "switch"
                        ImeSwitchBack.Result.PREVIOUS
                    }
                }, { FillHandoffLauncher(handoffs, { token ->
                    tokens += token
                    if (failLaunch) throw IllegalStateException(errorText)
                }).open(it) })
                controller = active
                observer = CoroutineScope(SupervisorJob() + worker).also { scope ->
                    scope.launch {
                        active.state.collectLatest { state ->
                            state.models?.fill?.state?.collect { active.fillChanged(state.generation) }
                        }
                    }
                }
                active.replaceRoot(root)
                active.startInput(editor)
                active.show(editor)
                assertNotNull(active.state.value.models).fill
            }
            Lane.EDITABLE_SELECTION, Lane.READ_ONLY_SELECTION -> {
                val entry = ProcessTextEntry(::createFill, CopyTextDelivery(clipboard))
                owners.put("selection", entry)
                val host = Any()
                entry.attach(host) { if (it != null) effect(it) }
                entry.setForeground(host, true)
                entry.start(ProcessTextIntentDecoder.decode(ACTION_PROCESS_TEXT, "text/plain") { key ->
                    when (key) {
                        EXTRA_PROCESS_TEXT -> capture
                        EXTRA_PROCESS_TEXT_READONLY -> lane == Lane.READ_ONLY_SELECTION
                        else -> error("Unexpected extra")
                    }
                })
                assertNotNull(entry.form.value)
            }
            Lane.SHARE -> {
                share.start(shareRequest(capture))
                share.useInPrompt()
                assertIs<ShareDestination.Filling>(share.destination.value).form
            }
            else -> {
                val source = EntrySource.valueOf(lane.name)
                val request = FillRoute.sanitize(source.action, "untrusted.md")
                assertNull(request.promptPath)
                createFill(FillSession(), CopyTextDelivery(clipboard)).also {
                    owners.put("activity", it)
                    it.setForeground(true)
                }
            }
        }
    }

    protected fun TestScope.pick(lane: Lane, form: FillViewModel) {
        picker.setQuery("Integration")
        runCurrent()
        val selection = picker.state.value.rows.single().selection
        if (lane == Lane.IME) controller!!.open(controller!!.state.value.generation, selection)
        else form.open(selection.relativePath)
        runCurrent()
        assertEquals(FillPhase.EDITING, form.state.value.phase)
    }

    protected fun tap(lane: Lane, form: FillViewModel) {
        when (lane) {
            Lane.IME -> controller!!.insert(controller!!.state.value.generation)
            Lane.EDITABLE_SELECTION -> form.insert()
            else -> form.copy()
        }
    }

    protected fun disk(): Map<String, List<Byte>> = Files.walk(directory).use { paths ->
        paths.filter { Files.isRegularFile(it) }.toList().associate {
            directory.relativize(it).toString() to Files.readAllBytes(it).toList()
        }
    }

    protected fun release() {
        observer?.cancel(); observer = null
        controller?.destroy(); controller = null
        owners.clear()
    }

    private fun createFill(session: FillSession, endpoint: TextDelivery): FillViewModel {
        creations++
        return factory.create(session, endpoint)
    }

    private fun effect(text: String) {
        beforeEffect()
        if (failEffect) throw IllegalStateException(errorText)
        effects += text
        events += "effect"
    }

    protected inner class TestClipboard : Clipboard {
        var text: String? = null
        var reads = 0
        var writes = 0
        var deferred = false
        val pending = mutableListOf<(String?) -> Unit>()
        override fun readText(completion: (String?) -> Unit) {
            reads++
            if (deferred) pending += completion else completion(text)
        }
        override fun writeText(text: String) { effect(text); writes++ }
    }
}
