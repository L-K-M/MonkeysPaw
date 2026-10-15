package ch.lkmc.monkeyspaw.ime

import android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AppModule
import ch.lkmc.monkeyspaw.entry.*
import ch.lkmc.monkeyspaw.ui.editor.*
import ch.lkmc.monkeyspaw.ui.fill.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.*
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.net.URLEncoder
import java.nio.file.Files
import java.util.Base64
import java.util.UUID
import java.util.logging.Handler
import java.util.logging.Level
import java.util.logging.LogRecord
import java.util.logging.Logger
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.*

/** Runtime-generated sentinels inspect the entire JVM sandbox, including cache/log/temp files. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class ImePrivacyTest : EntryFlowFixture() {
    private val diagnostics = ByteArrayOutputStream()
    private val records = java.util.concurrent.CopyOnWriteArrayList<LogRecord>()
    private val stdout = System.out
    private val stderr = System.err
    private val rootLogger = Logger.getLogger("")
    private val appLogger = Logger.getLogger("MonkeysPaw")
    private val rootLevel = rootLogger.level
    private val appLevel = appLogger.level
    private val handler = object : Handler() {
        override fun publish(record: LogRecord) { records += record }
        override fun flush() = Unit
        override fun close() = Unit
    }

    @BeforeTest fun observeDiagnostics() {
        System.setOut(PrintStream(diagnostics, true, Charsets.UTF_8))
        System.setErr(PrintStream(diagnostics, true, Charsets.UTF_8))
        handler.level = Level.ALL
        rootLogger.level = Level.ALL
        appLogger.level = Level.ALL
        rootLogger.addHandler(handler)
        appLogger.addHandler(handler)
    }

    @AfterTest fun restoreDiagnostics() {
        try {
            release()
            assertTrue(records.isEmpty(), "Unexpected JVM logger call")
            assertEquals(0, diagnostics.size(), "Unexpected stdout/stderr diagnostic")
        } finally {
            rootLogger.removeHandler(handler)
            appLogger.removeHandler(handler)
            rootLogger.level = rootLevel
            appLogger.level = appLevel
            System.setOut(stdout)
            System.setErr(stderr)
        }
    }

    @Test fun `diagnostic capture observes FINE records from app and inherited loggers`() {
        val message = sentinel()
        try {
            for (logger in listOf(Logger.getLogger(""), Logger.getLogger("MonkeysPaw"),
                Logger.getLogger("MonkeysPaw.privacy.probe"))) {
                records.clear()
                logger.fine(message)
                assertTrue(records.any { it.level == Level.FINE && it.message == message }, logger.name)
            }
        } finally { records.clear() }
    }

    @Test fun `diagnostic capture retains concurrent publisher records`() {
        val executor = java.util.concurrent.Executors.newFixedThreadPool(8)
        val start = java.util.concurrent.CountDownLatch(1)
        try {
            val publishers = (0 until 8).map { worker -> executor.submit {
                start.await()
                repeat(128) { record -> handler.publish(LogRecord(Level.FINE, "$worker-$record")) }
            } }
            start.countDown()
            publishers.forEach { it.get() }
            assertEquals(1024, records.size)
            assertEquals(1024, records.map { it.message }.toSet().size)
        } finally { executor.shutdownNow(); records.clear() }
    }

    @Test fun `sentinel scan rejects percent encoded spaces outside permitted files`() = runTest {
        prepare("percent-probe")
        val secret = sentinel()
        val leak = directory.resolve("cache/encoded.txt")
        try {
            put(leak, URLEncoder.encode(secret, Charsets.UTF_8).replace("+", "%20").encodeToByteArray())
            assertFailsWith<AssertionError> { absent(listOf(secret)) }
        } finally { Files.deleteIfExists(leak) }
    }

    @Test fun `cancelled entries and their late builtin callbacks leave every sandbox file unchanged`() = runTest {
        for (lane in Lane.entries) {
            prepare("cancel-${lane.name}")
            val capture = sentinel()
            val value = sentinel()
            val builtin = sentinel()
            val before = disk()
            clipboard.deferred = true
            val form = start(lane, capture)
            pick(lane, form)
            form.setValue("keep", value)
            assertEquals(1, clipboard.pending.size)
            form.cancel()
            release()
            clipboard.pending.removeAt(0)(builtin)
            form.copy()
            form.insert()
            runCurrent()
            assertEquals(FillPhase.CLOSED, form.state.value.phase)
            assertTrue(form.state.value.values.isEmpty())
            assertNull(form.state.value.capturedText)
            assertTrue(effects.isEmpty())
            unchanged(before)
            absent(listOf(capture, value, builtin))
        }
    }

    @Test fun `failed effects retain the form but persist no capture values builtin or error body`() = runTest {
        for (lane in Lane.entries) {
            prepare("failed-${lane.name}")
            val secrets = List(5) { sentinel() }
            clipboard.text = secrets[0]
            errorText = secrets[1]
            val before = disk()
            val form = start(lane, secrets[2])
            pick(lane, form)
            form.setValue("keep", secrets[3])
            form.setValue("once", secrets[4])
            failEffect = true
            tap(lane, form)
            runCurrent()
            assertEquals(FillPhase.EDITING, form.state.value.phase)
            assertNotNull(form.state.value.failure)
            assertTrue(form.state.value.values["keep"] == secrets[3])
            assertTrue(effects.isEmpty())
            unchanged(before)
            absent(secrets)
            form.cancel()
            release()
            runCurrent()
            unchanged(before)
        }
    }

    @Test fun `Application local warm-up and a missing library failure emit no diagnostics or files`() = runTest {
        prepare("startup")
        val scope = AppModule.applicationScope(worker)
        try {
            val before = disk()
            scope.launch { repository.refresh() }
            runCurrent()
            unchanged(before)
            Files.delete(directory.resolve("files/library/prompt.md"))
            Files.delete(directory.resolve("files/library"))
            val missing = disk()
            scope.launch { repository.refresh() }
            runCurrent()
            assertNotNull(repository.state.value.error)
            unchanged(missing)
        } finally { scope.cancel() }
    }

    @Test fun `failed handoff launch and process loss cannot persist or replay the held payload`() = runTest {
        for (lostProcess in listOf(false, true)) {
            prepare("lost-handoff-$lostProcess")
            val secrets = List(3) { sentinel() }
            clipboard.text = secrets[0]
            errorText = secrets[1]
            val before = disk()
            val form = start(Lane.IME)
            pick(Lane.IME, form)
            form.setValue("keep", secrets[2])
            failLaunch = !lostProcess
            controller!!.handoff(controller!!.state.value.generation)
            val token = tokens.single()
            if (lostProcess) {
                val activity = factory.create(FillSession())
                val owner = ViewModelStore().apply { put("activity", activity) }
                try {
                    factory.restoreHandoff(activity, FillHandoffStore().consume(token))
                    assertEquals(FillPhase.PICKING, activity.state.value.phase)
                    assertEquals(LearningPolicy.EPHEMERAL, activity.state.value.learningPolicy)
                    assertTrue(activity.state.value.values.isEmpty())
                    assertNull(activity.state.value.capturedText)
                    activity.copy()
                    activity.insert()
                } finally { owner.clear(); handoffs.clear(token) }
            } else {
                assertTrue(controller!!.state.value.handoffFailed)
                assertEquals(FillPhase.EDITING, form.state.value.phase)
                assertNull(handoffs.consume(token))
                form.cancel()
            }
            release()
            form.copy()
            form.insert()
            runCurrent()
            assertTrue(effects.isEmpty())
            unchanged(before)
            absent(secrets)
        }
    }

    @Test fun `Ephemeral IME Insert Copy and activity handoff keep every value off disk`() = runTest {
        for (completion in listOf("insert", "copy", "handoff")) {
            prepare("ephemeral-$completion")
            val secrets = List(3) { sentinel() }
            clipboard.text = secrets[0]
            editor = ImeEditor(editor.inputType, IME_FLAG_NO_PERSONALIZED_LEARNING, Any())
            val before = disk()
            val form = start(Lane.IME)
            pick(Lane.IME, form)
            form.setValue("keep", secrets[1])
            form.setValue("once", secrets[2])
            assertEquals(LearningPolicy.EPHEMERAL, form.state.value.learningPolicy)
            val completed = if (completion == "handoff") {
                controller!!.handoff(controller!!.state.value.generation)
                val token = tokens.single()
                val handoff = assertNotNull(handoffs.consume(token))
                assertNull(handoffs.consume(token))
                val activity = factory.create(FillSession())
                val owner = ViewModelStore().apply { put("activity", activity) }
                try {
                    factory.restoreHandoff(activity, handoff)
                    activity.setForeground(true)
                    assertEquals(DeliveryMode.COPY, activity.state.value.deliveryMode)
                    assertEquals(LearningPolicy.EPHEMERAL, activity.state.value.learningPolicy)
                    activity.insert()
                    activity.copy()
                    runCurrent()
                    assertTrue(activity.state.value.shouldFinish)
                    activity
                } finally { owner.clear() }
            } else {
                if (completion == "insert") tap(Lane.IME, form) else form.copy()
                runCurrent()
                assertTrue(form.state.value.shouldFinish)
                form
            }
            assertEquals(1, effects.size)
            assertEquals(1, clipboard.reads)
            assertEquals(if (completion == "insert") 0 else 1, clipboard.writes)
            assertFalse(events.any { it == "remember" || it == "usage" })
            completed.endSession()
            release()
            runCurrent()
            unchanged(before)
            absent(secrets)
        }
    }

    @Test fun `Normal delivery writes only remember true and one body-free usage record after restart`() = runTest {
        for (lane in Lane.entries) {
            prepare("normal-${lane.name}")
            val keep = sentinel()
            val transient = sentinel()
            val builtin = sentinel()
            val capture = sentinel()
            clipboard.text = builtin
            val before = disk()
            val form = start(lane, capture)
            pick(lane, form)
            form.setValue("keep", keep)
            form.setValue("once", transient)
            tap(lane, form)
            runCurrent()
            assertTrue(form.state.value.shouldFinish)
            release()
            runCurrent()
            val after = disk()
            val valuesPath = "files/state/values.json"
            val usagePath = "files/state/usage/${identity.storageKey}"
            assertEquals(before.keys + setOf(valuesPath, usagePath), after.keys)
            assertTrue(before.all { (path, bytes) -> after[path] == bytes }, "Existing files changed")
            val restarted = library(state = AndroidStateStore(directory.resolve("files/state").toFile()),
                prompts = AndroidPromptStore(directory.resolve("files/library").toFile()))
            assertTrue(restarted.values.rememberedValues(identity) == mapOf("keep" to keep))
            assertEquals(1, restarted.usage.useEvents(identity).size)
            absent(listOf(transient, builtin, capture))
            absent(listOf(keep), allowed = setOf(valuesPath))
        }
    }

    @Test fun `share draft cancel and refused Save leave no draft log capture or state files`() = runTest {
        prepare("share-draft")
        val capture = sentinel()
        put(directory.resolve("files/library/occupied.md"), "Existing prompt".encodeToByteArray())
        val before = disk()
        share.start(shareRequest(capture))
        share.saveAsNewPrompt()
        val draft = assertIs<ShareDestination.Editing>(share.destination.value).editor
        runCurrent()
        unchanged(before)
        draft.setNewPath("occupied.md")
        draft.save()
        runCurrent()
        assertTrue(draft.state.value.dirty)
        assertTrue(draft.state.value.isNew)
        assertNotNull(draft.state.value.failure)
        unchanged(before)
        share.back()
        draft.resolveDecision(assertNotNull(draft.state.value.pendingDecision).id, EditorDecision.DISCARD)
        release()
        runCurrent()
        unchanged(before)
        absent(listOf(capture))
    }

    @Test fun `explicit share Save permits only its prompt and explicit later save history`() = runTest {
        prepare("share-save")
        val capture = sentinel()
        val body = "---\nprivate: true\n---\n$capture\r\n{{literal}}"
        val before = disk()
        share.start(shareRequest(body))
        share.saveAsNewPrompt()
        val draft = assertIs<ShareDestination.Editing>(share.destination.value).editor
        runCurrent()
        unchanged(before)
        draft.setNewPath("Shared.md")
        draft.save()
        runCurrent()
        val saved = core.load("Shared.md")
        assertIs<PromptIdentity.Assigned>(saved.identity)
        assertTrue(saved.document.body == body)
        assertFalse(saved.document.frontMatter.isPrivate)
        val first = disk()
        assertEquals(before.keys + "files/library/Shared.md", first.keys)
        assertTrue(before.all { (path, bytes) -> first[path] == bytes })
        absent(listOf(capture), allowed = setOf("files/library/Shared.md"))
        draft.edit(assertNotNull(draft.state.value.source) + "\nExplicit edit")
        draft.save()
        runCurrent()
        release()
        val revision = core.history.revisions(saved.identity).single()
        val historyPath = "files/state/history/${saved.identity.storageKey}/${revision.filename}"
        assertEquals(first.keys + historyPath, disk().keys)
        assertTrue(core.history.read(revision).toList() == first.getValue("files/library/Shared.md"))
        assertTrue(core.values.rememberedValues(saved.identity).isEmpty())
        assertTrue(core.usage.useEvents(saved.identity).isEmpty())
        assertTrue(effects.isEmpty())
        assertEquals(0, clipboard.reads)
        absent(listOf(capture), allowed = setOf("files/library/Shared.md", historyPath))
    }

    private fun sentinel() = "n8-${UUID.randomUUID()}-雪 \"\n"

    private fun unchanged(before: Map<String, List<Byte>>) {
        assertTrue(before == disk(), "Cancelled, failed or Ephemeral operation changed sandbox files")
    }

    private fun absent(secrets: List<String>, allowed: Set<String> = emptySet()) {
        val variants = secrets.flatMap { listOf(it, Base64.getEncoder().encodeToString(it.encodeToByteArray()),
            URLEncoder.encode(it, Charsets.UTF_8), URLEncoder.encode(it, Charsets.UTF_8).replace("+", "%20"),
            JsonPrimitive(it).toString().removeSurrounding("\"")) }
        for ((path, bytes) in disk().filterKeys { it !in allowed }) {
            val text = bytes.toByteArray().decodeToString()
            assertFalse(variants.any(text::contains), "Sensitive sentinel persisted in $path")
        }
        assertTrue(records.isEmpty(), "Unexpected JVM logger call")
        assertEquals(0, diagnostics.size(), "Unexpected stdout/stderr diagnostic")
    }
}
