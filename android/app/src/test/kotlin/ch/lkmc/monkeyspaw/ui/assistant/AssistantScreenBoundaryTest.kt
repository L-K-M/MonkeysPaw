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
        assertTrue(activity.contains("onWrite = assistantWrite::open"))
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
}
