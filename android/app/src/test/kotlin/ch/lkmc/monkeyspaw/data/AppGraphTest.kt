package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.services.EditingService
import ch.lkmc.monkeyspaw.core.services.LibraryService
import ch.lkmc.monkeyspaw.di.AppModule
import kotlinx.coroutines.CoroutineScope
import java.io.File
import javax.inject.Singleton
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

/** Android components cannot be constructed on the stub JVM; validate their shared graph's wiring. */
internal class AppGraphTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val androidNamespace = "http://schemas.android.com/apk/res/android"

    @Test
    fun `one singleton provider owns every mutable library service and DataStore`() {
        val methods = AppModule::class.java.declaredMethods
        for (type in listOf(LibraryService::class.java, EditingService::class.java, LibraryRepository::class.java,
            AndroidPromptStore::class.java, StateStore::class.java, AndroidSettingsStore::class.java, CoroutineScope::class.java)) {
            val provider = methods.single { it.returnType == type }
            assertNotNull(provider.getAnnotation(Singleton::class.java), "${type.simpleName} must be process-scoped")
        }
        val module = source("di/AppModule.kt")
        assertTrue(module.contains("@InstallIn(SingletonComponent::class)"))
        assertEquals(1, Regex("LibraryService\\(").findAll(module).count())
        assertEquals(1, Regex("DataStoreFactory.create\\(").findAll(module).count())
        assertFalse(module.contains("corruptionHandler"))
        assertTrue(source("MonkeysPawApplication.kt").contains("@HiltAndroidApp"))
        assertTrue(source("MainActivity.kt").contains("@AndroidEntryPoint"))
    }

    @Test
    fun `manifest disables backups and permits only local M8 entry components in one process`() {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(File(sources, "AndroidManifest.xml"))
        val application = document.getElementsByTagName("application").item(0) as org.w3c.dom.Element
        assertEquals("false", application.getAttributeNS(androidNamespace, "allowBackup"))
        assertEquals(".MonkeysPawApplication", application.getAttributeNS(androidNamespace, "name"))
        assertFalse(application.hasAttributeNS(androidNamespace, "fullBackupContent"))
        assertFalse(application.hasAttributeNS(androidNamespace, "dataExtractionRules"))
        val allowed = setOf(".MainActivity", ".entry.FillActivity", ".entry.PromptTileService", ".entry.PromptWidgetProvider")
        val elements = document.getElementsByTagName("*")
        for (index in 0 until elements.length) {
            val element = elements.item(index) as org.w3c.dom.Element
            assertFalse(element.hasAttributeNS(androidNamespace, "process"))
            if (element.tagName in setOf("activity", "service", "receiver", "provider")) {
                assertTrue(element.getAttributeNS(androidNamespace, "name") in allowed)
            }
            if (element.tagName in setOf("uses-permission", "permission")) {
                assertEquals("remove", element.getAttributeNS("http://schemas.android.com/tools", "node"))
            }
        }
    }

    private fun source(path: String) = File(sources, "kotlin/ch/lkmc/monkeyspaw/$path").readText()
}
