package ch.lkmc.monkeyspaw.entry

import android.app.Activity.RESULT_CANCELED
import android.app.Activity.RESULT_OK
import android.content.Intent.ACTION_PROCESS_TEXT
import android.content.Intent.EXTRA_PROCESS_TEXT
import android.content.Intent.EXTRA_PROCESS_TEXT_READONLY
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.fill.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.test.*
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneOffset
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class ProcessTextEntryTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val entries = ViewModelStore()
    private val events = mutableListOf<String>()
    private val clipboard = FakeClipboard()
    private val endpoints = mutableListOf<TextDelivery>()
    private var creations = 0
    private var failRemember = false
    private var failUsage = false
    private lateinit var core: LibraryService
    private lateinit var entry: ProcessTextEntry
    private lateinit var host: ResultHost

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clearModels() { entries.clear(); Dispatchers.resetMain() }

    @Test fun `editable Insert returns RESULT_OK after the same render with zero clipboard writes`() = runTest {
        prompt("---\nfields:\n  f:\n    type: multiline\n    remember: false\n---\nBefore {{f}} after {{f}}")
        graph()
        val capture = " {{literal}}\r\n🐒 "
        val form = open(request(capture, false))
        assertEquals(DeliveryMode.SELECTION_RESULT, form.state.value.deliveryMode)
        assertTrue(events.isEmpty())
        assertEquals(RESULT_CANCELED, host.code)
        assertEquals(0, clipboard.reads)
        form.insert()
        form.insert()
        form.copy()
        assertEquals(RESULT_OK, host.code)
        assertTrue(host.text == "Before $capture after $capture")
        assertEquals(listOf("result"), events)
        assertEquals(0, clipboard.writes)
        assertFalse(form.state.value.shouldFinish)
        runCurrent()
        assertTrue(form.state.value.shouldFinish)
        assertEquals(listOf("result", "usage"), events)
        val identity = core.load("a.md").identity
        assertTrue(core.values.rememberedValues(identity).isEmpty())
        assertEquals(1, core.usage.useEvents(identity).size)
    }

    @Test fun `read-only default and mistyped flags expose only Copy and leave selection canceled`() = runTest {
        prompt("{{f}}")
        graph()
        for ((index, flag) in listOf(true, null, "false", 0).withIndex()) {
            val form = open(request(flag = flag))
            assertEquals(DeliveryMode.COPY, form.state.value.deliveryMode)
            form.insert()
            assertEquals(index, clipboard.writes)
            assertEquals(RESULT_CANCELED, host.code)
            form.copy()
            form.copy()
            runCurrent()
            assertEquals(index + 1, clipboard.writes)
            assertTrue(clipboard.text == "selection")
            assertEquals(RESULT_CANCELED, host.code)
            assertNull(host.text)
            assertEquals(0, host.results)
            assertTrue(form.state.value.shouldFinish)
        }
    }

    @Test fun `editable explicit Copy writes once learns once and never returns replacement text`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request(flag = false))
        form.copy()
        form.insert()
        form.copy()
        assertEquals(RESULT_CANCELED, host.code)
        assertEquals(listOf("copy"), events)
        runCurrent()
        assertEquals(listOf("copy", "remember", "usage"), events)
        assertEquals(1, clipboard.writes)
        assertEquals(0, host.results)
        assertTrue(form.state.value.shouldFinish)
    }

    @Test fun `capture follows body order and switching or ignoring preserves edits and prefills`() = runTest {
        prompt("---\nfields:\n  second:\n    type: multiline\n    default: second default\n    optional: true\n  first:\n    type: multiline\n    default: first default\n  choice:\n    type: choice\n    options: [one, two]\n    default: one\n---\n{{first}}/{{second}}/{{choice}}/{{implicit}}")
        graph()
        val identity = core.load("a.md").identity
        core.values.record(identity, mapOf("second" to "remembered"))
        events.clear()
        val before = stateBytes()
        val form = open(request(" {{literal}}\n ", false))
        val choice = assertNotNull(form.state.value.capturedText)
        assertEquals(listOf("first", "second", "implicit"), choice.candidates.map { it.name })
        assertEquals("first", choice.selectedField)
        form.selectCapturedField("second")
        assertTrue(form.state.value.values["first"] == "first default")
        form.setValue("second", "")
        form.selectCapturedField("first")
        assertTrue(form.state.value.values["second"] == "")
        form.selectCapturedField("choice")
        assertEquals("first", form.state.value.capturedText?.selectedField)
        form.selectCapturedField(null)
        assertTrue(form.state.value.values["first"] == "first default")
        form.setValue("implicit", "typed")
        form.selectCapturedField("implicit")
        assertTrue(form.state.value.values["implicit"] == "typed")
        assertTrue(before == stateBytes())
        assertTrue(events.isEmpty())
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertEquals(RESULT_CANCELED, host.code)
    }

    @Test fun `implicit text choices builtins and fieldless prompts share the same explicit completion`() = runTest {
        prompt("{{implicit}}", "implicit.md")
        prompt("---\nfields:\n  choice:\n    type: choice\n    options: [one, two]\n    default: one\n---\n{{choice}}", "choice.md")
        prompt("{{date}}", "builtin.md")
        prompt("Fieldless", "fieldless.md")
        graph()
        for (path in listOf("implicit.md", "choice.md", "builtin.md", "fieldless.md")) {
            val form = open(request(flag = false), path)
            val capture = assertNotNull(form.state.value.capturedText)
            if (path == "implicit.md") {
                assertEquals("implicit", capture.selectedField)
                assertEquals(FieldKind.TEXT, capture.candidates.single().kind)
            } else {
                assertNull(capture.selectedField)
                assertTrue(capture.candidates.isEmpty())
            }
            assertEquals(RESULT_CANCELED, host.code)
            assertTrue(form.state.value.copyEnabled)
            form.insert()
            runCurrent()
            assertEquals(RESULT_OK, host.code)
            assertTrue(form.state.value.shouldFinish)
        }
        assertEquals(4, host.results)
        assertEquals(0, clipboard.writes)
        assertEquals(0, clipboard.reads)
    }

    @Test fun `new intent retires old capture and callbacks and recomputes the new prompt choice`() = runTest {
        prompt("{{old}}/{{clipboard}}")
        prompt("---\nfields:\n  next:\n    type: multiline\n---\n{{next}}", "b.md")
        graph()
        clipboard.deferred = true
        val old = open(request("old capture", false))
        val oldEndpoint = endpoints.single()
        val before = stateBytes()
        val fresh = open(request("new capture", true), "b.md")
        assertEquals(FillPhase.CLOSED, old.state.value.phase)
        assertTrue(old.state.value.values.isEmpty())
        assertEquals("next", fresh.state.value.capturedText?.selectedField)
        assertTrue(fresh.state.value.values["next"] == "new capture")
        clipboard.complete("late builtin")
        old.insert()
        old.copy()
        runCurrent()
        assertEquals(TextDeliveryResult.STALE, oldEndpoint.deliver(DeliveryMode.SELECTION_RESULT, "late output"))
        assertEquals(FillPhase.EDITING, fresh.state.value.phase)
        assertEquals(RESULT_CANCELED, host.code)
        assertTrue(events.isEmpty())
        assertTrue(before == stateBytes())
        assertEquals(0, clipboard.writes)
    }

    @Test fun `replacing a valid form does not emit a canceled entry or finish the caller`() = runTest {
        prompt("{{f}}")
        graph()
        open(request(flag = false))
        var finishes = 0
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            entry.form.collectLatest { form ->
                if (form == null) finishes++
                else form.state.collect {
                    if (entry.form.value === form && it.shouldFinish) finishes++
                }
            }
        }
        val fresh = open(request("fresh capture", true))
        assertEquals(0, finishes)
        assertEquals(FillPhase.EDITING, fresh.state.value.phase)
        fresh.cancel()
        runCurrent()
        assertEquals(1, finishes)
    }

    @Test fun `cancel drops capture rejects late callbacks and does not learn`() = runTest {
        prompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.deferred = true
        val form = open(request(flag = false))
        val before = stateBytes()
        form.cancel()
        clipboard.complete("late builtin")
        form.insert()
        form.copy()
        runCurrent()
        assertEquals(FillPhase.CLOSED, form.state.value.phase)
        assertTrue(form.state.value.values.isEmpty())
        assertTrue(form.state.value.shouldFinish)
        assertEquals(TextDeliveryResult.STALE, endpoints.single().deliver(DeliveryMode.COPY, "late output"))
        assertEquals(RESULT_CANCELED, host.code)
        assertTrue(before == stateBytes())
        assertTrue(events.isEmpty())
        entry.close()
        entry.close()
        entry.start(request(flag = false))
        assertNull(entry.form.value)
        assertEquals(1, creations)
    }

    @Test fun `invalid new intent clears old form before IO and defaults result to canceled`() = runTest {
        prompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.deferred = true
        val old = open(request(flag = false))
        val before = stateBytes()
        entry.start(null)
        clipboard.complete("late builtin")
        runCurrent()
        assertNull(entry.form.value)
        assertEquals(FillPhase.CLOSED, old.state.value.phase)
        assertEquals(1, creations)
        assertEquals(RESULT_CANCELED, host.code)
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
        assertTrue(before == stateBytes())
    }

    @Test fun `a restored process without retained memory has no form capture or result to replay`() = runTest {
        graph()
        entry.start(null)
        assertTrue(entry.initialized)
        assertNull(entry.form.value)
        assertEquals(0, creations)
        assertEquals(RESULT_CANCELED, host.code)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertTrue(stateBytes().isEmpty())
    }

    @Test fun `background and old activity lifecycle calls cannot deliver to a retired host`() = runTest {
        prompt("{{f}}/{{clipboard}}")
        graph()
        clipboard.text = "opening builtin"
        val form = open(request(flag = false))
        form.setValue("f", "edited")
        val before = form.state.value.preview
        val oldHost = host
        entry.detach(oldHost)
        form.insert()
        form.copy()
        assertEquals(0, clipboard.writes)
        val replacement = ResultHost()
        entry.attach(replacement, replacement::setResult)
        assertSame(form, entry.form.value)
        assertFalse(form.state.value.foreground)
        entry.setForeground(replacement, true)
        entry.setForeground(oldHost, false)
        entry.detach(oldHost)
        assertTrue(form.state.value.foreground)
        assertEquals(before, form.state.value.preview)
        assertEquals(1, clipboard.reads)
        form.insert()
        runCurrent()
        assertEquals(0, oldHost.results)
        assertEquals(1, replacement.results)
        assertEquals(RESULT_OK, replacement.code)
        assertTrue(replacement.text == "edited/opening builtin")
        assertEquals(0, clipboard.writes)
    }

    @Test fun `rotation during accepted learning rebinds result without another effect or record`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request(flag = false))
        form.insert()
        assertEquals(FillPhase.DELIVERING, form.state.value.phase)
        val previous = host
        entry.detach(previous)
        val replacement = ResultHost()
        entry.attach(replacement, replacement::setResult)
        entry.setForeground(replacement, true)
        entry.detach(previous)
        assertEquals(RESULT_OK, replacement.code)
        assertTrue(replacement.text == "selection")
        form.insert()
        form.copy()
        runCurrent()
        assertEquals(listOf("result", "result", "remember", "usage"), events)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertTrue(form.state.value.shouldFinish)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `a new intent during accepted learning clears the old result but preserves its one record`() = runTest {
        prompt("{{f}}")
        graph()
        val old = open(request("old capture", false))
        old.insert()
        val fresh = open(request("new capture", true))
        runCurrent()
        assertEquals(RESULT_CANCELED, host.code)
        assertNull(host.text)
        assertEquals(FillPhase.CLOSED, old.state.value.phase)
        assertEquals(FillPhase.EDITING, fresh.state.value.phase)
        assertTrue(fresh.state.value.values["f"] == "new capture")
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
        assertEquals(listOf("result", "remember", "usage"), events)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `failed result keeps the form and requires explicit Copy without automatic fallback`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request(flag = false))
        val before = stateBytes()
        host.fail = true
        form.insert()
        runCurrent()
        assertEquals(FillPhase.EDITING, form.state.value.phase)
        assertEquals(FillFailure.DELIVERY, form.state.value.failure)
        assertEquals(RESULT_CANCELED, host.code)
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
        assertTrue(before == stateBytes())
        host.fail = false
        form.copy()
        runCurrent()
        assertEquals(RESULT_CANCELED, host.code)
        assertEquals(listOf("copy", "remember", "usage"), events)
        assertEquals(1, clipboard.writes)
        assertTrue(form.state.value.shouldFinish)
    }

    @Test fun `learning warning retains the accepted result for Done and never retries Insert`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request(flag = false))
        failRemember = true
        failUsage = true
        form.insert()
        runCurrent()
        assertEquals(FillPhase.DELIVERED, form.state.value.phase)
        assertEquals(2, form.state.value.warnings.size)
        assertFalse(form.state.value.shouldFinish)
        form.insert()
        form.copy()
        form.cancel() // Done acknowledges the shared Fill warning.
        assertTrue(form.state.value.shouldFinish)
        assertEquals(RESULT_OK, host.code)
        assertTrue(host.text == "selection")
        assertEquals(1, host.results)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `manifest selection filter keeps a normal caller result activity`() {
        val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
        val namespace = "http://schemas.android.com/apk/res/android"
        val manifest = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(sources.resolve("AndroidManifest.xml")).documentElement
        fun children(element: Element, tag: String) = element.getElementsByTagName(tag).let { nodes ->
            (0 until nodes.length).map { nodes.item(it) as Element }
        }
        fun Element.attr(name: String) = getAttributeNS(namespace, name)
        val activity = children(manifest, "activity").single { it.attr("name") == ".entry.ProcessTextActivity" }
        assertEquals("true", activity.attr("exported"))
        assertEquals("@string/app_name", activity.attr("label"))
        for (attribute in listOf("launchMode", "taskAffinity", "noHistory", "process", "allowTaskReparenting")) {
            assertFalse(activity.hasAttributeNS(namespace, attribute))
        }
        val filter = children(activity, "intent-filter").single()
        assertEquals(ACTION_PROCESS_TEXT, children(filter, "action").single().attr("name"))
        assertEquals("android.intent.category.DEFAULT", children(filter, "category").single().attr("name"))
        val data = children(filter, "data").single()
        assertEquals("text/plain", data.attr("mimeType"))
        for (attribute in listOf("scheme", "host", "path")) assertFalse(data.hasAttributeNS(namespace, attribute))
    }

    @Test fun `activity hosts the existing route and returns only a fresh result without saved capture`() {
        val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
        val activity = sources.resolve("kotlin/ch/lkmc/monkeyspaw/entry/ProcessTextActivity.kt").readText()
        assertTrue(activity.contains("FillRouteContent(it, library, seedOffer"))
        assertTrue(activity.contains("setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, text))"))
        assertTrue(activity.contains("setResult(RESULT_CANCELED)"))
        assertTrue(activity.contains("setIntent(Intent())"))
        assertTrue(activity.contains("if (!entry.initialized)"))
        assertTrue(activity.contains("if (savedInstanceState == null) ProcessTextIntentDecoder.read(intent) else null"))
        assertTrue(activity.contains("if (entry.form.value === form && it.shouldFinish) finish()"))
        assertFalse(Regex("\\b(?:startActivity|startActivityForResult|FLAG_ACTIVITY_NEW_TASK|SavedStateHandle|rememberSaveable|getBooleanExtra|putExtras|Log|Toast)\\b")
            .containsMatchIn(activity))
    }

    private fun graph() {
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
        val clock = AndroidClock({ Instant.parse("2026-10-14T00:30:00Z") }, { ZoneOffset.UTC })
        core = LibraryService(prompts, recording, clock, Entropy { count -> ByteArray(count) })
        val repository = LibraryRepository(core, EditingService(core), prompts, dispatcher)
        val copy = CopyTextDelivery(clipboard)
        val factory = FillViewModelFactory(repository, FillService(core, clipboard, clock::zone), copy)
        entry = ProcessTextEntry({ session, endpoint ->
            creations++
            endpoints.add(endpoint)
            factory.create(session, endpoint)
        }, copy)
        entries.put("entry", entry)
        host = ResultHost()
        entry.attach(host, host::setResult)
        entry.setForeground(host, true)
    }

    private fun TestScope.open(request: CapturedTextRequest, path: String = "a.md"): FillViewModel {
        entry.start(request)
        return assertNotNull(entry.form.value).also { it.open(path); runCurrent() }
    }

    private fun request(text: String = "selection", flag: Any? = false) = assertNotNull(
        ProcessTextIntentDecoder.decode(ACTION_PROCESS_TEXT, "text/plain") { key ->
            when (key) {
                EXTRA_PROCESS_TEXT -> text
                EXTRA_PROCESS_TEXT_READONLY -> flag
                else -> error("Unexpected extra")
            }
        })

    private fun prompt(source: String, path: String = "a.md") = put(libraryDir.resolve(path), source.encodeToByteArray())
    private fun stateBytes(): Map<String, List<Byte>> = if (!Files.exists(stateDir)) emptyMap() else
        Files.walk(stateDir).use { paths -> paths.filter { Files.isRegularFile(it) }.toList()
            .associate { stateDir.relativize(it).toString() to Files.readAllBytes(it).toList() } }

    private inner class ResultHost {
        var code = RESULT_CANCELED
        var text: String? = null
        var results = 0
        var fail = false
        fun setResult(value: String?) {
            if (fail) error("Untrusted platform diagnostic")
            code = if (value == null) RESULT_CANCELED else RESULT_OK
            text = value
            if (value != null) { results++; events.add("result") }
        }
    }

    private inner class FakeClipboard : Clipboard {
        var text: String? = null
        var reads = 0
        var writes = 0
        var deferred = false
        private val pending = mutableListOf<(String?) -> Unit>()
        override fun readText(completion: (String?) -> Unit) {
            reads++
            if (deferred) pending.add(completion) else completion(text)
        }
        override fun writeText(text: String) { writes++; this.text = text; events.add("copy") }
        fun complete(text: String?) { pending.removeAt(0)(text) }
    }
}
