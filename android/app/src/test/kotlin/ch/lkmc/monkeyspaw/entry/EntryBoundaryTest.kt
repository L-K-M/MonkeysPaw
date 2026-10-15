package ch.lkmc.monkeyspaw.entry

import java.io.File
import org.w3c.dom.Element
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

/** XML and adapter checks complement executable policy/Fill tests; task and launcher execution needs a device. */
internal class EntryBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val root = sources.resolve("kotlin/ch/lkmc/monkeyspaw/entry")
    private val namespace = "http://schemas.android.com/apk/res/android"

    @Test
    fun `only launcher capture entries permission-protected tile and IME are exported`() {
        val manifest = xml("AndroidManifest.xml")
        val expected = mapOf(
            ".MainActivity" to "true", ".entry.FillActivity" to "false",
            ".entry.ProcessTextActivity" to "true",
            ".entry.ShareReceiverActivity" to "true",
            ".entry.PromptShortcutActivity" to "false", ".entry.PromptTileService" to "true",
            ".entry.PromptWidgetProvider" to "false",
            ".ime.MonkeysPawImeService" to "true",
        )
        val components = children(manifest, "activity") + children(manifest, "service") + children(manifest, "receiver")
        assertEquals(expected.keys, components.map { it.attr("name") }.toSet())
        for (component in components) assertEquals(expected.getValue(component.attr("name")), component.attr("exported"))
        for (tag in listOf("activity-alias", "provider")) assertTrue(children(manifest, tag).isEmpty())
        // Only the assistant/sync transport's INTERNET permission is requested; anything merged in is removed.
        for (permission in children(manifest, "uses-permission")) {
            if (permission.attr("name") == "android.permission.INTERNET") continue
            assertEquals("remove", permission.getAttributeNS("http://schemas.android.com/tools", "node"))
        }
        val tile = components.single { it.attr("name") == ".entry.PromptTileService" }
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", tile.attr("permission"))
        assertEquals(listOf("android.service.quicksettings.action.QS_TILE"), children(tile, "action").map { it.attr("name") })
        val widget = components.single { it.attr("name") == ".entry.PromptWidgetProvider" }
        assertEquals(listOf("android.appwidget.action.APPWIDGET_UPDATE"), children(widget, "action").map { it.attr("name") })
        assertEquals("@xml/prompt_widget_info", children(widget, "meta-data").single().attr("resource"))
    }

    @Test
    fun `fill is a private reusable task and shortcut reset flags affect only its empty-affinity trampoline`() {
        val activities = children(xml("AndroidManifest.xml"), "activity")
        val fill = activities.single { it.attr("name") == ".entry.FillActivity" }
        assertEquals("singleTask", fill.attr("launchMode"))
        assertEquals("ch.lkmc.monkeyspaw.fill", fill.attr("taskAffinity"))
        assertEquals("true", fill.attr("excludeFromRecents"))
        assertTrue(children(fill, "intent-filter").isEmpty())
        assertFalse(fill.hasAttributeNS(namespace, "noHistory"))
        val shortcut = activities.single { it.attr("name") == ".entry.PromptShortcutActivity" }
        assertTrue(shortcut.hasAttributeNS(namespace, "taskAffinity"))
        assertEquals("", shortcut.attr("taskAffinity"))
        assertEquals("true", shortcut.attr("noHistory"))
        assertEquals("true", shortcut.attr("excludeFromRecents"))
        assertEquals("@android:style/Theme.NoDisplay", shortcut.attr("theme"))
        assertTrue(children(shortcut, "intent-filter").isEmpty())
        for (activity in activities) {
            for (flag in listOf("showWhenLocked", "turnScreenOn", "directBootAware")) assertNotEquals("true", activity.attr(flag))
        }
    }

    @Test
    fun `static Insert prompt shortcut names its explicit trampoline and resources resolve`() {
        val main = children(xml("AndroidManifest.xml"), "activity").single { it.attr("name") == ".MainActivity" }
        val metadata = children(main, "meta-data").single { it.attr("name") == "android.app.shortcuts" }
        assertEquals("@xml/shortcuts", metadata.attr("resource"))
        val shortcut = children(xml("res/xml/shortcuts.xml"), "shortcut").single()
        assertEquals("insert_prompt", shortcut.attr("shortcutId"))
        assertEquals("true", shortcut.attr("enabled"))
        assertEquals("@drawable/ic_insert_prompt", shortcut.attr("icon"))
        val intent = children(shortcut, "intent").single()
        assertEquals(EntrySource.SHORTCUT.action, intent.attr("action"))
        assertEquals("ch.lkmc.monkeyspaw", intent.attr("targetPackage"))
        assertEquals("ch.lkmc.monkeyspaw.entry.PromptShortcutActivity", intent.attr("targetClass"))
        assertTrue(children(shortcut, "extra").isEmpty())
        val strings = children(xml("res/values/strings.xml"), "string").associate { it.getAttribute("name") to it.textContent }
        assertEquals("Insert prompt", strings[shortcut.attr("shortcutShortLabel").removePrefix("@string/")])
        assertNotNull(strings[shortcut.attr("shortcutLongLabel").removePrefix("@string/")])
        assertEquals("vector", xml("res/drawable/ic_insert_prompt.xml").tagName)
    }

    @Test
    fun `widget exposes one accessible home-screen button with no periodic or locked content`() {
        val widget = xml("res/xml/prompt_widget_info.xml")
        assertEquals("appwidget-provider", widget.tagName)
        assertEquals("@layout/prompt_widget", widget.attr("initialLayout"))
        assertEquals(widget.attr("initialLayout"), widget.attr("previewLayout"))
        assertEquals("0", widget.attr("updatePeriodMillis"))
        assertEquals("home_screen", widget.attr("widgetCategory"))
        val button = children(xml("res/layout/prompt_widget.xml"), "Button").single()
        assertEquals("@+id/insert_prompt", button.attr("id"))
        assertEquals("@string/entry_insert_prompt", button.attr("text"))
        assertEquals("48dp", button.attr("minHeight"))
        assertEquals("@drawable/prompt_widget_background", button.attr("background"))
        assertEquals("ripple", xml("res/drawable/prompt_widget_background.xml").tagName)
    }

    @Test
    fun `adapters use guarded tile overloads and immutable explicit activity intents without clipboard work`() {
        val tile = root.resolve("PromptTileService.kt").readText()
        assertTrue(tile.contains("TileLaunchPolicy.click(isLocked, { unlockAndRun(it) }, ::openFill)"))
        assertTrue(tile.contains("if (TileLaunchPolicy.usesPendingIntent())"))
        assertTrue(tile.contains("startActivityAndCollapse(route.pendingIntent(this))"))
        assertTrue(tile.contains("startActivityAndCollapse(route.intent(this))"))
        val widget = root.resolve("PromptWidgetProvider.kt").readText()
        assertTrue(widget.contains("setOnClickPendingIntent(R.id.insert_prompt, FillRoute(EntrySource.WIDGET).pendingIntent(context))"))
        val shortcut = root.resolve("PromptShortcutActivity.kt").readText()
        assertTrue(shortcut.contains("startActivity(FillRoute(EntrySource.SHORTCUT).intent(this))"))
        assertTrue(shortcut.indexOf("startActivity(") < shortcut.indexOf("finish()"))
        assertFalse(Regex("\\b(?:getIntent|setIntent|putExtras|getStringExtra|setContent)\\b").containsMatchIn(shortcut))
        val route = root.resolve("FillRoute.kt").readText()
        assertTrue(route.contains("Intent(context, targetClass)"))
        assertTrue(route.contains(".setAction(source.action)"))
        assertTrue(route.contains(".setFlags(activityFlags)"))
        assertTrue(route.contains("context, source.requestCode, intent(context), pendingIntentFlags"))
        for (source in listOf(tile, widget, shortcut, route)) {
            assertFalse(Regex("\\b(?:Clipboard|ClipboardManager|FillService|LibraryRepository|Toast|IntentSender|FLAG_MUTABLE)\\b")
                .containsMatchIn(source))
        }
    }

    @Test
    fun `warm library requests use guarded activation and Copy or Back finishes without a target-app launch`() {
        val activity = root.resolve("FillActivity.kt").readText()
        assertTrue(activity.contains("val requestedPath = request.promptPath"))
        val repeated = activity.substringAfter("override fun onNewIntent(").substringBefore("override fun onCreate(")
        assertTrue(repeated.contains("super.onNewIntent(intent)"))
        assertTrue(repeated.contains("FillRoute.read(intent).promptPath?.let(fill::open)"))
        assertFalse(Regex("\\b(?:cancel|copy|finish)\\s*\\(").containsMatchIn(repeated))
        assertTrue(repeated.contains("setIntent(FillRoute(EntrySource.IME_HANDOFF, request.handoffToken).intent(this))"))
        assertTrue(activity.contains("BackHandler { fill.cancel() }"))
        assertTrue(activity.contains("if (it.shouldFinish) finish()"))
        assertFalse(Regex("\\b(?:startActivity|finishAndRemoveTask|setShowWhenLocked|requestDismissKeyguard)\\s*\\(")
            .containsMatchIn(activity))
    }

    private fun xml(path: String): Element = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(sources.resolve(path)).documentElement

    private fun children(element: Element, tag: String): List<Element> = element.getElementsByTagName(tag).let { nodes ->
        (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun Element.attr(name: String): String = getAttributeNS(namespace, name)
}
