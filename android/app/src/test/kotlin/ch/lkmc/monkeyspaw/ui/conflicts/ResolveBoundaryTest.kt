package ch.lkmc.monkeyspaw.ui.conflicts

import ch.lkmc.monkeyspaw.core.domain.sync.SyncResolutionFailure
import ch.lkmc.monkeyspaw.ui.assistant.displayDiffLine
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

internal class ResolveBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val root = sources.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test fun `comparison state has no persistence or raw diagnostic path`() {
        val forbidden = Regex("\\b(?:SavedStateHandle|rememberSaveable|Parcelable|Serializable|Bundle|Logger|Log|println|printStackTrace|DataStore)\\b")
        for (file in root.resolve("ui/conflicts").walkTopDown().filter { it.extension == "kt" }) {
            assertFalse(forbidden.containsMatchIn(file.readText()), file.name)
        }
        val screen = root.resolve("ui/conflicts/ResolveScreen.kt").readText()
        assertFalse(Regex("\\b(?:SyncResolutionService|AndroidSyncRepository|HttpTransport|viewModelScope|LaunchedEffect)\\b").containsMatchIn(screen))
        assertTrue(screen.contains("ImproveDiffView(diff"))
        val activity = root.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("onResolve = ::openResolve"))
        assertTrue(activity.contains("editor.closeThen"))
        assertTrue(activity.contains("resolver.requestClose"))
        assertTrue(activity.contains("override fun onDestroy()"))
        assertTrue(activity.contains("editor.cancelCloseThen()"))
        assertTrue(activity.contains("resolver.close()"))
    }

    @Test fun `renderer keeps both sides horizontally accessible and separates header from body`() {
        val renderer = root.resolve("ui/assistant/ImproveDiffView.kt").readText()
        assertTrue(renderer.contains("minimumDiffPaneWidth = 240.dp"))
        assertTrue(renderer.contains("horizontalScroll(rememberScrollState())"))
        assertTrue(renderer.contains("LazyColumn(Modifier.width(paneWidth * 2 + 1.dp).heightIn(max = 420.dp))"))
        assertTrue(renderer.contains("items(diff.frontMatter)"))
        assertTrue(renderer.contains("items(diff.body)"))
        assertTrue(renderer.contains("DiffSide.CURRENT"))
        assertTrue(renderer.contains("DiffSide.CANDIDATE"))
        assertTrue(renderer.contains("stringResource(currentLabel)"))
        assertTrue(renderer.contains("stringResource(candidateLabel)"))
        assertEquals("Café ␍↵", displayDiffLine("Café\r\n", "no newline"))
        assertEquals("Cafe\u0301 🐒 ↵", displayDiffLine("Cafe\u0301 🐒\n", "no newline"))
        assertEquals("last (no newline)", displayDiffLine("last", "no newline"))
    }

    @Test fun `resolution labels and changed-head warning make the choice explicit`() {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(sources.resolve("res/values/resolve_strings.xml"))
        val nodes = document.getElementsByTagName("string")
        val strings = (0 until nodes.length).associate {
            val element = nodes.item(it) as org.w3c.dom.Element
            element.getAttribute("name") to element.textContent
        }
        assertEquals("Server", strings["resolve_server_version"])
        assertEquals("My version", strings["resolve_my_version"])
        assertTrue(strings.getValue("resolve_refreshed").contains("choose again"))
        assertTrue(strings.getValue("resolve_leave_help").contains("may still complete"))
        assertTrue(strings.getValue("resolve_mine_help").contains("personal favourite and private keys"))
    }

    @Test fun `all service failures have fixed typed UI reasons`() {
        val failures = listOf(SyncResolutionFailure.Inactive, SyncResolutionFailure.Busy, SyncResolutionFailure.InvalidCopy,
            SyncResolutionFailure.StaleCopy, SyncResolutionFailure.StaleSession, SyncResolutionFailure.StaleAccess,
            SyncResolutionFailure.OriginalUnavailable, SyncResolutionFailure.AccessDenied, SyncResolutionFailure.InvalidCandidate,
            SyncResolutionFailure.NeedsSignIn, SyncResolutionFailure.Offline, SyncResolutionFailure.RecoveryRequired,
            SyncResolutionFailure.OperationFailed)
        assertEquals(ResolveFailure.entries.toSet(), failures.map(::resolutionFailure).toSet())
        assertTrue(failures.map(::resolutionFailure).all { it.message != 0 })
    }
}
