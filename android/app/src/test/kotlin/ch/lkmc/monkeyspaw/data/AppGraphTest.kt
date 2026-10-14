package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import ch.lkmc.monkeyspaw.core.services.EditingService
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.core.ports.Clock
import ch.lkmc.monkeyspaw.core.ports.Clipboard
import ch.lkmc.monkeyspaw.core.services.LibraryService
import ch.lkmc.monkeyspaw.di.AppModule
import kotlinx.coroutines.CoroutineScope
import java.io.File
import javax.inject.Singleton
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

/** Android components cannot be constructed on the stub JVM; validate their shared graph's wiring. */
internal class AppGraphTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")) {
        "monkeyspaw.appSources is injected by the Gradle test task; run via ./gradlew testDebugUnitTest"
    })
    private val androidNamespace = "http://schemas.android.com/apk/res/android"

    @Test
    fun `one singleton provider owns every mutable library service and DataStore`() {
        val methods = AppModule::class.java.declaredMethods
        for (type in listOf(LibraryService::class.java, EditingService::class.java, LibraryRepository::class.java,
            AndroidPromptStore::class.java, StateStore::class.java, AndroidSettingsStore::class.java, SecretStore::class.java,
            CoroutineScope::class.java, AndroidSeedCatalog::class.java, SeedInstaller::class.java, FillService::class.java,
            AndroidClock::class.java, Clock::class.java, Clipboard::class.java,
            HttpTransport::class.java, MonotonicClock::class.java)) {
            val provider = methods.single { it.returnType == type }
            assertNotNull(provider.getAnnotation(Singleton::class.java), "${type.simpleName} must be process-scoped")
        }
        val module = source("di/AppModule.kt")
        assertTrue(module.contains("@InstallIn(SingletonComponent::class)"))
        assertEquals(1, constructorCount(module, "LibraryService"))
        assertEquals(2, constructorCount(module, "DataStoreFactory.create"))
        assertEquals(1, constructorCount(module, "AndroidKeystoreSecretStore"))
        assertFalse(module.contains("corruptionHandler"))
        assertTrue(source("MonkeysPawApplication.kt").contains("@HiltAndroidApp"))
        assertTrue(source("MainActivity.kt").contains("@AndroidEntryPoint"))
    }

    @Test
    fun `graph roots are disjoint library state and settings trees`() {
        val module = source("di/AppModule.kt")
        assertTrue(module.contains("AndroidPromptStore(File(context.filesDir, \"library\"))"))
        assertTrue(module.contains("AndroidStateStore(File(context.filesDir, \"state\"), settings = settings)"))
        assertTrue(AppModule::class.java.declaredMethods.single { it.returnType == StateStore::class.java }
            .parameterTypes.contains(AndroidSettingsStore::class.java))
        assertTrue(module.contains("File(context.filesDir, \"datastore/settings.json\")"))
        assertTrue(module.contains("File(context.filesDir, \"datastore/secrets.json\")"))
    }

    @Test
    fun `graph source guard counts exact constructors rather than similarly named types`() {
        assertEquals(1, constructorCount("LibraryService( MemoLibraryService(", "LibraryService"))
        assertEquals(1, constructorCount("DataStoreFactory.create( OtherDataStoreFactory.create( DataStoreFactoryXcreate(",
            "DataStoreFactory.create"))
    }

    @Test
    fun `manifest disables backups and permits only local M8 entry components in one process`() {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(File(sources, "AndroidManifest.xml"))
        validateManifest(document)
    }

    @Test
    fun `network permission and config retain system trust with runtime cleartext policy`() {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(sources, "res/xml/network_security_config.xml"))
        assertEquals("true", (document.getElementsByTagName("base-config").item(0) as org.w3c.dom.Element)
            .getAttribute("cleartextTrafficPermitted"))
        val anchors = document.getElementsByTagName("certificates")
        assertEquals(1, anchors.length)
        assertEquals("system", (anchors.item(0) as org.w3c.dom.Element).getAttribute("src"))
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val manifest = factory.newDocumentBuilder().parse(File(sources, "AndroidManifest.xml"))
        val application = manifest.getElementsByTagName("application").item(0) as org.w3c.dom.Element
        assertEquals("@xml/network_security_config", application.getAttributeNS(androidNamespace, "networkSecurityConfig"))
        val permissions = manifest.getElementsByTagName("uses-permission")
        assertEquals(1, (0 until permissions.length).count {
            (permissions.item(it) as org.w3c.dom.Element).getAttributeNS(androidNamespace, "name") == "android.permission.INTERNET"
        })
    }

    @Test
    fun `manifest guard rejects an exported activity alias`() {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(File(sources, "AndroidManifest.xml"))
        val alias = document.createElement("activity-alias").apply {
            setAttributeNS(androidNamespace, "android:name", ".UnexpectedAlias")
            setAttributeNS(androidNamespace, "android:targetActivity", ".MainActivity")
            setAttributeNS(androidNamespace, "android:exported", "true")
        }
        document.getElementsByTagName("application").item(0).appendChild(alias)
        assertFailsWith<AssertionError> { validateManifest(document) }
    }

    private fun validateManifest(document: org.w3c.dom.Document) {
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
            if (element.tagName in setOf("activity", "activity-alias", "service", "receiver", "provider")) {
                assertTrue(element.getAttributeNS(androidNamespace, "name") in allowed)
            }
            if (element.tagName in setOf("uses-permission", "permission")) {
                if (element.getAttributeNS(androidNamespace, "name") != "android.permission.INTERNET") {
                    assertEquals("remove", element.getAttributeNS("http://schemas.android.com/tools", "node"))
                }
            }
        }
    }

    private fun constructorCount(source: String, name: String) = Regex("\\b${Regex.escape(name)}\\(").findAll(source).count()

    private fun source(path: String) = File(sources, "kotlin/ch/lkmc/monkeyspaw/$path").readText()
}
