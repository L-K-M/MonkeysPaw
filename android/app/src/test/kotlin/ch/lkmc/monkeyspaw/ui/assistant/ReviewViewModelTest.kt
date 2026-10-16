package ch.lkmc.monkeyspaw.ui.assistant

import androidx.lifecycle.ViewModelStore
import androidx.datastore.core.DataStore
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.ui.editor.*
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import dagger.Lazy
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class ReviewViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val applicationScope = CoroutineScope(SupervisorJob() + dispatcher)
    private var sequence = 0

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clear() { models.clear(); applicationScope.cancel(); Dispatchers.resetMain() }

    private class Worker(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        var held = false
        var executing = false
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            val work = Runnable { executing = true; try { block.run() } finally { executing = false } }
            if (held) tasks.addLast(work) else delegate.dispatch(context, work)
        }
        fun releaseAll() { held = false; while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    private class Client : AssistantClient {
        val calls = mutableListOf<AssistantRequest>()
        val completedQuotes = mutableListOf<List<String>>()
        var quotes = listOf("Cafe\u0301", "Café", "")
        var held: CompletableDeferred<Unit>? = null
        var failure: AssistantError? = null
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse = error("Missing deadline")
        override suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse {
            val responseQuotes = quotes.toList()
            calls.add(request)
            held?.let { withContext(NonCancellable) { it.await() } }
            failure?.let { throw it }
            val source = assertIs<AssistantAction.Review>(request.action).source
            val json = buildJsonObject {
                put("summary", "Review summary")
                put("findings", buildJsonArray {
                    for ((index, quote) in responseQuotes.withIndex()) add(buildJsonObject {
                        put("criterion", LlmRubricCriterion.entries[index % LlmRubricCriterion.entries.size].rawValue)
                        put("severity", LlmReviewSeverity.entries[index % LlmReviewSeverity.entries.size].rawValue)
                        put("quote", quote); put("problem", "Problem $index"); put("suggestion", "Suggestion $index")
                    })
                })
            }
            val review = LlmOutputDecoder.review(json.toString(), source)
            completedQuotes.add(review.findings.map { it.quote })
            return AssistantResponse(AssistantOutput.Review(review), AssistantTokenUsage(12, 8))
        }
        override suspend fun listModels(connection: ProviderConnection): AssistantModelPage = error("Unexpected listing")
        override suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage =
            error("Unexpected listing")
    }

    private inner class Harness(private val test: TestScope, val kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE) {
        val root = temporary.resolve("review-${sequence++}")
        val promptRoot = root.resolve("library")
        val recordsRoot = root.resolve("state")
        val prompts = AndroidPromptStore(promptRoot.toFile())
        val records = AndroidStateStore(recordsRoot.toFile())
        val io = Worker(dispatcher)
        val clock = Clock { Instant.parse("2026-10-14T00:00:00Z") }
        val monotonic = MonotonicClock { test.testScheduler.currentTime * 1_000_000 }
        var access = AssistantAccessState.PRIVATE_PROMPT
        val authority = AssistantAccess { access }
        val library = LibraryService(prompts, records, clock, Entropy { ByteArray(it) { 1 } }, authority)
        val repository = LibraryRepository(library, EditingService(library), prompts, dispatcher)
        val editor = EditorViewModel(repository, dispatcher, clock, applicationScope).also { models.put("editor-$sequence", it) }
        val changes = AssistantProviderChanges()
        val anthropic = Client()
        val openAI = Client()
        val client get() = if (kind == ProviderKind.ANTHROPIC) anthropic else openAI
        lateinit var providers: ProviderSettingsService
        lateinit var graph: AssistantGraph
        lateinit var model: ReviewViewModel
        var graphFailure = false
        var loads = 0
        private lateinit var baseline: Map<String, List<Byte>>

        suspend fun configure(source: ByteArray? = "😀 e\u0301\r\nCafe\u0301 {{bad name}} {{topic}}".encodeToByteArray(), configured: Boolean = true) {
            prompts.prepareRoot()
            if (source != null) {
                put(promptRoot.resolve("original.md"), source)
                editor.open(LibrarySelection(PromptIdentity.at("original.md"), "original.md"))
            }
            val secrets = object : SecretStore {
                override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? = null
                override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier = error("No key")
                override suspend fun delete(account: SecretAccount) = Unit
            }
            val settings = MutableStateFlow(AndroidSettings())
            val store = object : DataStore<AndroidSettings> {
                override val data = settings
                override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings =
                    transform(settings.value).also { settings.value = it }
            }
            providers = ProviderSettingsService(ProviderSettingsStore(AndroidStateStore(root.resolve("provider").toFile(),
                settings = AndroidSettingsStore(store), isMainThread = { false })), secrets, dispatcher)
            if (configured) providers.save(ProviderDraft(kind = kind, baseURL = "https://review.example/v1", modelID = "review-model"))
            val service = AssistantService(providers, anthropic, openAI, io, clock, Entropy { error("Review creates no identity") }, monotonic, dispatcher)
            graph = AssistantGraph(service, authority, monotonic)
            model = ReviewViewModel(Lazy {
                assertTrue(io.executing, "Graph resolves on the worker")
                loads++
                if (graphFailure) throw ProviderSettingsError.ReadFailed
                graph
            }, io, changes).also { models.put("review-$sequence", it); it.bind(editor) }
            test.runCurrent()
            baseline = files()
        }

        fun open() { model.open(); test.runCurrent() }
        fun review() {
            open()
            assertTrue(model.state.value.canReview)
            model.review()
            test.runCurrent()
        }
        fun unchanged() {
            assertEquals(baseline, files(), "Review must not write prompt, history, provenance or provider state")
            assertNull(model.state.value.assistant?.artifact)
            assertNull(model.state.value.assistant?.candidate)
            assertNull(model.state.value.assistant?.diff)
            assertNull(model.state.value.assistant?.acceptanceOutcome)
            assertNull(editor.state.value.assistantAcceptanceOutcome)
            assertFalse(Files.exists(recordsRoot.resolve("history")))
        }
        fun files(): Map<String, List<Byte>> = Files.walk(root).use { paths ->
            paths.filter { Files.isRegularFile(it) }.toList().associate { root.relativize(it).toString() to Files.readAllBytes(it).toList() }
        }
    }

    @Test fun `both clients review raw unsaved templates with local placeholder checks and no publication`() = runTest {
        for (kind in ProviderKind.entries) {
            val h = Harness(this, kind)
            h.configure()
            h.open()
            assertTrue(h.client.calls.isEmpty())
            assertEquals("review.example", h.model.state.value.assistant?.providerHost)
            assertEquals("review-model", h.model.state.value.assistant?.modelID)
            h.editor.edit("Unsaved 😀 Cafe\u0301 {{bad name}} {{clipboard}} {{topic}}")
            runCurrent()
            h.model.setEffort(AssistantEffort.HIGH)
            h.review()
            val result = assertNotNull(h.model.state.value.assistant)
            assertEquals(AssistantPhase.DRAFT, result.phase)
            assertEquals(h.editor.state.value.source, assertIs<AssistantAction.Review>(h.client.calls.single().action).source)
            assertEquals(AssistantEffort.HIGH, h.client.calls.single().effort)
            assertEquals(AssistantTokenUsage(12, 8), result.usage)
            assertTrue(h.model.state.value.localIssues.any { it.code == PromptIssueCode.INVALID_PLACEHOLDER })
            assertTrue(h.model.state.value.canSelectFindings)
            assertTrue(h.model.state.value.localIssues.isNotEmpty())
            h.unchanged()
        }
    }

    @Test fun `all rubric and severity values have distinct native labels and survive the review snapshot`() = runTest {
        val h = Harness(this)
        h.configure()
        h.client.quotes = LlmRubricCriterion.entries.map { "Cafe\u0301" }
        h.review()
        val findings = h.model.state.value.assistant!!.review!!.findings
        assertEquals(LlmRubricCriterion.entries, findings.map { it.criterion })
        assertEquals(LlmReviewSeverity.entries.toSet(), findings.map { it.severity }.toSet())
        assertEquals(LlmRubricCriterion.entries.size, LlmRubricCriterion.entries.map(::reviewCriterionResource).toSet().size)
        assertEquals(LlmReviewSeverity.entries.size, LlmReviewSeverity.entries.map(::reviewSeverityResource).toSet().size)
        for (index in findings.indices) h.model.toggleFinding(index)
        h.model.toggleFinding(-1); h.model.toggleFinding(findings.size)
        assertEquals(findings.indices.toSet(), h.model.state.value.assistant?.selectedFindings)
        h.model.toggleFinding(0)
        assertFalse(0 in h.model.state.value.assistant!!.selectedFindings)
        h.unchanged()
    }

    @Test fun `exact first quote after emoji combining text and CRLF converts byte offsets to UTF16 editor selection`() = runTest {
        val h = Harness(this)
        val source = "😀 e\u0301\r\nCafe\u0301 🙂\r\nCafe\u0301"
        h.configure(source.encodeToByteArray())
        h.review()
        val finding = h.model.state.value.assistant!!.review!!.findings.first()
        val match = assertIs<LlmReview.QuoteMatch.Matched>(finding.quoteMatch)
        val start = source.indexOf(finding.quote)
        assertEquals(source.substring(0, start).encodeToByteArray().size, match.startByte)
        assertTrue(match.startByte > start)
        h.model.toggleFinding(0)
        h.editor.setTab(EditorTab.PREVIEW)
        h.model.showQuote(0)
        assertEquals(ReviewDestination.EDITOR, h.model.state.value.destination)
        assertEquals(EditorTab.EDIT, h.editor.state.value.tab)
        assertEquals(ReviewQuoteSelection(start, start + finding.quote.length), h.editor.state.value.quoteSelection)
        assertEquals(finding.quote, source.substring(h.editor.state.value.quoteSelection!!.start, h.editor.state.value.quoteSelection!!.endExclusive))
        h.model.open()
        assertEquals(ReviewDestination.FINDINGS, h.model.state.value.destination)
        assertEquals(setOf(0), h.model.state.value.assistant?.selectedFindings)
        assertEquals(1, h.client.calls.size)
        h.unchanged()
    }

    @Test fun `empty or unmatched quotes remain selectable but never highlight and empty findings succeed`() = runTest {
        val h = Harness(this)
        h.configure()
        h.review()
        for (index in 1..2) {
            assertIs<LlmReview.QuoteMatch.Unmatched>(h.model.state.value.assistant!!.review!!.findings[index].quoteMatch)
            h.model.toggleFinding(index)
            h.model.showQuote(index)
            assertNull(h.editor.state.value.quoteSelection)
            assertEquals(ReviewDestination.FINDINGS, h.model.state.value.destination)
        }
        assertEquals(setOf(1, 2), h.model.state.value.assistant?.selectedFindings)
        h.client.quotes = emptyList()
        h.model.review(); runCurrent()
        assertEquals(2, h.client.calls.size)
        assertTrue(h.model.state.value.assistant!!.review!!.findings.isEmpty())
        assertTrue(h.model.state.value.assistant!!.selectedFindings.isEmpty())
        assertEquals(AssistantPhase.DRAFT, h.model.state.value.assistant?.phase)
        h.unchanged()
    }

    @Test fun `buffer changes clear highlights and selections synchronously and returning to identical text cannot revive them`() = runTest {
        val h = Harness(this)
        h.configure()
        h.review()
        h.model.toggleFinding(0); h.model.showQuote(0)
        val original = h.editor.state.value.source!!
        val snapshot = h.editor.assistantSnapshot!!
        val finding = h.model.state.value.assistant!!.review!!.findings[0]
        h.editor.edit("Away")
        assertNull(h.editor.state.value.quoteSelection)
        assertTrue(h.model.state.value.assistant!!.selectedFindings.isEmpty())
        h.editor.edit(original)
        runCurrent()
        h.model.open(); h.model.toggleFinding(0); h.model.showQuote(0)
        assertTrue(h.model.state.value.assistant!!.isStale)
        assertFalse(h.model.state.value.canSelectFindings)
        assertEquals(ReviewDestination.FINDINGS, h.model.state.value.destination)
        assertNull(h.editor.state.value.quoteSelection)
        assertFalse(h.editor.highlightReviewQuote(snapshot, finding.quote, finding.quoteMatch as LlmReview.QuoteMatch.Matched))
        h.unchanged()
    }

    @Test fun `private invalid future unreadable absent provider and unavailable access disable Review before sending`() = runTest {
        val fixtures = listOf(
            "---\nprivate: true\n---\nPrivate".encodeToByteArray() to ReviewUnavailable.PRIVATE,
            "Unclosed {{topic".encodeToByteArray() to ReviewUnavailable.INVALID,
            "---\nformat: 2\n---\nFuture".encodeToByteArray() to ReviewUnavailable.READ_ONLY,
            byteArrayOf(0xff.toByte()) to ReviewUnavailable.READ_ONLY,
            null to ReviewUnavailable.SOURCE,
        )
        for ((source, reason) in fixtures) {
            val h = Harness(this)
            h.configure(source); h.open()
            assertEquals(reason, h.model.state.value.unavailable)
            assertFalse(h.model.state.value.canReview)
            h.model.review(); h.model.retryWithFeedback(); runCurrent()
            assertTrue(h.client.calls.isEmpty())
            h.unchanged()
        }
        val missing = Harness(this)
        missing.configure(configured = false); missing.open()
        assertEquals(ReviewUnavailable.PROVIDER, missing.model.state.value.unavailable)
        missing.model.review(); runCurrent()
        assertTrue(missing.client.calls.isEmpty())
        val access = Harness(this)
        access.configure(); access.access = AssistantAccessState.UNAVAILABLE; access.open()
        assertEquals(ReviewUnavailable.ACCESS, access.model.state.value.unavailable)
        access.model.review(); runCurrent()
        assertTrue(access.client.calls.isEmpty())
    }

    @Test fun `validation changes update privacy gating without a new buffer notification and dirty guards block requests`() = runTest {
        val h = Harness(this)
        h.configure(); h.open()
        h.editor.edit("---\nprivate: true\n---\nSecret")
        h.model.review()
        assertEquals(ReviewUnavailable.VALIDATING, h.model.state.value.unavailable)
        runCurrent()
        assertEquals(ReviewUnavailable.PRIVATE, h.model.state.value.unavailable)
        h.editor.edit("Public {{topic}}")
        runCurrent()
        assertTrue(h.model.state.value.canReview)
        h.editor.reload()
        assertNotNull(h.editor.state.value.pendingDecision)
        assertEquals(ReviewUnavailable.BUSY, h.model.state.value.unavailable)
        h.model.review(); runCurrent()
        assertTrue(h.client.calls.isEmpty())
        h.unchanged()
    }

    @Test fun `cursor interaction clears a quote without invalidating findings or revalidating unchanged source`() = runTest {
        val h = Harness(this)
        h.configure(); h.review()
        h.model.toggleFinding(0); h.model.showQuote(0)
        val snapshot = assertNotNull(h.editor.assistantSnapshot)
        val review = assertNotNull(h.model.state.value.assistant?.review)
        assertNotNull(h.editor.state.value.quoteSelection)
        h.editor.clearReviewQuote()
        h.editor.edit(assertNotNull(snapshot.source))
        assertEquals(snapshot, h.editor.assistantSnapshot)
        assertFalse(h.editor.state.value.validating)
        runCurrent()
        assertNull(h.editor.state.value.quoteSelection)
        assertSame(review, h.model.state.value.assistant?.review)
        assertFalse(h.model.state.value.assistant!!.isStale)
        assertEquals(setOf(0), h.model.state.value.assistant?.selectedFindings)
        assertEquals(1, h.client.calls.size)
        h.unchanged()
    }

    @Test fun `provider failures keep feedback and explicit retry clears failure while working without persistence`() = runTest {
        for (kind in ProviderKind.entries) for (error in listOf(AssistantError.Authentication,
            AssistantError.Transport(HttpTransportError.NetworkFailure))) {
            val h = Harness(this, kind)
            h.configure(); h.open()
            h.model.editFeedback("Check the same template")
            h.client.failure = error
            h.model.review(); runCurrent()
            val failed = assertNotNull(h.model.state.value.assistant)
            assertEquals(AssistantPhase.FAILED, failed.phase)
            assertEquals(AssistantFailure.Assistant(error), failed.failure)
            assertEquals(1, failed.transcript.size)
            assertTrue(h.model.state.value.canRetry)
            assertEquals("Check the same template", h.model.state.value.feedback)
            advanceTimeBy(2000); runCurrent()
            assertEquals(1, h.client.calls.size)
            assertEquals(failed.elapsedSeconds, h.model.state.value.assistant!!.elapsedSeconds)
            h.unchanged()

            h.client.failure = null
            val reply = CompletableDeferred<Unit>().also { h.client.held = it }
            h.model.retryWithFeedback(); runCurrent()
            val working = assertNotNull(h.model.state.value.assistant)
            assertEquals(AssistantPhase.WORKING, working.phase)
            assertNull(working.failure)
            assertFalse(working.isStale)
            assertEquals("Check the same template", h.model.state.value.feedback)
            assertEquals(2, h.client.calls.size)
            val request = h.client.calls.last()
            assertEquals("Check the same template", request.feedback)
            assertEquals(failed.transcript, request.transcript)
            assertEquals(h.editor.state.value.source, assertIs<AssistantAction.Review>(request.action).source)
            reply.complete(Unit); runCurrent()
            assertEquals(AssistantPhase.DRAFT, h.model.state.value.assistant!!.phase)
            assertNotNull(h.model.state.value.assistant?.review)
            assertNull(h.model.state.value.assistant?.failure)
            h.unchanged()
        }
    }

    @Test fun `Cancel Back teardown and new request generations suppress noncooperative late replies`() = runTest {
        for (departure in 0..3) {
            val h = Harness(this)
            h.configure()
            val reply = CompletableDeferred<Unit>().also { h.client.held = it }
            val originalQuotes = h.client.quotes
            h.review()
            advanceTimeBy(2100); runCurrent()
            assertTrue(h.model.state.value.assistant!!.elapsedSeconds >= 2)
            when (departure) {
                0 -> h.model.cancel()
                1 -> h.model.close()
                2 -> models.clear()
                else -> { h.model.cancel(); h.client.held = null; h.client.quotes = emptyList(); h.model.review() }
            }
            runCurrent()
            reply.complete(Unit); runCurrent()
            assertEquals(originalQuotes, h.client.completedQuotes.last(), "The late reply must keep its original findings")
            assertTrue(h.model.state.value.assistant?.review?.findings.isNullOrEmpty())
            assertTrue(h.model.state.value.assistant?.selectedFindings.isNullOrEmpty())
            if (departure == 0 || departure == 3) {
                val retained = assertNotNull(h.model.state.value.assistant)
                assertEquals(if (departure == 0) AssistantPhase.IDLE else AssistantPhase.DRAFT, retained.phase)
                assertEquals(0.0, retained.elapsedSeconds)
                assertEquals(if (departure == 0) 1 else 2, h.client.calls.size)
            } else assertNull(h.model.state.value.assistant)
            val settled = h.model.state.value
            advanceTimeBy(2000); runCurrent()
            assertEquals(settled, h.model.state.value)
            if (departure == 1 || departure == 2) assertFalse(h.model.state.value.isOpen)
            h.unchanged()
        }
    }

    @Test fun `inflight buffer change produces stale findings and explicit feedback uses fresh raw snapshot`() = runTest {
        val h = Harness(this)
        h.configure()
        val reply = CompletableDeferred<Unit>().also { h.client.held = it }
        h.review()
        h.editor.edit("Fresh 😀 Cafe\u0301 {{topic}}")
        reply.complete(Unit); runCurrent()
        assertTrue(h.model.state.value.assistant!!.isStale)
        h.model.showQuote(0); h.model.toggleFinding(0)
        assertNull(h.editor.state.value.quoteSelection)
        assertTrue(h.model.state.value.assistant!!.selectedFindings.isEmpty())
        h.model.editFeedback("Check fresh source")
        assertEquals(1, h.client.calls.size)
        h.model.retryWithFeedback(); runCurrent()
        val request = h.client.calls.last()
        assertEquals(h.editor.state.value.source, assertIs<AssistantAction.Review>(request.action).source)
        assertEquals("Check fresh source", request.feedback)
        assertEquals(2, request.transcript.size)
        assertFalse(h.model.state.value.assistant!!.isStale)
        h.model.showQuote(0)
        assertNotNull(h.editor.state.value.quoteSelection)
        h.unchanged()
    }

    @Test fun `rebind and recreated collection retain the in-memory review without resending`() = runTest {
        val h = Harness(this)
        h.configure()
        val reply = CompletableDeferred<Unit>().also { h.client.held = it }
        h.review()
        h.model.bind(h.editor); h.model.open()
        assertEquals(AssistantPhase.WORKING, h.model.state.first().assistant?.phase)
        assertEquals(1, h.client.calls.size)
        reply.complete(Unit); runCurrent()
        h.model.toggleFinding(1)
        val review = h.model.state.value.assistant?.review
        h.model.bind(h.editor); h.model.open()
        assertSame(review, h.model.state.first().assistant?.review)
        assertEquals(setOf(1), h.model.state.value.assistant?.selectedFindings)
        assertEquals(1, h.loads)
        assertEquals(1, h.client.calls.size)
        h.model.close(); h.open()
        assertNull(h.model.state.value.assistant?.review)
        assertTrue(h.model.state.value.assistant!!.selectedFindings.isEmpty())
        h.unchanged()
    }

    @Test fun `provider credential and editor session transitions retire findings including away and back`() = runTest {
        for (working in listOf(false, true)) for (transition in 0..2) {
            val h = Harness(this)
            h.configure()
            val reply = if (working) CompletableDeferred<Unit>().also { h.client.held = it } else null
            h.review()
            if (!working) { h.model.toggleFinding(0); h.model.showQuote(0) }
            when (transition) {
                0 -> h.changes.changed()
                1 -> {
                    val profile = h.graph.service.selectedProfile!!.id
                    h.providers.selectProfile(null); h.changes.changed()
                    h.providers.selectProfile(profile); h.changes.changed()
                }
                else -> h.editor.close()
            }
            reply?.complete(Unit); runCurrent()
            assertNull(h.model.state.value.assistant?.review)
            assertTrue(h.model.state.value.assistant?.selectedFindings.isNullOrEmpty())
            assertNull(h.editor.state.value.quoteSelection)
            h.unchanged()
        }
    }

    @Test fun `graph loading can retry and cancellation before worker execution cannot reopen route`() = runTest {
        val h = Harness(this)
        h.configure()
        h.graphFailure = true; h.open()
        assertTrue(h.model.state.value.loadFailed)
        h.graphFailure = false; h.model.reload(); runCurrent()
        assertTrue(h.model.state.value.canReview)
        h.model.close(); h.io.held = true
        h.model.open(); h.model.close(); h.io.releaseAll(); runCurrent()
        assertFalse(h.model.state.value.isOpen)
        assertTrue(h.client.calls.isEmpty())
        h.unchanged()
    }

    @Test fun `departing the editor from the quote route retires the review and its inputs`() = runTest {
        val h = Harness(this)
        h.configure(); h.review()
        h.model.editFeedback("Session only")
        h.model.toggleFinding(0); h.model.showQuote(0)
        assertEquals(ReviewDestination.EDITOR, h.model.state.value.destination)
        h.editor.close()
        assertFalse(h.model.state.value.isOpen)
        assertEquals("", h.model.state.value.feedback)
        assertNull(h.model.state.value.assistant)
        assertNull(h.editor.state.value.quoteSelection)
        h.unchanged()
    }

    @Test fun `findings and feedback are redacted and cleared when the review closes`() = runTest {
        val h = Harness(this)
        h.configure()
        val sentinel = "review-${UUID.randomUUID()}"
        h.client.quotes = listOf(sentinel)
        h.review()
        h.model.toggleFinding(0); h.model.editFeedback(sentinel)
        for (diagnostic in listOf(h.model.toString(), h.model.state.value.toString(), h.model.state.value.assistant.toString(),
            h.model.state.value.assistant?.review.toString(), h.model.state.value.assistant?.review?.findings.toString())) {
            assertFalse(diagnostic.contains(sentinel))
        }
        h.model.close()
        assertEquals("", h.model.state.value.feedback)
        assertNull(h.model.state.value.assistant)
        assertFalse(h.files().values.any { it.toByteArray().decodeToString().contains(sentinel) })
        h.unchanged()
    }
}
