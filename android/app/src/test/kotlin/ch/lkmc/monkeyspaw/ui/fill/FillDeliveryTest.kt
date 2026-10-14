package ch.lkmc.monkeyspaw.ui.fill

import android.content.Intent.ACTION_SEND
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.entry.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneOffset
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class FillDeliveryTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val events = mutableListOf<String>()
    private val clipboard = FakeClipboard()
    private var clockReads = 0
    private var zoneReads = 0
    private var modelNumber = 0
    private var failRemember = false
    private var failUsage = false
    private lateinit var core: LibraryService
    private lateinit var factory: FillViewModelFactory

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clearModels() { models.clear(); Dispatchers.resetMain() }

    @Test fun `all modes use the same held literal render snapshot and effect learning finish order`() = runTest {
        putPrompt("---\nfields:\n  fresh:\n    remember: false\n  empty:\n    optional: true\n---\n{{f}}/{{fresh}}/{{empty}}/{{clipboard}}/{{date}}/{{time}}/{{f}}")
        graph()
        val identity = core.load("a.md").identity
        for ((index, mode) in DeliveryMode.entries.withIndex()) {
            clockReads = 0
            zoneReads = 0
            clipboard.reads = 0
            clipboard.text = "{{captured}}"
            lateinit var model: FillViewModel
            val endpoint = TextDelivery { received, text ->
                assertEquals(mode, received)
                assertTrue(text == "{{literal}}\n/session//{{captured}}/2026-10-14/00:30/{{literal}}\n")
                assertEquals(FillPhase.DELIVERING, model.state.value.phase)
                assertEquals(index, core.usage.useEvents(identity).size)
                events.add("effect")
                model.copy()
                model.insert()
                model.cancel()
                model.setValue("f", "late")
                TextDeliveryResult.ACCEPTED
            }
            model = open(FillSession(mode = mode), endpoint)
            model.setValue("f", "{{literal}}\n")
            model.setValue("fresh", "session")
            model.setValue("empty", "")
            assertEquals(1, clockReads)
            assertEquals(1, zoneReads)
            assertEquals(1, clipboard.reads)
            clipboard.text = "changed externally"
            events.clear()
            tap(model)
            tap(model)
            assertEquals(listOf("effect"), events)
            assertFalse(model.state.value.shouldFinish)
            runCurrent()
            assertEquals(listOf("effect", "remember", "usage"), events)
            assertTrue(model.state.value.shouldFinish)
            events.add("finish")
            assertEquals(listOf("effect", "remember", "usage", "finish"), events)
            assertTrue(core.values.rememberedValues(identity) == mapOf("f" to "{{literal}}\n", "empty" to ""))
            assertEquals(index + 1, core.usage.useEvents(identity).size)
            assertEquals(2, clockReads) // Opening snapshot plus accepted usage timestamp.
            assertEquals(1, zoneReads)
            assertEquals(1, clipboard.reads)
            assertEquals(0, clipboard.writes)
        }
    }

    @Test fun `ephemeral accepts each mode without any remembered or usage write`() = runTest {
        putPrompt("{{f}}")
        graph()
        val before = stateBytes()
        for (mode in DeliveryMode.entries) {
            val model = open(FillSession(mode = mode, learning = LearningPolicy.EPHEMERAL), TextDelivery { _, _ ->
                events.add("effect")
                TextDeliveryResult.ACCEPTED
            })
            model.setValue("f", "ephemeral")
            events.clear()
            tap(model)
            runCurrent()
            assertEquals(listOf("effect"), events)
            assertTrue(model.state.value.shouldFinish)
            assertTrue(before == stateBytes())
        }
        assertEquals(0, clipboard.reads)
        assertEquals(0, clockReads)
        assertEquals(0, zoneReads)
    }

    @Test fun `failed effects retain the form and stale effects close without learning in every mode`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.text = "opening snapshot"
        val before = stateBytes()
        for (mode in DeliveryMode.entries) {
            for (result in listOf(TextDeliveryResult.REFUSED, TextDeliveryResult.STALE, null)) {
                var calls = 0
                val model = open(FillSession(mode = mode), TextDelivery { _, _ ->
                    calls++
                    if (result == null) throw IllegalStateException("private effect error")
                    result
                })
                model.setValue("f", "held")
                val preview = model.state.value.preview
                tap(model)
                runCurrent()
                assertEquals(1, calls)
                if (result == TextDeliveryResult.STALE) {
                    assertEquals(FillPhase.CLOSED, model.state.value.phase)
                    assertTrue(model.state.value.values.isEmpty())
                } else {
                    assertEquals(FillPhase.EDITING, model.state.value.phase)
                    assertEquals(preview, model.state.value.preview)
                    assertEquals(if (mode == DeliveryMode.COPY) FillFailure.CLIPBOARD else FillFailure.DELIVERY,
                        model.state.value.failure)
                }
                assertTrue(before == stateBytes())
            }
        }
        assertTrue(events.isEmpty())
        assertEquals(0, clipboard.writes)
    }

    @Test fun `refused insertion requires explicit Copy and records one accepted attempt`() = runTest {
        putPrompt("{{f}}")
        graph()
        for (mode in listOf(DeliveryMode.IME_COMMIT, DeliveryMode.SELECTION_RESULT)) {
            val attempts = mutableListOf<DeliveryMode>()
            val model = open(FillSession(mode = mode), TextDelivery { request, _ ->
                attempts.add(request)
                if (request == DeliveryMode.COPY) TextDeliveryResult.ACCEPTED else TextDeliveryResult.REFUSED
            })
            model.setValue("f", "value")
            events.clear()
            model.insert()
            runCurrent()
            assertEquals(listOf(mode), attempts)
            assertTrue(events.isEmpty())
            model.copy()
            model.copy()
            model.insert()
            runCurrent()
            assertEquals(listOf(mode, DeliveryMode.COPY), attempts)
            assertEquals(listOf("remember", "usage"), events)
        }
    }

    @Test fun `capture moves over prefills while edits empty values and remember false retain precedence`() = runTest {
        putPrompt("---\nfields:\n  first:\n    default: first default\n    remember: false\n  second:\n    type: multiline\n    default: second default\n    optional: true\n  choice:\n    type: choice\n    options: [one, two]\n    default: one\n---\n{{first}}/{{second}}/{{choice}}")
        graph()
        val identity = core.load("a.md").identity
        core.values.record(identity, mapOf("first" to "ignored", "second" to "remembered"))
        val capture = CapturedTextRequest.parse(ACTION_SEND, "text/plain", " {{raw}}\n ")
        val before = stateBytes()
        val model = open(FillSession(capture = capture))
        assertEquals("second", model.state.value.capturedText?.selectedField)
        assertTrue(model.state.value.values == mapOf("first" to "first default", "second" to capture.text, "choice" to "one"))
        model.selectCapturedField("first")
        assertTrue(model.state.value.values["second"] == "remembered")
        model.selectCapturedField("second")
        assertTrue(model.state.value.values["first"] == "first default")
        model.setValue("second", "")
        model.selectCapturedField("first")
        model.selectCapturedField("choice")
        assertEquals("first", model.state.value.capturedText?.selectedField)
        assertTrue(model.state.value.values["second"] == "")
        model.selectCapturedField(null)
        assertNull(model.state.value.capturedText?.selectedField)
        assertTrue(model.state.value.values["first"] == "first default")
        assertTrue(model.state.value.values["second"] == "")
        model.selectCapturedField("first")
        assertTrue(before == stateBytes())
        model.copy()
        runCurrent()
        assertTrue(clipboard.text == " {{raw}}\n //one")
        assertTrue(core.values.rememberedValues(identity) == mapOf("first" to "ignored", "second" to "", "choice" to "one"))
    }

    @Test fun `retired session rejects late snapshot and later delivery without learning`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.deferred = true
        var active = true
        var effects = 0
        val model = open(FillSession(mode = DeliveryMode.IME_COMMIT, isActive = { active }), TextDelivery { _, _ ->
            effects++
            TextDeliveryResult.ACCEPTED
        })
        model.setValue("f", "value")
        assertNull(model.handoff())
        active = false
        clipboard.complete("late")
        runCurrent()
        model.insert()
        model.copy()
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertEquals(0, effects)
        assertTrue(events.isEmpty())
        assertNull(model.handoff())
    }

    @Test fun `invalidating a resolved session prevents any endpoint or unused builtin read`() = runTest {
        putPrompt("Body")
        graph()
        var active = false
        var effects = 0
        val unopened = open(FillSession(isActive = { active }), TextDelivery { _, _ -> effects++; TextDeliveryResult.ACCEPTED })
        assertEquals(FillPhase.CLOSED, unopened.state.value.phase)
        active = true
        val model = open(FillSession(mode = DeliveryMode.SELECTION_RESULT, isActive = { active }),
            TextDelivery { _, _ -> effects++; TextDeliveryResult.ACCEPTED })
        assertTrue(model.state.value.copyEnabled)
        active = false
        model.insert()
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertEquals(0, effects)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clockReads)
        assertEquals(0, zoneReads)
    }

    @Test fun `retired load failure cannot update the old session`() = runTest {
        graph()
        var active = true
        val model = tracked(factory.create(FillSession(isActive = { active })))
        model.setForeground(true)
        model.open("missing.md")
        active = false
        runCurrent()
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertEquals(0, clipboard.reads)
        assertTrue(events.isEmpty())
    }

    @Test fun `accepted bookkeeping learns but never publishes completion into a retired session`() = runTest {
        putPrompt("{{f}}")
        graph()
        var active = true
        val model = open(FillSession(mode = DeliveryMode.IME_COMMIT, isActive = { active }), TextDelivery { _, _ ->
            events.add("effect")
            TextDeliveryResult.ACCEPTED
        })
        model.setValue("f", "accepted")
        model.insert()
        active = false
        runCurrent()
        assertEquals(listOf("effect", "remember", "usage"), events)
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertTrue(model.state.value.values.isEmpty())
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
    }

    @Test fun `persistence warnings never repeat the effect in any mode`() = runTest {
        putPrompt("{{f}}")
        graph()
        for (mode in DeliveryMode.entries) {
            var effects = 0
            val model = open(FillSession(mode = mode), TextDelivery { _, _ -> effects++; TextDeliveryResult.ACCEPTED })
            model.setValue("f", "delivered")
            failRemember = true
            failUsage = true
            tap(model)
            runCurrent()
            assertEquals(listOf(FillWarning.REMEMBERED_VALUES_NOT_SAVED, FillWarning.USAGE_NOT_SAVED), model.state.value.warnings)
            assertEquals(FillPhase.DELIVERED, model.state.value.phase)
            assertFalse(model.state.value.shouldFinish)
            tap(model)
            model.copy()
            assertEquals(1, effects)
            model.cancel()
            assertTrue(model.state.value.shouldFinish)
        }
    }

    @Test fun `accepted insertion bookkeeping survives host teardown and rejects its late UI reply`() = runTest {
        putPrompt("{{f}}")
        val worker = QueuedDispatcher()
        graph(worker)
        lateinit var model: FillViewModel
        model = tracked(factory.create(FillSession(mode = DeliveryMode.IME_COMMIT), TextDelivery { _, _ ->
            events.add("effect")
            model.endSession()
            TextDeliveryResult.ACCEPTED
        }))
        model.setForeground(true)
        model.open("a.md")
        runCurrent()
        worker.runAll()
        runCurrent()
        model.setValue("f", "accepted")
        model.insert()
        models.clear()
        worker.runAll()
        runCurrent()
        assertEquals(listOf("effect", "remember", "usage"), events)
        assertEquals(FillPhase.CLOSED, model.state.value.phase)
        assertTrue(model.state.value.values.isEmpty())
        assertTrue(core.values.rememberedValues(core.load("a.md").identity) == mapOf("f" to "accepted"))
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
    }

    @Test fun `handoff consumes once preserves prompt values capture and builtin snapshot and uses only Copy`() = runTest {
        putPrompt("---\nfields:\n  f:\n    default: base\n  other:\n    optional: true\n---\n{{f}}/{{other}}/{{clipboard}}/{{date}}/{{time}}")
        graph()
        for (policy in LearningPolicy.entries) {
            clipboard.text = "opening snapshot"
            val capture = CapturedTextRequest.parse(ACTION_SEND, "text/plain", "{{literal}}\n")
            var oldEndpoint = 0
            val source = open(FillSession(mode = DeliveryMode.IME_COMMIT, learning = policy, capture = capture,
                input = FillInput.INLINE), TextDelivery { _, _ -> oldEndpoint++; TextDeliveryResult.ACCEPTED })
            source.selectCapturedField("other")
            source.setValue("f", "typed")
            val expected = source.state.value.preview
            val handoff = assertNotNull(source.handoff())
            val store = FillHandoffStore()
            val token = store.offer(handoff)
            source.endSession()
            clipboard.text = "changed externally"
            val activity = tracked(factory.create(FillViewModel::class.java))
            factory.restoreHandoff(activity, store.consume(token))
            assertNull(store.consume(token))
            assertEquals(DeliveryMode.COPY, activity.state.value.deliveryMode)
            assertEquals(policy, activity.state.value.learningPolicy)
            assertEquals(FillInput.EDITABLE, activity.state.value.input)
            assertEquals(expected, activity.state.value.preview)
            assertEquals("other", activity.state.value.capturedText?.selectedField)
            val reads = clipboard.reads
            val clocks = clockReads
            activity.setForeground(true)
            activity.setForeground(false)
            activity.setForeground(true)
            runCurrent()
            assertEquals(reads, clipboard.reads)
            assertEquals(clocks, clockReads)
            events.clear()
            val before = stateBytes()
            activity.insert()
            activity.copy()
            runCurrent()
            assertEquals(0, oldEndpoint)
            assertTrue(clipboard.text == (expected as FillPreview.Rendered).text)
            assertEquals(if (policy == LearningPolicy.NORMAL) listOf("copy", "remember", "usage") else listOf("copy"), events)
            if (policy == LearningPolicy.EPHEMERAL) assertTrue(before == stateBytes())
            activity.cancel()
            assertTrue(activity.state.value.values.isEmpty())
            assertNull(activity.state.value.capturedText)
        }
    }

    @Test fun `lost handoff safely restarts an empty Copy picker without learning or an old endpoint`() = runTest {
        putPrompt("{{f}}")
        graph()
        val activity = tracked(factory.create(FillViewModel::class.java))
        factory.restoreHandoff(activity, null)
        assertEquals(FillPhase.PICKING, activity.state.value.phase)
        assertTrue(activity.state.value.values.isEmpty())
        assertEquals(DeliveryMode.COPY, activity.state.value.deliveryMode)
        assertEquals(LearningPolicy.EPHEMERAL, activity.state.value.learningPolicy)
        activity.setForeground(true)
        activity.open("a.md")
        runCurrent()
        assertTrue(activity.state.value.values["f"] == "")
        activity.setValue("f", "fresh")
        val before = stateBytes()
        activity.copy()
        runCurrent()
        assertEquals(listOf("copy"), events)
        assertTrue(before == stateBytes())
    }

    @Test fun `handoff preserves the opened document when its file changes and never rewrites the prompt`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.text = "opening snapshot"
        val source = open(FillSession())
        source.setValue("f", "held")
        val handoff = assertNotNull(source.handoff())
        val expected = source.state.value.preview as FillPreview.Rendered
        val replacement = "A changed prompt on disk".encodeToByteArray()
        put(libraryDir.resolve("a.md"), replacement)
        source.endSession()
        val activity = tracked(factory.create(FillViewModel::class.java))
        factory.restoreHandoff(activity, handoff)
        activity.setForeground(true)
        activity.copy()
        runCurrent()
        assertTrue(clipboard.text == expected.text)
        assertEquals(1, clipboard.reads)
        assertTrue(Files.readAllBytes(libraryDir.resolve("a.md")).contentEquals(replacement))
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
    }

    @Test fun `handoff replaces a held form and its late snapshot cannot overwrite the adopted form`() = runTest {
        putPrompt("{{f}}/{{clipboard}}")
        putPrompt("{{other}}/{{clipboard}}", "b.md")
        graph()
        clipboard.text = "source snapshot"
        val source = open(FillSession(learning = LearningPolicy.EPHEMERAL))
        source.setValue("f", "source value")
        val handoff = assertNotNull(source.handoff())
        val expected = source.state.value.preview
        clipboard.deferred = true
        val held = open(FillSession(), path = "b.md")
        held.setValue("other", "old")
        factory.restoreHandoff(held, handoff)
        clipboard.complete("old late snapshot")
        runCurrent()
        assertEquals(expected, held.state.value.preview)
        assertTrue(held.state.value.values == mapOf("f" to "source value"))
        assertEquals(2, clipboard.reads)
        assertEquals(LearningPolicy.EPHEMERAL, held.state.value.learningPolicy)
        held.copy()
        runCurrent()
        assertEquals(listOf("copy"), events)
        assertTrue(core.usage.useEvents(core.load("b.md").identity).isEmpty())
    }

    private fun putPrompt(source: String, path: String = "a.md") = put(libraryDir.resolve(path), source.encodeToByteArray())
    private fun tracked(model: FillViewModel) = model.also { models.put("fill-${modelNumber++}", it) }
    private fun TestScope.open(session: FillSession, endpoint: TextDelivery = CopyTextDelivery(clipboard), path: String = "a.md") =
        tracked(factory.create(session, endpoint)).also { it.setForeground(true); it.open(path); runCurrent() }
    private fun tap(model: FillViewModel) {
        if (model.state.value.deliveryMode == DeliveryMode.COPY) model.copy() else model.insert()
    }

    private fun graph(worker: CoroutineDispatcher = dispatcher) {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val state = AndroidStateStore(stateDir.toFile())
        val recording = object : StateStore by state {
            override fun writePrivate(bytes: ByteArray, path: String) {
                if (failRemember) throw StoreError.IOFailure
                events.add("remember")
                state.writePrivate(bytes, path)
            }
            override fun write(bytes: ByteArray, path: String) {
                if (failUsage) throw StoreError.IOFailure
                events.add("usage")
                state.write(bytes, path)
            }
        }
        val clock = AndroidClock({ clockReads++; Instant.parse("2026-10-14T00:30:00Z") }, { zoneReads++; ZoneOffset.UTC })
        core = LibraryService(prompts, recording, clock, Entropy { count -> ByteArray(count) })
        val repository = LibraryRepository(core, EditingService(core), prompts, worker)
        factory = FillViewModelFactory(repository, FillService(core, clipboard, clock::zone), CopyTextDelivery(clipboard))
    }

    private fun stateBytes(): Map<String, List<Byte>> = if (!Files.exists(stateDir)) emptyMap() else
        Files.walk(stateDir).use { paths -> paths.filter { Files.isRegularFile(it) }.toList()
            .associate { stateDir.relativize(it).toString() to Files.readAllBytes(it).toList() } }

    private inner class FakeClipboard : Clipboard {
        var text: String? = null
        var reads = 0
        var writes = 0
        var deferred = false
        private val pending = mutableListOf<(String?) -> Unit>()
        override fun readText(completion: (String?) -> Unit) { reads++; if (deferred) pending.add(completion) else completion(text) }
        override fun writeText(text: String) { writes++; this.text = text; events.add("copy") }
        fun complete(text: String?) { pending.removeAt(0)(text) }
    }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val tasks = mutableListOf<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.add(block) }
        fun runAll() { while (tasks.isNotEmpty()) tasks.removeAt(0).run() }
    }
}
