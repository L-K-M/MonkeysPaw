package ch.lkmc.monkeyspaw.ui.assistant

import java.io.File
import kotlin.test.*

/** JVM policy checks supplement the runnable ViewModel flows; native rendering remains owner-run. */
internal class AssistantScreenBoundaryTest {
    private val root = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val sources = root.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test fun `draft decisions do not require all buttons to fit on one unscrollable line`() {
        val screen = sources.resolve("ui/assistant/WriteScreen.kt").readText()
        val decisions = screen.substringAfter("else if (state.assistant?.artifact != null) {")
            .substringBefore("if (state.canRetry)")
        for (intent in listOf("onShowDiff", "onAccept", "onReject")) assertTrue(decisions.contains(intent), intent)
        assertFalse(Regex("\\bRow\\(").containsMatchIn(decisions) && !decisions.contains("horizontalScroll("),
            "Draft decisions must remain reachable when their combined width exceeds the viewport")
    }

    @Test fun `Write has a complete route with explicit callbacks and no automatic request or saved content`() {
        val activity = sources.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("private val assistantWrite: WriteViewModel by viewModels()"))
        assertTrue(activity.contains("assistantWrite.bind(editor)"))
        assertTrue(activity.contains("onWrite = { assistantImprove.close(); assistantReview.close(); assistantWrite.open() }"))
        assertTrue(activity.contains("onBack = assistantWrite::close"))
        assertTrue(activity.contains("EditorDecisionDialogs(editing, editor::resolveDecision, editor::resolveConflict)"))
        val screens = listOf("WriteScreen.kt", "ArtifactControls.kt").map { sources.resolve("ui/assistant/$it").readText() }
        for (view in screens) {
            assertFalse(Regex("\\b(?:LocalContext|LaunchedEffect|DisposableEffect|ViewModel|AssistantService|AssistantClient|HttpTransport|LibraryRepository|Dispatchers)\\b").containsMatchIn(view))
            assertFalse(Regex("Text\\(\"").containsMatchIn(view))
        }
        val screen = screens.first()
        for (intent in listOf("onWrite", "onRetry", "onAccept", "onReject", "onCancel", "onShowDiff", "onEffort", "onBack")) {
            assertTrue(screen.contains(intent), intent)
        }
        assertTrue(screen.contains("enabled = state.canAccept"))
        assertTrue(screen.contains("BackHandler(onBack = onBack)"))
        val sessionSources = sources.resolve("ui/assistant").walkTopDown().filter { it.extension == "kt" }
            .joinToString("\n") { it.readText() }
        assertFalse(Regex("\\b(?:SavedStateHandle|Bundle|rememberSaveable|DataStore|Clipboard|FillService)\\b").containsMatchIn(sessionSources))
        val strings = root.resolve("res/values/assistant_strings.xml").readText()
        assertTrue(strings.contains("name=\"assistant_write_disclosure\""))
        assertTrue(strings.contains("session transcript and feedback"))
        assertTrue(strings.contains("Open templates, Fill previews and remembered values are never sent by Write"))
    }

    @Test fun `Review exposes only completed routes and reuses issues effort and footer without saved content`() {
        val activity = sources.resolve("MainActivity.kt").readText()
        val screen = sources.resolve("ui/assistant/ReviewScreen.kt").readText()
        assertTrue(activity.contains("private val assistantReview: ReviewViewModel by viewModels()"))
        assertTrue(activity.contains("assistantReview.bind(editor)"))
        assertTrue(activity.contains("reviewing.isOpen && reviewing.destination == ReviewDestination.FINDINGS"))
        assertTrue(activity.contains("onReview = assistantReview::open"))
        for (control in listOf("ArtifactIssues", "AssistantEffortControl", "AssistantFooter", "BackHandler(onBack = onBack)")) {
            assertTrue(screen.contains(control), control)
        }
        assertFalse(Regex("\\b(?:LocalContext|LaunchedEffect|DisposableEffect|ViewModel|AssistantService|AssistantClient|HttpTransport|LibraryRepository|Dispatchers)\\b").containsMatchIn(screen))
        assertFalse(Regex("Text\\(\"").containsMatchIn(screen))
        assertFalse(screen.contains("onAccept"))
        assertTrue(screen.contains("enabled = state.canImproveWithThese"))
        assertTrue(activity.contains("onImprove = { assistantReview.openImprove(assistantImprove) }"))
        val strings = root.resolve("res/values/assistant_strings.xml").readText()
        assertTrue(strings.contains("Review sends the current template front matter and body"))
        assertTrue(strings.contains("No findings."))
        assertTrue(strings.contains("Quote does not match"))
    }

    @Test fun `Improve exposes explicit actions and paired lazy diff panes without effects or persisted content`() {
        val activity = sources.resolve("MainActivity.kt").readText()
        val screen = sources.resolve("ui/assistant/ImproveScreen.kt").readText()
        val diff = sources.resolve("ui/assistant/ImproveDiffView.kt").readText()
        assertTrue(activity.contains("private val assistantImprove: ImproveViewModel by viewModels()"))
        assertTrue(activity.contains("assistantImprove.bind(editor)"))
        assertTrue(activity.contains("onBack = assistantImprove::close"))
        assertTrue(activity.contains("else assistantImprove.open()"))
        for (intent in listOf("onImprove", "onInstruction", "onRetry", "onShowDiff", "onAccept", "onReject", "onCancel", "onBack")) {
            assertTrue(screen.contains(intent), intent)
        }
        for (control in listOf("ArtifactDraft", "ArtifactFields", "ArtifactIssues", "ArtifactNotes", "ArtifactPreview", "ImproveDiffView")) {
            assertTrue(screen.contains(control), control)
        }
        for (view in listOf(screen, diff)) {
            assertFalse(Regex("\\b(?:LocalContext|LaunchedEffect|DisposableEffect|ViewModel|AssistantService|AssistantClient|HttpTransport|LibraryRepository|Dispatchers)\\b").containsMatchIn(view))
            assertFalse(Regex("Text\\(\"").containsMatchIn(view))
        }
        assertTrue(screen.contains("enabled = state.canAccept"))
        assertTrue(screen.contains("BackHandler(onBack = onBack)"))
        for (layout in listOf("horizontalScroll(rememberScrollState())", "minimumDiffPaneWidth = 240.dp", "maxWidth", "LazyColumn",
            "items(diff.frontMatter)", "items(diff.body)", "DiffSide.CURRENT", "DiffSide.CANDIDATE", "line.originalLine", "line.mergedLine",
            "line.placeholderWarnings", "IntrinsicSize.Min")) assertTrue(diff.contains(layout), layout)
        val strings = root.resolve("res/values/assistant_strings.xml").readText()
        assertTrue(strings.contains("Improve sends the current template front matter and body, your instruction and selected findings"))
        assertTrue(strings.contains("Selected findings are reused only while their source is unchanged"))
    }

    @Test fun `diff display preserves Unicode and shows exact LF CRLF and missing newline distinctions`() {
        assertEquals("😀 e\u0301 ↵", displayDiffLine("😀 e\u0301\n", "no newline"))
        assertEquals("😀 e\u0301 ␍↵", displayDiffLine("😀 e\u0301\r\n", "no newline"))
        assertEquals("😀 e\u0301 (no newline)", displayDiffLine("😀 e\u0301", "no newline"))
        assertEquals("\r (no newline)", displayDiffLine("\r", "no newline"))
    }
}
