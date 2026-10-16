package ch.lkmc.monkeyspaw.ui.library

import java.io.File
import kotlin.test.*

/** Rendering/lifecycle need a device; keep layer and completed-destination boundaries executable here. */
internal class LibraryScreenBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val packageRoot = sources.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test
    fun `composable screens only render state and invoke callbacks`() {
        val screens = packageRoot.resolve("ui").walkTopDown().filter { it.name.endsWith("Screen.kt") }.toList()
        assertTrue(screens.isNotEmpty())
        for (screen in screens) validateView(screen.readText())
    }

    @Test
    fun `view source guard rejects IO and direct services`() {
        for (statement in listOf("File(\"path\").readText()", "LocalContext.current", "library: LibraryService",
            "repository: LibraryRepository", "clipboard: Clipboard", "Dispatchers.IO", "LaunchedEffect(Unit) {}")) {
            assertFailsWith<AssertionError>(statement) { validateView("@Composable fun Screen() { $statement }") }
        }
    }

    @Test
    fun `library exposes completed controls and Ready routes to the browser with a foreground rescan`() {
        val screen = packageRoot.resolve("ui/library/LibraryScreen.kt").readText()
        val unfinished = Regex("\\b(?:Account|Groups?|Conflicts?)\\b", RegexOption.IGNORE_CASE)
        assertFalse(unfinished.containsMatchIn(screen))
        val activity = packageRoot.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("if (startup == SeedOfferUiState.Ready)"))
        assertTrue(activity.contains("LibraryScreen("))
        assertTrue(activity.contains("if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()"))
        val seeds = packageRoot.resolve("ui/locallibrary/SeedOfferScreen.kt").readText()
        assertTrue(seeds.contains("SeedOfferUiState.Ready -> Unit"))
        val resources = sources.resolve("res/values/strings.xml").readText()
        assertFalse(Regex("name=\"library_(?:account|group|conflict|fill|editor|copy)").containsMatchIn(resources))
    }

    @Test
    fun `assistant entries stay behind setup and seeds and are offered only in browser mode`() {
        val activity = packageRoot.resolve("MainActivity.kt").readText()
        val setup = activity.indexOf("if (setupState.loading")
        val settings = activity.indexOf("else if (setupState.settingsOpen)")
        val ready = activity.indexOf("else if (startup == SeedOfferUiState.Ready)")
        val assistant = activity.indexOf("if (assistant.isOpen)")
        assertTrue(setup >= 0 && settings > setup && ready > settings && assistant > ready)
        assertTrue(activity.contains("onSettings = setup::openSettings"))
        assertTrue(activity.contains("onAssistantSettings = assistantSettings::open"))
        val screen = packageRoot.resolve("ui/library/LibraryScreen.kt").readText()
        val browserControls = screen.substringAfter("if (mode == LibraryMode.BROWSER) {").substringBefore("\n            }")
        assertTrue(browserControls.contains("onWrite?.let"))
        assertTrue(browserControls.contains("onAssistantSettings?.let"))
        val ime = packageRoot.resolve("ime/ImeScreen.kt").readText()
        assertTrue(ime.contains("mode = LibraryMode.IME_PICKER"))
        assertFalse(ime.contains("onWrite"))
        assertFalse(ime.contains("onAssistantSettings"))
    }

    private fun validateView(source: String) {
        val imports = Regex("(?m)^import (.+)$").findAll(source).map { it.groupValues[1] }
        assertTrue(imports.all { it.startsWith("androidx.compose.") || it == "androidx.activity.compose.BackHandler" ||
            it == "ch.lkmc.monkeyspaw.R" || it in setOf("ch.lkmc.monkeyspaw.core.domain.format.FieldKind",
                "ch.lkmc.monkeyspaw.core.domain.format.PromptRenderError", "ch.lkmc.monkeyspaw.core.services.FillPreview",
                "ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance",
                "ch.lkmc.monkeyspaw.core.ports.DeliveryMode",
                "ch.lkmc.monkeyspaw.core.domain.llm.ConnectionTestResult", "ch.lkmc.monkeyspaw.core.domain.llm.ProviderKind",
                "ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort",
                "ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID", "ch.lkmc.monkeyspaw.core.domain.llm.ProviderSettingsError",
                "ch.lkmc.monkeyspaw.core.domain.llm.SecretStoreError") })
        val forbidden = Regex("\\b(?:File|Files|Path|Context|LocalContext|Clipboard|LibraryRepository|LibraryService|EditingService|SeedInstaller|DataStore|Dispatchers|viewModelScope|LaunchedEffect|HttpTransport|URL|InputStream|OutputStream)\\b")
        assertFalse(forbidden.containsMatchIn(source))
    }
}
