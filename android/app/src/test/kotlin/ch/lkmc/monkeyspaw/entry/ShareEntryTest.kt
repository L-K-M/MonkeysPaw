package ch.lkmc.monkeyspaw.entry

import android.content.Intent.ACTION_SEND
import android.content.Intent.EXTRA_TEXT
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.ui.editor.*
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
internal class ShareEntryTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val entries = ViewModelStore()
    private val events = mutableListOf<String>()
    private val clipboard = FakeClipboard()
    private val endpoints = mutableListOf<TextDelivery>()
    private var fillCreations = 0
    private var creates = 0
    private var replacements = 0
    private var failCreate = false
    private var failRemember = false
    private var failUsage = false
    private lateinit var core: LibraryService
    private lateinit var repository: LibraryRepository
    private lateinit var entry: ShareEntry
    private var host = Any()

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clearModels() { entries.clear(); Dispatchers.resetMain() }

    @Test fun `chooser creates no form file remembered state or clipboard effect`() = runTest {
        graph()
        val before = disk()
        entry.start(request())
        runCurrent()
        assertEquals(ShareDestination.Choosing, entry.destination.value)
        assertTrue(entry.initialized)
        assertEquals(0, fillCreations)
        assertEquals(0, creates)
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        assertTrue(before == disk())
        assertTrue(events.isEmpty())
    }

    @Test fun `invalid input and lost process memory reject before constructing either model`() = runTest {
        graph()
        val before = disk()
        val selection = CapturedTextRequest.parse(android.content.Intent.ACTION_PROCESS_TEXT, "text/plain", "selection")
        for (request in listOf(null, selection)) {
            entry.start(request)
            entry.useInPrompt()
            entry.saveAsNewPrompt()
            runCurrent()
            assertEquals(ShareDestination.Closed, entry.destination.value)
        }
        assertEquals(0, fillCreations)
        assertEquals(0, creates)
        assertTrue(before == disk())
        assertTrue(events.isEmpty())
    }

    @Test fun `existing prompt shares Copy render success ordering and exactly once learning`() = runTest {
        prompt("---\nfields:\n  f:\n    type: multiline\n    remember: false\n---\nBefore {{f}} after {{f}}")
        graph()
        val capture = " {{literal}}\r\n🐒 "
        val form = open(request(capture))
        assertEquals(DeliveryMode.COPY, form.state.value.deliveryMode)
        form.insert()
        assertEquals(0, clipboard.writes)
        assertTrue(events.isEmpty())
        assertEquals(TextDeliveryResult.REFUSED, endpoints.single().deliver(DeliveryMode.SELECTION_RESULT, "ignored"))
        form.copy()
        form.copy()
        assertTrue(clipboard.text == "Before $capture after $capture")
        assertEquals(listOf("copy"), events)
        assertFalse(form.state.value.shouldFinish)
        runCurrent()
        assertTrue(form.state.value.shouldFinish)
        assertEquals(listOf("copy", "usage"), events)
        assertEquals(1, clipboard.writes)
        assertEquals(0, clipboard.reads)
        val identity = core.load("a.md").identity
        assertTrue(core.values.rememberedValues(identity).isEmpty())
        assertEquals(1, core.usage.useEvents(identity).size)
        assertEquals(0, creates)
    }

    @Test fun `same body-order chooser switches ignores and restores prefills while keeping edits`() = runTest {
        prompt("---\nfields:\n  second:\n    type: multiline\n    default: second default\n    optional: true\n  first:\n    type: multiline\n    default: first default\n  choice:\n    type: choice\n    options: [one, two]\n    default: one\n---\n{{first}}/{{second}}/{{choice}}/{{implicit}}")
        graph()
        core.values.record(core.load("a.md").identity, mapOf("second" to "remembered"))
        events.clear()
        val before = disk()
        val form = open(request(" {{literal}}\n "))
        assertEquals(listOf("first", "second", "implicit"), form.state.value.capturedText?.candidates?.map { it.name })
        assertEquals("first", form.state.value.capturedText?.selectedField)
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
        assertTrue(before == disk())
        assertTrue(events.isEmpty())
    }

    @Test fun `implicit choice-only builtin-only and fieldless prompts wait for explicit Copy`() = runTest {
        prompt("{{implicit}}", "implicit.md")
        prompt("---\nfields:\n  c:\n    type: choice\n    options: [one, two]\n    default: one\n---\n{{c}}", "choice.md")
        prompt("{{date}}", "builtin.md")
        prompt("Fieldless", "fieldless.md")
        graph()
        for ((index, path) in listOf("implicit.md", "choice.md", "builtin.md", "fieldless.md").withIndex()) {
            val form = open(request(), path)
            val capture = assertNotNull(form.state.value.capturedText)
            assertEquals(if (index == 0) "implicit" else null, capture.selectedField)
            assertEquals(if (index == 0) 1 else 0, capture.candidates.size)
            assertEquals(index, clipboard.writes)
            assertTrue(form.state.value.copyEnabled)
            form.copy()
            runCurrent()
            assertTrue(form.state.value.shouldFinish)
            assertEquals(index + 1, clipboard.writes)
        }
        assertEquals(0, clipboard.reads)
    }

    @Test fun `failed Copy retains capture and learns nothing until an explicit successful retry`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request())
        val before = disk()
        clipboard.failWrite = true
        form.copy()
        runCurrent()
        assertEquals(FillPhase.EDITING, form.state.value.phase)
        assertEquals(FillFailure.CLIPBOARD, form.state.value.failure)
        assertTrue(before == disk())
        assertTrue(events.isEmpty())
        assertTrue(form.state.value.values["f"] == "shared")
        clipboard.failWrite = false
        form.copy()
        runCurrent()
        assertEquals(listOf("copy", "remember", "usage"), events)
        assertEquals(1, clipboard.writes)
    }

    @Test fun `successful Copy warnings require Done without repeating delivery`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request())
        failRemember = true
        failUsage = true
        form.copy()
        runCurrent()
        assertEquals(FillPhase.DELIVERED, form.state.value.phase)
        assertEquals(2, form.state.value.warnings.size)
        assertFalse(form.state.value.shouldFinish)
        form.copy()
        entry.back()
        assertTrue(form.state.value.shouldFinish)
        assertEquals(listOf("copy"), events)
        assertEquals(1, clipboard.writes)
    }

    @Test fun `new-prompt choice uses the K16 draft and never imports shared metadata`() = runTest {
        graph()
        val capture = "---\nid: 01J0N4QX000000000000000000\nfavorite: true\nmodel: untrusted\n---\n  e\u0301 {{x}}\r\n\r\n"
        val before = disk()
        val editor = newPrompt(capture)
        runCurrent()
        val draft = assertNotNull(editor.state.value.source)
        val parsed = PromptCodec.parse(draft, "Untitled.md")
        assertTrue(parsed.body == capture)
        assertNull(parsed.frontMatter.id)
        assertFalse(parsed.frontMatter.favorite)
        assertTrue(editor.state.value.isNew)
        assertTrue(editor.state.value.dirty)
        assertFalse(editor.state.value.canCommand)
        assertTrue(before == disk())
        assertEquals(0, creates)
        assertEquals(0, replacements)
        assertEquals(0, fillCreations)
        assertTrue(events.isEmpty())
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.writes)
        entry.useInPrompt()
        entry.saveAsNewPrompt()
        assertSame(editor, assertIs<ShareDestination.Editing>(entry.destination.value).editor)
    }

    @Test fun `explicit Save exclusively creates fresh IDs with exact body and user metadata policy`() = runTest {
        graph()
        val body = "  e\u0301 {{x}}\r\n\r\n"
        val editor = newPrompt(body)
        editor.setNewPath("Notes/new.md")
        editor.edit("---\nmodel:\n  provider: custom\n  options: [one, two]\n---\n" + body)
        editor.save()
        editor.save()
        assertFalse(Files.exists(libraryDir.resolve("Notes/new.md")))
        runCurrent()
        assertEquals(1, creates)
        assertEquals(0, replacements)
        assertFalse(editor.state.value.dirty)
        assertFalse(editor.state.value.isNew)
        assertIs<PromptIdentity.Assigned>(editor.state.value.selection?.identity)
        val first = core.load("Notes/new.md")
        assertTrue(first.document.body == body)
        assertTrue(first.document.source.contains("model:\n  provider: custom\n  options:\n  - one\n  - two\n"))
        assertFalse(Files.exists(stateDir.resolve("values.json")))
        assertTrue(core.usage.useEvents(first.identity).isEmpty())
        assertTrue(core.history.revisions(first.identity).isEmpty())
        val second = newPrompt(body)
        second.setNewPath("Notes/second.md")
        second.save()
        runCurrent()
        assertNotEquals(first.identity, core.load("Notes/second.md").identity)
        assertEquals(2, creates)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `explicit Save of fenced share preserves it in body and assigns its own ID`() = runTest {
        graph()
        val body = "---\nid: 01J0N4QX000000000000000000\nprivate: true\n---\nhttps://example.invalid/path\r\n"
        val editor = newPrompt(body)
        editor.save()
        runCurrent()
        val loaded = core.load("Untitled.md")
        assertTrue(loaded.document.body == body)
        assertNotNull(loaded.document.frontMatter.id)
        assertFalse(loaded.document.frontMatter.isPrivate)
        assertEquals(1, creates)
        assertFalse(editor.state.value.dirty)
        assertEquals(0, clipboard.writes)
    }

    @Test fun `occupied destination refuses replacement and retains editable draft for retry`() = runTest {
        prompt("Existing", "Untitled.md")
        graph()
        val editor = newPrompt()
        val draft = editor.state.value.source
        editor.save()
        runCurrent()
        assertEquals(EditorFailure.OCCUPIED, editor.state.value.failure)
        assertTrue(editor.state.value.source == draft)
        assertTrue(editor.state.value.isNew && editor.state.value.dirty && editor.state.value.canEdit)
        assertTrue(Files.readString(libraryDir.resolve("Untitled.md")) == "Existing")
        assertEquals(0, replacements)
        editor.setNewPath("unused.md")
        editor.save()
        runCurrent()
        assertFalse(editor.state.value.dirty)
        assertTrue(core.load("unused.md").document.body == "shared")
    }

    @Test fun `write failure and invalid prompt preserve the new draft and create no file`() = runTest {
        graph()
        val editor = newPrompt()
        failCreate = true
        editor.save()
        runCurrent()
        assertEquals(EditorFailure.DATA, editor.state.value.failure)
        assertTrue(editor.state.value.isNew && editor.state.value.dirty)
        assertFalse(Files.exists(libraryDir.resolve("Untitled.md")))
        assertTrue(editor.state.value.source == "---\n---\nshared")
        failCreate = false
        editor.edit("---\n---\n{{unclosed")
        editor.save()
        runCurrent()
        assertEquals(EditorFailure.INVALID, editor.state.value.failure)
        assertTrue(editor.state.value.source == "---\n---\n{{unclosed")
        assertFalse(Files.exists(libraryDir.resolve("Untitled.md")))
        assertTrue(editor.state.value.canEdit)
        assertEquals(1, creates)
        assertEquals(0, replacements)
    }

    @Test fun `Back from chooser or Fill retires capture without effects and ignores late taps`() = runTest {
        prompt("{{f}}")
        graph()
        val before = disk()
        val form = open(request())
        entry.back()
        assertTrue(form.state.value.shouldFinish)
        form.copy()
        entry.start(request())
        entry.back()
        entry.useInPrompt()
        entry.saveAsNewPrompt()
        entry.start(request())
        runCurrent()
        assertEquals(ShareDestination.Closed, entry.destination.value)
        assertEquals(1, fillCreations)
        assertTrue(before == disk())
        assertTrue(events.isEmpty())
    }

    @Test fun `editor Back uses the existing unsaved Save Discard Cancel guard`() = runTest {
        graph()
        val editor = newPrompt()
        val draft = editor.state.value.source
        entry.back()
        editor.resolveDecision(assertNotNull(editor.state.value.pendingDecision).id, EditorDecision.CANCEL)
        assertTrue(editor.state.value.source == draft)
        assertTrue(editor.state.value.isOpen)
        assertFalse(Files.exists(libraryDir.resolve("Untitled.md")))
        entry.back()
        editor.resolveDecision(assertNotNull(editor.state.value.pendingDecision).id, EditorDecision.DISCARD)
        runCurrent()
        assertFalse(editor.state.value.isOpen)
        assertEquals(0, creates)
        assertTrue(events.isEmpty())
    }

    @Test fun `editor Back Save closes only after successful exclusive creation`() = runTest {
        prompt("Existing", "Untitled.md")
        graph()
        val editor = newPrompt()
        entry.back()
        editor.resolveDecision(assertNotNull(editor.state.value.pendingDecision).id, EditorDecision.SAVE)
        runCurrent()
        assertTrue(editor.state.value.isOpen && editor.state.value.dirty)
        assertNotNull(editor.state.value.pendingDecision)
        assertEquals(EditorFailure.OCCUPIED, editor.state.value.failure)
        editor.setNewPath("new.md")
        editor.resolveDecision(assertNotNull(editor.state.value.pendingDecision).id, EditorDecision.SAVE)
        runCurrent()
        assertFalse(editor.state.value.isOpen)
        assertTrue(core.load("new.md").document.body == "shared")
        assertTrue(Files.readString(libraryDir.resolve("Untitled.md")) == "Existing")
    }

    @Test fun `new intents replace chooser Fill and editor without stale capture or finish`() = runTest {
        prompt("{{f}}")
        graph()
        val before = disk()
        entry.start(request("first"))
        val form = open(request("second"))
        var finished = false
        val observation = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            entry.destination.collectLatest { current ->
                if (current is ShareDestination.Filling) current.form.state.collect {
                    if (entry.destination.value === current && it.shouldFinish) finished = true
                }
            }
        }
        val stale = endpoints.last()
        val editor = newPrompt("third")
        form.copy()
        assertEquals(TextDeliveryResult.STALE, stale.deliver(DeliveryMode.COPY, "stale"))
        assertEquals(FillPhase.CLOSED, form.state.value.phase)
        assertFalse(finished)
        entry.start(request("fourth"))
        editor.save()
        entry.saveAsNewPrompt()
        runCurrent()
        val current = assertIs<ShareDestination.Editing>(entry.destination.value).editor
        assertTrue(current.state.value.source == "---\n---\nfourth")
        assertFalse(editor.state.value.isOpen)
        assertTrue(before == disk())
        assertTrue(events.isEmpty())
        observation.cancel()
    }

    @Test fun `queued explicit Save cannot write after its share is replaced`() = runTest {
        graph()
        val editor = newPrompt("old")
        editor.save()
        entry.start(request("fresh"))
        runCurrent()
        assertEquals(ShareDestination.Choosing, entry.destination.value)
        assertEquals(0, creates)
        assertFalse(Files.exists(libraryDir.resolve("Untitled.md")))
    }

    @Test fun `late builtin callback cannot update a replacement or deliver stale text`() = runTest {
        prompt("{{clipboard}}/{{f}}")
        graph()
        clipboard.deferred = true
        val old = open(request("old"))
        assertFalse(old.state.value.builtinsResolved)
        entry.start(request("fresh"))
        clipboard.complete("old builtin")
        old.copy()
        runCurrent()
        assertEquals(ShareDestination.Choosing, entry.destination.value)
        assertEquals(FillPhase.CLOSED, old.state.value.phase)
        assertTrue(events.isEmpty())
        assertEquals(0, clipboard.writes)
    }

    @Test fun `rotation retains one capture form builtin snapshot and current-owner effect guard`() = runTest {
        prompt("{{clipboard}}/{{f}}")
        graph()
        clipboard.text = "opening builtin"
        val form = open(request())
        form.setValue("f", "edited")
        clipboard.text = "later builtin"
        val oldHost = host
        entry.detach(oldHost)
        form.copy()
        assertEquals(TextDeliveryResult.STALE, endpoints.last().deliver(DeliveryMode.COPY, "ignored"))
        host = Any()
        entry.attach(host)
        entry.setForeground(host, true)
        entry.detach(oldHost)
        entry.setForeground(oldHost, false)
        assertSame(form, assertIs<ShareDestination.Filling>(entry.destination.value).form)
        form.copy()
        runCurrent()
        assertTrue(clipboard.text == "opening builtin/edited")
        assertEquals(1, clipboard.reads)
        assertEquals(1, fillCreations)
        assertEquals(1, clipboard.writes)
    }

    @Test fun `rotation retains the unsaved editor draft without persisting it`() = runTest {
        graph()
        val editor = newPrompt()
        editor.edit("---\n---\nEdited")
        editor.setNewPath("draft.md")
        entry.detach(host)
        host = Any()
        entry.attach(host)
        entry.setForeground(host, true)
        runCurrent()
        assertSame(editor, assertIs<ShareDestination.Editing>(entry.destination.value).editor)
        assertTrue(editor.state.value.source == "---\n---\nEdited")
        assertEquals("draft.md", editor.state.value.relativePath)
        assertEquals(0, creates)
        assertFalse(Files.exists(libraryDir.resolve("draft.md")))
    }

    @Test fun `invalid replacement retires active form while accepted Copy keeps only its one record`() = runTest {
        prompt("{{f}}")
        graph()
        val form = open(request())
        form.copy()
        entry.start(null)
        form.copy()
        runCurrent()
        assertEquals(ShareDestination.Closed, entry.destination.value)
        assertEquals(FillPhase.CLOSED, form.state.value.phase)
        assertEquals(listOf("copy", "remember", "usage"), events)
        assertEquals(1, clipboard.writes)
        assertEquals(1, core.usage.useEvents(core.load("a.md").identity).size)
    }

    @Test fun `manifest and activity expose only capture with the shared routes and no saved payload`() {
        val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
        val namespace = "http://schemas.android.com/apk/res/android"
        val manifest = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(sources.resolve("AndroidManifest.xml")).documentElement
        fun children(element: Element, tag: String) = element.getElementsByTagName(tag).let { nodes ->
            (0 until nodes.length).map { nodes.item(it) as Element }
        }
        fun Element.attr(name: String) = getAttributeNS(namespace, name)
        val activity = children(manifest, "activity").single { it.attr("name") == ".entry.ShareReceiverActivity" }
        assertEquals("true", activity.attr("exported"))
        assertFalse(activity.hasAttributeNS(namespace, "label"))
        for (attribute in listOf("launchMode", "taskAffinity", "noHistory", "process", "allowTaskReparenting")) {
            assertFalse(activity.hasAttributeNS(namespace, attribute))
        }
        val filter = children(activity, "intent-filter").single()
        assertEquals(ACTION_SEND, children(filter, "action").single().attr("name"))
        assertEquals("android.intent.category.DEFAULT", children(filter, "category").single().attr("name"))
        val data = children(filter, "data").single()
        assertEquals("text/plain", data.attr("mimeType"))
        for (attribute in listOf("scheme", "host", "path")) assertFalse(data.hasAttributeNS(namespace, attribute))
        val source = sources.resolve("kotlin/ch/lkmc/monkeyspaw/entry/ShareReceiverActivity.kt").readText()
        assertTrue(source.contains("FillRouteContent(destination.form, library, seedOffer"))
        assertTrue(source.contains("EditorScreen(state = editor.state.collectAsStateWithLifecycle().value"))
        assertTrue(source.contains("BackHandler { entry.back() }"))
        assertTrue(source.contains("setIntent(Intent())"))
        assertTrue(source.contains("if (!entry.initialized)"))
        assertTrue(source.contains("if (savedInstanceState == null) ShareIntentDecoder.read(intent) else null"))
        assertTrue(source.contains("entry.destination.value === destination"))
        val boundary = source + sources.resolve("kotlin/ch/lkmc/monkeyspaw/entry/ShareEntry.kt").readText()
        assertFalse(Regex("\\b(?:startActivity|startActivityForResult|setResult|commitText|SavedStateHandle|rememberSaveable|putExtra|HttpTransport|URL|Log|Toast)\\b")
            .containsMatchIn(boundary))
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
        val tracked = object : PromptStore by prompts {
            override fun create(bytes: ByteArray, path: String) {
                creates++
                if (failCreate) throw StoreError.IOFailure
                prompts.create(bytes, path)
            }
            override fun write(bytes: ByteArray, path: String) { replacements++; prompts.write(bytes, path) }
        }
        val clock = AndroidClock({ Instant.parse("2026-10-14T00:30:00Z") }, { ZoneOffset.UTC })
        var draw = 0
        core = LibraryService(tracked, recording, clock, Entropy { count -> ByteArray(count) { (draw++).toByte() } })
        repository = LibraryRepository(core, EditingService(core), prompts, dispatcher)
        val copy = CopyTextDelivery(clipboard)
        val factory = FillViewModelFactory(repository, FillService(core, clipboard, clock::zone), copy)
        entry = ShareEntry({ session, endpoint ->
            fillCreations++
            endpoints.add(endpoint)
            factory.create(session, endpoint)
        }, copy, EditorViewModelFactory(repository, dispatcher, clock))
        entries.put("entry", entry)
        entry.attach(host)
        entry.setForeground(host, true)
    }

    private fun TestScope.open(request: CapturedTextRequest, path: String = "a.md"): FillViewModel {
        entry.start(request)
        entry.useInPrompt()
        entry.useInPrompt()
        entry.saveAsNewPrompt()
        return assertIs<ShareDestination.Filling>(entry.destination.value).form.also { it.open(path); runCurrent() }
    }

    private fun newPrompt(text: String = "shared"): EditorViewModel {
        entry.start(request(text))
        entry.saveAsNewPrompt()
        return assertIs<ShareDestination.Editing>(entry.destination.value).editor
    }

    private fun request(text: String = "shared") = assertNotNull(ShareIntentDecoder.decode(ACTION_SEND, "text/plain") {
        assertEquals(EXTRA_TEXT, it)
        text
    })
    private fun prompt(source: String, path: String = "a.md") = put(libraryDir.resolve(path), source.encodeToByteArray())
    private fun disk(): Map<String, List<Byte>> = Files.walk(filesDir.takeIf(Files::exists) ?: temporary).use { paths ->
        paths.filter { Files.isRegularFile(it) }.toList()
            .associate { temporary.relativize(it).toString() to Files.readAllBytes(it).toList() }
    }

    private inner class FakeClipboard : Clipboard {
        var text: String? = null
        var reads = 0
        var writes = 0
        var failWrite = false
        var deferred = false
        private val pending = mutableListOf<(String?) -> Unit>()
        override fun readText(completion: (String?) -> Unit) {
            reads++
            if (deferred) pending.add(completion) else completion(text)
        }
        override fun writeText(text: String) {
            if (failWrite) error("Untrusted clipboard diagnostic")
            writes++; this.text = text; events.add("copy")
        }
        fun complete(text: String?) { pending.removeAt(0)(text) }
    }
}
