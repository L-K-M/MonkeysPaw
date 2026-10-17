package ch.lkmc.monkeyspaw.entry

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import kotlin.test.*

/** Pins source contracts and both AGP merged manifests, including the release that ships. */
internal class EntryManifestTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val android = "http://schemas.android.com/apk/res/android"
    private val tools = "http://schemas.android.com/tools"

    @Test fun `merged startup metadata never eagerly initializes HTTP or its loggers for an IME launch`() {
        for (merged in mergedManifests()) assertFalse("okhttp3.internal.platform.PlatformInitializer" in startupInitializers(merged))
    }

    @Test fun `merged startup metadata never schedules background profile installation for an IME launch`() {
        for (merged in mergedManifests()) assertFalse("androidx.profileinstaller.ProfileInstallerInitializer" in startupInitializers(merged))
    }

    @Test fun `merged startup metadata leaves work initialization to authorized entry`() {
        for (merged in mergedManifests()) assertFalse("androidx.work.WorkManagerInitializer" in startupInitializers(merged))
    }

    @Test fun `merged manifest has the exact permissions components filters and safe startup allowlist`() {
        mergedManifests().forEach(::validateMergedManifest)
    }

    @Test fun `merged manifest contract rejects duplicate components`() {
        for (merged in mergedManifests()) {
            val application = merged.children("application").single()
            application.appendChild(application.children("activity").first().cloneNode(true))
            assertFailsWith<AssertionError> { validateMergedManifest(merged) }
        }
    }

    @Test fun `merged manifest contract rejects missing or weaker profile receiver protection`() {
        for (permission in listOf("", "android.permission.INTERNET")) {
            for (merged in mergedManifests()) {
                val receiver = merged.children("application").single().children("receiver")
                    .single { it.attr("name") == "androidx.profileinstaller.ProfileInstallReceiver" }
                receiver.setAttributeNS(android, "android:permission", permission)
                assertFailsWith<AssertionError> { validateMergedManifest(merged) }
            }
        }
    }

    private fun validateMergedManifest(merged: Element) {
        assertEquals(listOf("INTERNET", "WAKE_LOCK", "ACCESS_NETWORK_STATE", "RECEIVE_BOOT_COMPLETED", "FOREGROUND_SERVICE")
            .map { "android.permission.$it" }.sorted(), merged.children("uses-permission").map { it.attr("name") }.sorted())
        for (tag in listOf("permission", "uses-permission-sdk-23", "uses-permission-sdk-m")) assertTrue(merged.children(tag).isEmpty())
        val application = merged.children("application").single()
        assertEquals("false", application.attr("allowBackup"))
        val tags = setOf("activity", "activity-alias", "service", "receiver", "provider")
        val source = xml("AndroidManifest.xml").children("application").single().children().filter { it.tagName in tags }
        val components = application.children().filter { it.tagName in tags }
        val actual = components.associateBy { it.attr("name") }
        fun qualified(name: String) = if (name.startsWith('.')) "ch.lkmc.monkeyspaw$name" else name
        val profileReceiver = "androidx.profileinstaller.ProfileInstallReceiver"
        val workComponents = mapOf(
            "androidx.work.impl.background.systemjob.SystemJobService" to Component("service", true, "android.permission.BIND_JOB_SERVICE"),
            "androidx.work.impl.foreground.SystemForegroundService" to Component("service", false),
            "androidx.work.impl.utils.ForceStopRunnable\$BroadcastReceiver" to Component("receiver", false),
            "androidx.work.impl.background.systemalarm.RescheduleReceiver" to Component("receiver", false),
            "androidx.work.impl.diagnostics.DiagnosticsReceiver" to Component("receiver", true, "android.permission.DUMP"),
            "androidx.room.MultiInstanceInvalidationService" to Component("service", false),
        )
        assertEquals((source.map { qualified(it.attr("name")) } + profileReceiver + workComponents.keys).sorted(),
            components.map { it.attr("name") }.sorted())
        for ((name, expected) in workComponents) {
            val component = actual.getValue(name)
            assertEquals(expected.tag, component.tagName)
            assertEquals(expected.exported.toString(), component.attr("exported"))
            assertEquals(expected.permission, component.attr("permission"))
        }
        for (component in source) {
            val counterpart = actual.getValue(qualified(component.attr("name")))
            assertEquals(component.tagName, counterpart.tagName)
            assertEquals(component.attr("exported"), counterpart.attr("exported"))
            assertEquals(component.attr("permission"), counterpart.attr("permission"))
            assertEquals(filters(component), filters(counterpart))
        }
        val framework = actual.getValue(profileReceiver)
        assertEquals("true", framework.attr("exported"))
        assertEquals("android.permission.DUMP", framework.attr("permission"))
        assertEquals(listOf("INSTALL_PROFILE", "SKIP_FILE", "SAVE_PROFILE", "BENCHMARK_OPERATION").map {
            listOf("action" to mapOf("android:name" to "androidx.profileinstaller.action.$it"))
        }, filters(framework))
        val startup = actual.getValue("androidx.startup.InitializationProvider")
        assertEquals("ch.lkmc.monkeyspaw.androidx-startup", startup.attr("authorities"))
        assertEquals(setOf("androidx.emoji2.text.EmojiCompatInitializer", "androidx.lifecycle.ProcessLifecycleInitializer"),
            startupInitializers(merged))
        for (element in actual.values + application) assertFalse(element.hasAttributeNS(android, "process"))
    }

    @Test fun `only INTERNET is requested and removed library permissions cannot become active`() {
        val manifest = xml("AndroidManifest.xml")
        val permissions = manifest.children("uses-permission")
        // M10/M11 already require INTERNET in the app. IME reachability is checked by ImeBoundaryTest.
        assertEquals(listOf("android.permission.INTERNET"), permissions.filterNot(::removed).map { it.attr("name") })
        assertTrue(manifest.children("uses-permission-sdk-23").isEmpty())
        assertTrue(manifest.children("uses-permission-sdk-m").isEmpty())
        assertTrue(manifest.children("permission").all(::removed))
        val omitted = permissions.filter(::removed).single()
        assertEquals("\${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION", omitted.attr("name"))
        val application = manifest.children("application").single()
        assertEquals(".MonkeysPawApplication", application.attr("name"))
        assertEquals("false", application.attr("allowBackup"))
        assertFalse(application.hasAttributeNS(android, "backupAgent"))
        assertFalse(application.hasAttributeNS(android, "fullBackupContent"))
        assertFalse(application.hasAttributeNS(android, "dataExtractionRules"))
        assertFalse(application.hasAttributeNS(android, "process"))
    }

    @Test fun `all entry components have exact export binding and intent filter contracts`() {
        val application = xml("AndroidManifest.xml").children("application").single()
        val expected = mapOf(
            "androidx.startup.InitializationProvider" to Component("provider", false),
            ".MainActivity" to Component("activity", true, action = "android.intent.action.MAIN",
                category = "android.intent.category.LAUNCHER"),
            ".entry.FillActivity" to Component("activity", false),
            ".entry.PromptShortcutActivity" to Component("activity", false),
            ".entry.ProcessTextActivity" to Component("activity", true, action = "android.intent.action.PROCESS_TEXT",
                category = "android.intent.category.DEFAULT", mime = "text/plain"),
            ".entry.ShareReceiverActivity" to Component("activity", true, action = "android.intent.action.SEND",
                category = "android.intent.category.DEFAULT", mime = "text/plain"),
            ".ime.MonkeysPawImeService" to Component("service", true, "android.permission.BIND_INPUT_METHOD",
                "android.view.InputMethod"),
            ".entry.PromptTileService" to Component("service", true, "android.permission.BIND_QUICK_SETTINGS_TILE",
                "android.service.quicksettings.action.QS_TILE"),
            ".entry.PromptWidgetProvider" to Component("receiver", false, action = "android.appwidget.action.APPWIDGET_UPDATE"),
        )
        val components = application.children().filter { it.tagName in setOf("activity", "service", "receiver", "provider", "activity-alias") }
        assertEquals(expected.keys.sorted(), components.map { it.attr("name") }.sorted())
        for (component in components) {
            val contract = expected.getValue(component.attr("name"))
            assertEquals(contract.tag, component.tagName)
            assertEquals(contract.exported.toString(), component.attr("exported"))
            assertEquals(contract.permission, component.attr("permission"))
            for (attribute in listOf("process", "directBootAware", "isolatedProcess", "showWhenLocked", "turnScreenOn")) {
                assertFalse(component.hasAttributeNS(android, attribute), "Unexpected $attribute")
            }
            val filters = component.children("intent-filter")
            if (contract.action == null) {
                assertTrue(filters.isEmpty())
                continue
            }
            val filter = filters.single()
            assertEquals(listOf(contract.action), filter.children("action").map { it.attr("name") })
            assertEquals(listOfNotNull(contract.category), filter.children("category").map { it.attr("name") })
            val data = filter.children("data")
            if (contract.mime == null) assertTrue(data.isEmpty())
            else {
                assertEquals(contract.mime, data.single().attr("mimeType"))
                assertEquals(1, data.single().attributes.length) // No URI, scheme, host or path entry.
            }
            assertEquals(1 + (if (contract.category == null) 0 else 1) + data.size, filter.children().size)
        }
    }

    @Test fun `IME metadata and quick entry resources resolve without adding another endpoint`() {
        val components = xml("AndroidManifest.xml").children("application").single().children()
        val ime = components.single { it.attr("name") == ".ime.MonkeysPawImeService" }
        val metadata = ime.children("meta-data").single()
        assertEquals("android.view.im", metadata.attr("name"))
        assertEquals("@xml/method", metadata.attr("resource"))
        val method = xml("res/xml/method.xml")
        assertEquals("input-method", method.tagName)
        assertEquals("true", method.attr("supportsSwitchingToNextInputMethod"))
        assertEquals(2, method.attributes.length) // Namespace declaration and switching flag only.
        assertTrue(method.children().isEmpty())
        val strings = sources.resolve("res/values").listFiles { file -> file.extension == "xml" }!!
            .flatMap { file -> parse(file).children("string") }.associate { it.getAttribute("name") to it.textContent }
        for (component in components) {
            val label = component.attr("label")
            if (label.startsWith("@string/")) assertFalse(strings[label.removePrefix("@string/")].isNullOrBlank())
        }
        val main = components.single { it.attr("name") == ".MainActivity" }
        assertEquals("@xml/shortcuts", main.children("meta-data").single().attr("resource"))
        val shortcut = xml("res/xml/shortcuts.xml").children("shortcut").single()
        val intent = shortcut.children("intent").single()
        assertEquals(EntrySource.SHORTCUT.action, intent.attr("action"))
        assertEquals("ch.lkmc.monkeyspaw", intent.attr("targetPackage"))
        assertEquals("ch.lkmc.monkeyspaw.entry.PromptShortcutActivity", intent.attr("targetClass"))
        assertTrue(shortcut.children("extra").isEmpty())
        val widget = components.single { it.attr("name") == ".entry.PromptWidgetProvider" }
        assertEquals("@xml/prompt_widget_info", widget.children("meta-data").single().attr("resource"))
        val provider = xml("res/xml/prompt_widget_info.xml")
        assertEquals("0", provider.attr("updatePeriodMillis"))
        assertEquals("@layout/prompt_widget", provider.attr("initialLayout"))
        assertEquals("@string/entry_insert_prompt", xml("res/layout/prompt_widget.xml").children("Button").single().attr("text"))
    }

    private data class Component(val tag: String, val exported: Boolean, val permission: String = "",
        val action: String? = null, val category: String? = null, val mime: String? = null)

    private fun removed(element: Element) = element.getAttributeNS(tools, "node") == "remove"
    private fun mergedManifests() = listOf("debug", "release").map { variant ->
        parse(File(checkNotNull(System.getProperty("monkeyspaw.mergedManifest.$variant"))))
    }
    private fun startupInitializers(merged: Element): Set<String> = merged.children("application").single().children("provider")
        .single { it.attr("name") == "androidx.startup.InitializationProvider" }
        .children("meta-data").map { it.attr("name") }.toSet()
    private fun filters(component: Element) = component.children("intent-filter").map { filter ->
        filter.children().map { child -> child.tagName to (0 until child.attributes.length).associate {
            child.attributes.item(it).nodeName to child.attributes.item(it).nodeValue
        } }
    }
    private fun xml(path: String) = parse(sources.resolve(path))
    private fun parse(file: File) = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(file).documentElement
    private fun Element.children(tag: String? = null): List<Element> = (0 until childNodes.length)
        .mapNotNull { childNodes.item(it) as? Element }.filter { tag == null || it.tagName == tag }
    private fun Element.attr(name: String) = getAttributeNS(android, name)
}
