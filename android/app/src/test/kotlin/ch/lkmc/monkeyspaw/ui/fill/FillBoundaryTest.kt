package ch.lkmc.monkeyspaw.ui.fill

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

/** Device rendering/finish are owner proof; these checks enforce the compiled route's boundaries. */
internal class FillBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val root = sources.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test
    fun `library activation opens the registered private Fill entry and the entry owns Back and finish`() {
        val main = root.resolve("MainActivity.kt").readText()
        assertTrue(main.contains("onOpen = ::openFill"))
        assertTrue(main.contains("Intent(this, FillActivity::class.java)"))
        assertTrue(main.contains("fillLauncher.open(selection.relativePath)"))
        assertTrue(main.contains("fillLauncher.resumed()"))
        val library = root.resolve("ui/library/LibraryScreen.kt").readText()
        assertTrue(library.contains("onOpen(row.selection)"))
        val activity = root.resolve("entry/FillActivity.kt").readText()
        assertTrue(activity.contains("@AndroidEntryPoint"))
        assertTrue(activity.contains("LibraryScreen("))
        assertTrue(activity.contains("FillScreen("))
        assertTrue(activity.contains("BackHandler { fill.cancel() }"))
        assertTrue(activity.contains("if (it.shouldFinish) finish()"))
        assertTrue(activity.contains("fill.setForeground(true)"))
        assertTrue(activity.contains("fill.setForeground(false)"))
        assertFalse(Regex("\\b(?:Clipboard|ClipboardManager|Toast|File|Context|FillService)\\b").containsMatchIn(activity))
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val manifest = factory.newDocumentBuilder().parse(sources.resolve("AndroidManifest.xml"))
        val namespace = "http://schemas.android.com/apk/res/android"
        val activities = manifest.getElementsByTagName("activity")
        val fill = (0 until activities.length).map { activities.item(it) as org.w3c.dom.Element }
            .single { it.getAttributeNS(namespace, "name") == ".entry.FillActivity" }
        assertEquals("false", fill.getAttributeNS(namespace, "exported"))
        assertEquals(0, fill.getElementsByTagName("intent-filter").length)
    }

    @Test
    fun `ViewModel uses only Core copy and repository learning and screen has no work or drivers`() {
        val model = root.resolve("ui/fill/FillViewModel.kt").readText()
        assertFalse(Regex("\\b(?:ClipboardManager|AndroidClipboard|AndroidClock|Context|File|writeText|readText|Toast)\\b")
            .containsMatchIn(model))
        assertTrue(model.contains("fill.copy("))
        assertTrue(model.contains("repository.withLibrary"))
        val screen = root.resolve("ui/fill/FillScreen.kt").readText()
        assertFalse(Regex("\\b(?:LocalContext|Clipboard|FillService|viewModelScope|LaunchedEffect|Dispatchers|File)\\b")
            .containsMatchIn(screen))
        assertTrue(screen.contains("enabled = state.copyEnabled"))
        assertTrue(screen.contains("enabled = state.cancelEnabled"))
        assertTrue(screen.contains("onValue(field.field.name, it)"))
    }

    @Test
    fun `system clipboard writes sensitive plain text on Main without URI coercion or copy notifications`() {
        val driver = root.resolve("data/AndroidClipboard.kt").readText()
        assertTrue(driver.contains("Looper.myLooper() == Looper.getMainLooper()"))
        assertTrue(driver.contains("ClipData.newPlainText(AppIdentity.displayName, text)"))
        assertTrue(driver.contains("clip.description.extras = PersistableBundle()"))
        assertTrue(driver.contains("manager().setPrimaryClip(clip)"))
        assertTrue(driver.contains("clip.getItemAt(0).text?.toString()"))
        assertEquals(1, Regex("\\.primaryClip\\b").findAll(driver).count())
        assertFalse(Regex("\\b(?:coerceToText|Toast|addPrimaryClipChangedListener|contentResolver)\\b").containsMatchIn(driver))
        val module = root.resolve("di/AppModule.kt").readText()
        assertTrue(module.contains("FillService(library, clipboard, clock::zone)"))
    }
}
