package ch.lkmc.monkeyspaw.ime

import android.text.InputType.*
import android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.fill.*
import ch.lkmc.monkeyspaw.ui.library.LibraryContent
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
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
    private lateinit var controller: ImeSessionController
    private lateinit var repository: LibraryRepository
    private lateinit var core: LibraryService

    @BeforeTest fun setMain() { Dispatchers.setMain(worker) }
    @AfterTest fun clear() {
        if (::controller.isInitialized) controller.destroy()
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
        assertEquals(0, switches) // N3 switches only on the explicit Switch keyboard action.
        controller.backToPicker(epoch())
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

    private lateinit var libraryPath: java.nio.file.Path
    private lateinit var statePath: java.nio.file.Path

    private suspend fun graph(body: String = "ready") {
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
        val fillFactory = FillViewModelFactory(repository, FillService(core, clipboard, { ZoneOffset.UTC }), CopyTextDelivery(clipboard))
        controller = ImeSessionController({ root, session ->
            created++
            val owner = root as Root
            val library = LibraryViewModel(repository, worker)
            val fill = fillFactory.create(session, TextDelivery { mode, text ->
                if (!session.isActive()) TextDeliveryResult.STALE else CopyTextDelivery(clipboard).deliver(mode, text)
            })
            owner.store.put("library", library)
            owner.store.put("fill", fill)
            ImeModels(library, fill)
        }, { current }, { switches++; switchResult })
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
