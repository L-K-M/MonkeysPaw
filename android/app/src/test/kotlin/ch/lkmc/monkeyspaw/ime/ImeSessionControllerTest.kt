package ch.lkmc.monkeyspaw.ime

import android.text.InputType.*
import android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.entry.FillHandoffLauncher
import ch.lkmc.monkeyspaw.entry.FillHandoffStore
import ch.lkmc.monkeyspaw.ui.fill.*
import ch.lkmc.monkeyspaw.ui.library.LibraryContent
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.ZoneOffset
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class ImeSessionControllerTest : TemporaryFiles() {
    private val worker = StandardTestDispatcher()
    private val clipboard = FakeClipboard()
    private val roots = mutableListOf<Root>()
    private var current = ImeEditor(TYPE_CLASS_TEXT, 0, Any())
    private var created = 0
    private var switches = 0
    private var switchResult = true
    private var switchOutcome = ImeSwitchBack.Result.PREVIOUS
    private var onSwitch: () -> Unit = {}
    private val commits = mutableListOf<String>()
    private var commitResult: Boolean? = true
    private var onCommit: () -> Unit = {}
    private val handoffs = FillHandoffStore()
    private val launchedTokens = mutableListOf<String>()
    private var launchThrows = false
    private var onLaunch: () -> Unit = {}
    private var observer: CoroutineScope? = null
    private lateinit var controller: ImeSessionController
    private lateinit var repository: LibraryRepository
    private lateinit var core: LibraryService
    private lateinit var fillFactory: FillViewModelFactory

    @BeforeTest fun setMain() { Dispatchers.setMain(worker) }
    @AfterTest fun clear() {
        if (::controller.isInitialized) controller.destroy()
        observer?.cancel()
        roots.forEach { it.destroy() }
        Dispatchers.resetMain()
    }

    @Test fun `start and restart replace generations even for identical metadata and connection`() = runTest {
        graph()
        val root = root()
        controller.replaceRoot(root)
        controller.startInput(current)
        assertEquals(0, created)
        controller.show(current)
        advanceUntilIdle()
        val first = models()
        val oldEpoch = epoch()
        assertEquals(LibraryContent.READY, first.library.state.value.content)
        assertEquals(FillInput.INLINE, first.fill.state.value.input)
        controller.startInput(current)
        advanceUntilIdle()
        assertEquals(2, created)
        assertEquals(1, root.clears)
        assertEquals(FillPhase.CLOSED, first.fill.state.value.phase)
        controller.query(oldEpoch, "retired")
        controller.open(oldEpoch, first.library.state.value.rows.single().selection)
        controller.switch(oldEpoch)
        assertEquals("", models().library.state.value.query)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertEquals(0, switches)
    }

    @Test fun `hide retires pending clipboard callbacks and show creates a fresh form once`() = runTest {
        graph("{{clipboard}}")
        show()
        open()
        val first = models().fill
        assertEquals(1, clipboard.reads)
        assertFalse(first.state.value.builtinsResolved)
        controller.hide()
        controller.hide()
        val root = roots.single()
        assertEquals(1, root.clears)
        assertNull(controller.state.value.models)
        clipboard.pending.single()("late private snapshot")
        advanceUntilIdle()
        assertEquals(FillPhase.CLOSED, first.state.value.phase)
        controller.show(current)
        controller.show(current)
        advanceUntilIdle()
        assertEquals(2, created)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertEquals(1, clipboard.reads)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `password variants create no models read no clipboard and still allow explicit switch`() = runTest {
        graph("{{clipboard}}")
        controller.replaceRoot(root())
        for (type in listOf(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD,
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_PASSWORD,
            TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD)) {
            current = ImeEditor(type or TYPE_TEXT_FLAG_MULTI_LINE, 0, null)
            controller.startInput(current)
            controller.show(current)
            assertTrue(controller.state.value.password)
            assertNull(controller.state.value.models)
            controller.copy(epoch())
            controller.refresh(epoch())
            controller.switch(epoch())
        }
        advanceUntilIdle()
        assertEquals(0, created)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertEquals(4, switches)
    }

    @Test fun `latest password metadata retires an opened form before any Copy or pending read reply`() = runTest {
        graph("{{clipboard}}")
        show()
        open()
        val old = models().fill
        val oldEpoch = epoch()
        current = ImeEditor(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD, 0, Any())
        controller.copy(oldEpoch)
        clipboard.pending.single()("retired")
        advanceUntilIdle()
        assertTrue(controller.state.value.password)
        assertNull(controller.state.value.models)
        assertEquals(FillPhase.CLOSED, old.state.value.phase)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `connection or learning metadata changes reject callbacks and never reuse the old form`() = runTest {
        graph()
        show()
        open()
        val old = models().fill
        val oldEpoch = epoch()
        current = ImeEditor(TYPE_CLASS_TEXT, IME_FLAG_NO_PERSONALIZED_LEARNING, Any())
        controller.copy(oldEpoch)
        advanceUntilIdle()
        assertEquals(FillPhase.CLOSED, old.state.value.phase)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertEquals(LearningPolicy.EPHEMERAL, models().fill.state.value.learningPolicy)
        assertEquals(0, clipboard.writes)
        assertEquals(0, switches)
    }

    @Test fun `root replacement destroys the old owner and discards late UI and builtin callbacks`() = runTest {
        graph("{{clipboard}}")
        show()
        open()
        val first = models()
        val oldEpoch = epoch()
        val previous = roots.single()
        val next = root()
        controller.replaceRoot(next)
        clipboard.pending.single()("retired")
        controller.value(oldEpoch, "text", "late")
        controller.copy(oldEpoch)
        controller.backToPicker(oldEpoch)
        advanceUntilIdle()
        assertEquals(1, previous.destroys)
        assertEquals(1, previous.clears)
        assertEquals(FillPhase.CLOSED, first.fill.state.value.phase)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `finish unbind and destroy are idempotent and cannot be revived by late show`() = runTest {
        graph()
        show()
        val owner = roots.single()
        val oldEpoch = epoch()
        controller.finishInput()
        controller.unbind()
        controller.unbind()
        controller.show(current)
        assertNull(controller.state.value.models)
        assertEquals(1, owner.clears)
        controller.startInput(current)
        controller.show(current)
        assertEquals(2, created)
        controller.destroy()
        controller.destroy()
        controller.startInput(current)
        controller.show(current)
        controller.switch(oldEpoch)
        assertEquals(1, owner.destroys)
        assertEquals(2, owner.clears)
        assertEquals(2, created)
        val lateRoot = root()
        controller.replaceRoot(lateRoot)
        assertEquals(1, lateRoot.destroys)
        assertEquals(0, switches)
    }

    @Test fun `warm browsing performs no disk rescan or clipboard read after local root becomes unavailable`() = runTest {
        graph("{{clipboard}}")
        val version = repository.state.value.snapshot.version
        Files.delete(libraryPath.resolve("a.md"))
        Files.delete(libraryPath)
        show()
        controller.query(epoch(), "Test")
        advanceUntilIdle()
        assertEquals(version, repository.state.value.snapshot.version)
        assertNull(repository.state.value.error)
        assertEquals(LibraryContent.READY, models().library.state.value.content)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `inline defaults and choices share preview and explicit Copy with normal learning`() = runTest {
        graph("---\nfields:\n  mode:\n    type: choice\n    options: [brief, full]\n    default: brief\n  text:\n    default: ready\n---\n{{mode}}/{{text}}")
        show()
        open()
        val form = models().fill
        assertEquals(mapOf("mode" to "brief", "text" to "ready"), form.state.value.values)
        controller.value(epoch(), "mode", "full")
        controller.copy(epoch())
        controller.copy(epoch())
        advanceUntilIdle()
        assertEquals(listOf("full/ready"), clipboard.copied)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertTrue(form.state.value.shouldFinish)
        assertEquals(0, clipboard.reads)
        assertEquals(1, switches)
        controller.hide()
        controller.show(current)
        advanceUntilIdle()
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
    }

    @Test fun `missing metadata and connection allow explicit Copy with ephemeral bookkeeping`() = runTest {
        graph()
        current = ImeEditor(null, IME_FLAG_NO_PERSONALIZED_LEARNING, null)
        show()
        open()
        controller.copy(epoch())
        advanceUntilIdle()
        assertEquals(1, clipboard.writes)
        assertTrue(core.usage.useEvents(core.load("a.md").identity).isEmpty())
        assertFalse(statePath.resolve("values.json").toFile().exists())
    }

    @Test fun `accepted Copy bookkeeping survives hiding and never switches a newer target`() = runTest {
        graph("{{text}}")
        show()
        open()
        val identity = core.load("a.md").identity
        controller.value(epoch(), "text", "accepted")
        clipboard.onWrite = { controller.hide() }
        controller.copy(epoch())
        advanceUntilIdle()
        assertEquals(1, clipboard.writes)
        assertEquals(1, core.usage.useEvents(identity).size)
        assertEquals(mapOf("text" to "accepted"), core.values.rememberedValues(identity))
        assertNull(controller.state.value.models)
        assertEquals(0, switches)
    }

    @Test fun `failed switch retains visible instructions and stale switch cannot affect another session`() = runTest {
        graph()
        show()
        switchResult = false
        val oldEpoch = epoch()
        controller.switch(oldEpoch)
        assertTrue(controller.state.value.switchUnavailable)
        controller.hide()
        controller.show(current)
        controller.switch(oldEpoch)
        assertEquals(1, switches)
        assertFalse(controller.state.value.switchUnavailable)
    }

    @Test fun `changed connection before switch rejects the old button callback`() = runTest {
        graph()
        show()
        val oldEpoch = epoch()
        current = ImeEditor(TYPE_CLASS_TEXT, 0, Any())
        controller.switch(oldEpoch)
        assertEquals(0, switches)
        assertNotEquals(oldEpoch, epoch())
    }

    @Test fun `fieldless row activation inserts once then learns before switching with no clipboard effects`() = runTest {
        graph("ready")
        show()
        val identity = core.load("a.md").identity
        val events = mutableListOf<String>()
        onCommit = {
            events += "commit"
            assertTrue(core.usage.useEvents(identity).isEmpty())
        }
        onSwitch = {
            events += "switch"
            assertEquals(1, core.usage.useEvents(identity).size)
        }
        open()
        val activeEpoch = epoch()
        controller.insert(activeEpoch)
        controller.copy(activeEpoch)
        controller.fillChanged(activeEpoch)
        advanceUntilIdle()
        assertEquals(DeliveryMode.IME_COMMIT, models().fill.state.value.deliveryMode)
        assertEquals(listOf("commit", "switch"), events)
        assertEquals(1, commits.size)
        assertTrue(commits.single() == "ready")
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertEquals(1, switches)
    }

    @Test fun `inline fields wait for explicit Insert and remember only after acceptance`() = runTest {
        graph()
        show()
        open()
        assertTrue(controller.state.value.insertEnabled)
        val identity = core.load("a.md").identity
        assertTrue(commits.isEmpty())
        onCommit = {
            assertTrue(core.values.rememberedValues(identity).isEmpty())
            assertTrue(core.usage.useEvents(identity).isEmpty())
        }
        onSwitch = {
            assertTrue(core.values.rememberedValues(identity)["text"] == "accepted")
            assertEquals(1, core.usage.useEvents(identity).size)
        }
        controller.value(epoch(), "text", "accepted")
        controller.insert(epoch())
        controller.insert(epoch())
        advanceUntilIdle()
        assertEquals(1, commits.size)
        assertEquals(0, clipboard.writes)
        assertEquals(1, switches)
    }

    @Test fun `failed Insert has no learning or switch and explicit Copy completes learning before switch`() = runTest {
        graph()
        show()
        open()
        val identity = core.load("a.md").identity
        commitResult = false
        controller.insert(epoch())
        controller.insert(epoch())
        advanceUntilIdle()
        assertEquals(FillFailure.DELIVERY, models().fill.state.value.failure)
        assertFalse(controller.state.value.insertEnabled)
        controller.value(epoch(), "text", "ready")
        advanceUntilIdle()
        assertFalse(controller.state.value.insertEnabled)
        assertEquals(1, commits.size)
        assertTrue(core.usage.useEvents(identity).isEmpty())
        assertTrue(core.values.rememberedValues(identity).isEmpty())
        assertEquals(0, clipboard.writes)
        assertEquals(0, switches)
        clipboard.onWrite = {
            assertTrue(core.usage.useEvents(identity).isEmpty())
            assertTrue(core.values.rememberedValues(identity).isEmpty())
        }
        onSwitch = {
            assertEquals(1, core.usage.useEvents(identity).size)
            assertTrue(core.values.rememberedValues(identity)["text"] == "ready")
        }
        controller.copy(epoch())
        controller.copy(epoch())
        advanceUntilIdle()
        assertEquals(1, clipboard.writes)
        assertEquals(1, commits.size)
        assertEquals(1, switches)
    }

    @Test fun `final clipboard render with multiline in terminal offers Copy without commit or learning`() = runTest {
        graph("{{clipboard}}")
        current = ImeEditor(0x00080090, 0, Any())
        show()
        open()
        assertFalse(models().fill.state.value.copyEnabled)
        assertEquals(1, clipboard.reads)
        clipboard.pending.single()("first\nsecond")
        advanceUntilIdle()
        assertEquals(FillFailure.DELIVERY, models().fill.state.value.failure)
        assertFalse(controller.state.value.insertEnabled)
        assertTrue(commits.isEmpty())
        assertEquals(0, clipboard.writes)
        assertEquals(0, switches)
        assertTrue(core.usage.useEvents(core.load("a.md").identity).isEmpty())
        controller.copy(epoch())
        advanceUntilIdle()
        assertTrue(clipboard.copied.single() == "first\nsecond")
        assertEquals(1, switches)
    }

    @Test fun `ephemeral Insert has no remembered or usage writes and still switches once`() = runTest {
        graph()
        current = ImeEditor(TYPE_CLASS_TEXT, IME_FLAG_NO_PERSONALIZED_LEARNING, Any())
        show()
        open()
        controller.insert(epoch())
        advanceUntilIdle()
        assertEquals(1, commits.size)
        assertEquals(1, switches)
        assertEquals(0, clipboard.writes)
        assertTrue(core.usage.useEvents(core.load("a.md").identity).isEmpty())
        assertFalse(statePath.resolve("values.json").toFile().exists())
    }

    @Test fun `accepted Insert learning survives teardown and never switches another input session`() = runTest {
        graph()
        show()
        open()
        val identity = core.load("a.md").identity
        val previous = models().fill
        val oldEpoch = epoch()
        onCommit = {
            current = ImeEditor(TYPE_CLASS_TEXT, IME_FLAG_NO_PERSONALIZED_LEARNING, Any())
            controller.startInput(current)
            controller.show(current)
        }
        controller.insert(oldEpoch)
        controller.fillChanged(oldEpoch)
        advanceUntilIdle()
        assertEquals(1, commits.size)
        assertEquals(FillPhase.CLOSED, previous.state.value.phase)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertEquals(LearningPolicy.EPHEMERAL, models().fill.state.value.learningPolicy)
        assertEquals(1, core.usage.useEvents(identity).size)
        assertTrue(core.values.rememberedValues(identity)["text"] == "ready")
        assertEquals(0, switches)
    }

    @Test fun `old endpoint rechecks changed connection and latest learning metadata before commit`() = runTest {
        graph()
        show()
        open()
        val previous = models().fill
        current = ImeEditor(TYPE_CLASS_TEXT, IME_FLAG_NO_PERSONALIZED_LEARNING, Any())
        previous.insert()
        advanceUntilIdle()
        assertTrue(commits.isEmpty())
        assertEquals(0, clipboard.writes)
        assertEquals(0, switches)
        assertEquals(FillPhase.CLOSED, previous.state.value.phase)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
    }

    @Test fun `persistence warnings keep Done available and never replay accepted insertion`() = runTest {
        graph()
        show()
        open()
        Files.createDirectories(statePath.resolve("values.json"))
        controller.insert(epoch())
        advanceUntilIdle()
        assertEquals(FillPhase.DELIVERED, models().fill.state.value.phase)
        assertTrue(FillWarning.REMEMBERED_VALUES_NOT_SAVED in models().fill.state.value.warnings)
        assertEquals(0, switches)
        controller.insert(epoch())
        controller.copy(epoch())
        controller.backToPicker(epoch())
        advanceUntilIdle()
        assertEquals(1, commits.size)
        assertEquals(0, clipboard.writes)
        assertEquals(1, switches)
    }

    @Test fun `Search handoff switches before launch carries no endpoint and own Fill has no recursive picker`() = runTest {
        graph()
        show()
        val oldEpoch = epoch()
        switchOutcome = ImeSwitchBack.Result.PICKER
        val events = mutableListOf<String>()
        onSwitch = { events += "switch" }
        onLaunch = { events += "launch" }
        controller.handoff(oldEpoch)
        controller.handoff(oldEpoch)
        assertEquals(listOf("switch", "launch"), events)
        val snapshot = handoffs.consume(launchedTokens.single())!!
        assertNull(snapshot.form)
        assertNull(handoffs.consume(launchedTokens.single()))
        val activity = fillFactory.create(FillSession())
        root().store.put("activity", activity)
        fillFactory.restoreHandoff(activity, snapshot)
        assertEquals(DeliveryMode.COPY, activity.state.value.deliveryMode)
        current = ImeEditor(TYPE_CLASS_TEXT, 0, Any(), inFillActivity = true)
        controller.startInput(current)
        controller.show(current)
        controller.handoff(epoch())
        controller.insert(epoch())
        assertTrue(controller.state.value.inFillActivity)
        assertNull(controller.state.value.models)
        assertEquals(1, launchedTokens.size)
        assertEquals(1, created)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertTrue(commits.isEmpty())
        controller.switch(epoch())
        assertEquals(2, switches)
    }

    @Test fun `own editor remains blocked through local focus loss until a new input start`() = runTest {
        graph()
        val connection = Any()
        current = ImeEditor(TYPE_CLASS_TEXT, 0, connection, inFillActivity = true)
        show()
        val ownEpoch = epoch()
        assertNull(controller.state.value.models)
        // Losing top-resumed status does not itself prove that this connection changed editors.
        current = ImeEditor(TYPE_CLASS_TEXT, 0, connection, inFillActivity = false)
        controller.switch(ownEpoch)
        assertNull(controller.state.value.models)
        assertTrue(controller.state.value.inFillActivity)
        assertEquals(1, switches)
        controller.handoff(ownEpoch)
        assertTrue(launchedTokens.isEmpty())
        current = ImeEditor(TYPE_CLASS_TEXT, IME_FLAG_NO_PERSONALIZED_LEARNING, connection, inFillActivity = false)
        controller.switch(ownEpoch)
        assertNotEquals(ownEpoch, epoch())
        assertTrue(controller.state.value.inFillActivity)
        assertNull(controller.state.value.models)
        assertEquals(1, switches)
        controller.startInput(current)
        controller.show(current)
        advanceUntilIdle()
        assertFalse(controller.state.value.inFillActivity)
        assertEquals(1, created)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertEquals(LearningPolicy.EPHEMERAL, models().fill.state.value.learningPolicy)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertTrue(commits.isEmpty())
    }

    @Test fun `Fill handoff waits for builtin completion and preserves held values and ephemeral Copy policy`() = runTest {
        graph("{{text}}/{{clipboard}}")
        current = ImeEditor(TYPE_CLASS_TEXT, IME_FLAG_NO_PERSONALIZED_LEARNING, Any())
        show()
        open()
        controller.handoff(epoch())
        assertEquals(0, switches)
        assertTrue(launchedTokens.isEmpty())
        clipboard.pending.single()("held")
        advanceUntilIdle()
        controller.value(epoch(), "text", "value")
        controller.handoff(epoch())
        val snapshot = handoffs.consume(launchedTokens.single())!!
        assertEquals(LearningPolicy.EPHEMERAL, snapshot.learning)
        val activity = fillFactory.create(FillSession())
        root().store.put("activity", activity)
        fillFactory.restoreHandoff(activity, snapshot)
        activity.setForeground(true)
        assertEquals(DeliveryMode.COPY, activity.state.value.deliveryMode)
        assertTrue((activity.state.value.preview as FillPreview.Rendered).text == "value/held")
        activity.insert()
        activity.copy()
        advanceUntilIdle()
        assertTrue(clipboard.copied.single() == "value/held")
        assertEquals(1, clipboard.reads)
        assertEquals(1, switches)
        assertTrue(commits.isEmpty())
        assertTrue(core.usage.useEvents(core.load("a.md").identity).isEmpty())
        assertFalse(statePath.resolve("values.json").toFile().exists())
    }

    @Test fun `unavailable picker retains the form and a failed activity launch clears its payload for retry`() = runTest {
        graph()
        show()
        open()
        switchResult = false
        controller.handoff(epoch())
        assertTrue(controller.state.value.switchUnavailable)
        assertTrue(launchedTokens.isEmpty())
        assertEquals(FillPhase.EDITING, models().fill.state.value.phase)
        switchResult = true
        launchThrows = true
        controller.handoff(epoch())
        assertTrue(controller.state.value.handoffFailed)
        assertEquals(FillPhase.EDITING, models().fill.state.value.phase)
        launchThrows = false
        controller.handoff(epoch())
        assertEquals(1, launchedTokens.size)
        assertNotNull(handoffs.consume(launchedTokens.single()))
        assertEquals(0, clipboard.writes)
        assertTrue(commits.isEmpty())
    }

    @Test fun `successful handoff tolerates keyboard departure but a new target during switching cancels launch`() = runTest {
        graph()
        show()
        open()
        onSwitch = { controller.unbind() }
        controller.handoff(epoch())
        assertEquals(1, launchedTokens.size)
        assertNotNull(handoffs.consume(launchedTokens.single()))
        current = ImeEditor(TYPE_CLASS_TEXT, 0, Any())
        controller.startInput(current)
        controller.show(current)
        advanceUntilIdle()
        onSwitch = {
            current = ImeEditor(TYPE_CLASS_TEXT, 0, Any())
            controller.startInput(current)
            controller.show(current)
        }
        controller.handoff(epoch())
        advanceUntilIdle()
        assertEquals(1, launchedTokens.size)
        assertEquals(FillPhase.PICKING, models().fill.state.value.phase)
        assertTrue(commits.isEmpty())
        assertEquals(0, clipboard.writes)
    }

    private lateinit var libraryPath: java.nio.file.Path
    private lateinit var statePath: java.nio.file.Path

    private suspend fun graph(body: String = "---\nfields:\n  text:\n    default: ready\n---\n{{text}}") {
        val directory = temporary
        libraryPath = directory.resolve("library")
        statePath = directory.resolve("state")
        val prompts = AndroidPromptStore(libraryPath.toFile())
        prompts.prepareRoot()
        prompts.write("---\ntitle: Test\n---\n$body".let {
            if (body.startsWith("---")) body.replaceFirst("---\n", "---\ntitle: Test\n") else it
        }.toByteArray(), "a.md")
        core = library(prompts = prompts, state = AndroidStateStore(statePath.toFile()))
        repository = LibraryRepository(core, EditingService(core), prompts, worker)
        repository.refresh()
        fillFactory = FillViewModelFactory(repository, FillService(core, clipboard, { ZoneOffset.UTC }), CopyTextDelivery(clipboard))
        controller = ImeSessionController({ root, session ->
            created++
            val owner = root as Root
            val library = LibraryViewModel(repository, worker)
            val gateway = object : ImeDeliveryGateway {
                override fun editor() = current
                override fun commitText(editor: ImeEditor, text: String, newCursorPosition: Int): Boolean? {
                    assertTrue(editor.matches(current))
                    assertEquals(1, newCursorPosition)
                    commits += text
                    onCommit()
                    return commitResult
                }
            }
            val fill = fillFactory.create(session, ImeTextDelivery(gateway, session.isActive, CopyTextDelivery(clipboard)))
            owner.store.put("library", library)
            owner.store.put("fill", fill)
            ImeModels(library, fill)
        }, { current }, { isCurrent ->
            if (!isCurrent()) ImeSwitchBack.Result.STALE else {
                switches++
                onSwitch()
                if (switchResult) switchOutcome else ImeSwitchBack.Result.UNAVAILABLE
            }
        }, { handoff ->
            FillHandoffLauncher(handoffs) { token ->
                if (launchThrows) throw IllegalStateException("Unavailable")
                launchedTokens += token
                onLaunch()
            }.open(handoff)
        })
        observer = CoroutineScope(SupervisorJob() + worker).also { scope ->
            scope.launch {
                controller.state.collectLatest { state ->
                    state.models?.fill?.state?.collect { controller.fillChanged(state.generation) }
                }
            }
        }
    }

    private fun root() = Root().also(roots::add)
    private fun show() {
        controller.replaceRoot(root())
        controller.startInput(current)
        controller.show(current)
    }
    private suspend fun TestScope.open() {
        advanceUntilIdle()
        controller.open(epoch(), models().library.state.value.rows.single().selection)
        advanceUntilIdle()
    }
    private fun models() = checkNotNull(controller.state.value.models)
    private fun epoch() = controller.state.value.generation

    private class Root : ImeSessionRoot {
        val store = ViewModelStore()
        var clears = 0
        var destroys = 0
        private var destroyed = false
        private val lifecycle = ImeViewLifecycle({}, {}, {})
        override fun show() = lifecycle.show()
        override fun hide() = lifecycle.hide()
        override fun clearModels() { clears++; store.clear() }
        override fun destroy() {
            if (destroyed) return
            destroyed = true
            destroys++
            lifecycle.destroy()
            store.clear()
        }
    }

    private class FakeClipboard : Clipboard {
        var reads = 0
        val copied = mutableListOf<String>()
        val writes get() = copied.size
        var onWrite: () -> Unit = {}
        val pending = mutableListOf<(String?) -> Unit>()
        override fun readText(completion: (String?) -> Unit) { reads++; pending += completion }
        override fun writeText(text: String) { copied += text; onWrite() }
    }
}
