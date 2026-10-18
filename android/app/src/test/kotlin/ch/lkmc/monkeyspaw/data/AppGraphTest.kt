package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import ch.lkmc.monkeyspaw.core.services.EditingService
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.core.services.AssistantService
import ch.lkmc.monkeyspaw.core.services.AssistantAccess
import ch.lkmc.monkeyspaw.di.AssistantGraph
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
        val methods = AppModule::class.java.declaredMethods.filterNot { it.isSynthetic }
        for (type in listOf(LibraryService::class.java, EditingService::class.java, LibraryRepository::class.java,
            AndroidPromptStore::class.java, StateStore::class.java, AndroidSettingsStore::class.java, SecretStore::class.java,
            AndroidStateStore::class.java, AndroidSyncStartup::class.java, AndroidSyncRepository::class.java,
            SyncWorkScheduler::class.java, SyncWorkHooks::class.java,
            CoroutineScope::class.java, AndroidSeedCatalog::class.java, SeedInstaller::class.java, FillService::class.java,
            AndroidClock::class.java, Clock::class.java, Clipboard::class.java,
            HttpTransport::class.java, MonotonicClock::class.java, AssistantService::class.java,
            AssistantAccess::class.java, AssistantGraph::class.java)) {
            val provider = methods.single { it.returnType == type }
            assertNotNull(provider.getAnnotation(Singleton::class.java), "${type.simpleName} must be process-scoped")
        }
        val module = source("di/AppModule.kt")
        assertTrue(module.contains("@InstallIn(SingletonComponent::class)"))
        assertEquals(1, constructorCount(module, "LibraryService"))
        assertEquals(2, constructorCount(module, "DataStoreFactory.create"))
        assertEquals(1, constructorCount(module, "AndroidKeystoreSecretStore"))
        assertTrue(module.contains("OkHttpHttpTransport(clock, scope, syncTlsTrust = AndroidSyncTlsTrust())"))
        assertFalse(module.contains("corruptionHandler"))
        assertTrue(source("MonkeysPawApplication.kt").contains("@HiltAndroidApp"))
        assertTrue(source("MainActivity.kt").contains("@AndroidEntryPoint"))
    }

    @Test
    fun `assistant context and checked publication share one access authority and graph identity`() {
        val methods = AppModule::class.java.declaredMethods
        for (type in listOf(LibraryService::class.java, AssistantGraph::class.java)) {
            assertTrue(methods.single { it.returnType == type }.parameterTypes.contains(AssistantAccess::class.java))
        }
        val service = methods.single { it.returnType == AssistantService::class.java }
        assertTrue(service.parameterTypes.contains(MonotonicClock::class.java))
        val module = source("di/AppModule.kt")
        assertEquals(1, constructorCount(module, "AssistantService"))
        assertEquals(1, constructorCount(module, "AssistantGraph"))
        assertTrue(module.contains("fun assistantAccess(library: Lazy<LibraryService>)"))
        assertTrue(module.contains("library.get().accessSnapshot"))
        assertTrue(module.contains("snapshot.access(relativePath, identity)"))
    }

    @Test
    fun `graph roots are disjoint library state and settings trees`() {
        val module = source("di/AppModule.kt")
        assertTrue(module.contains("AndroidPromptStore(File(context.filesDir, \"library\"))"))
        assertTrue(module.contains("AndroidStateStore(File(context.filesDir, \"state\"), settings = settings)"))
        assertTrue(AppModule::class.java.declaredMethods.single { it.returnType == AndroidStateStore::class.java }
            .parameterTypes.contains(AndroidSettingsStore::class.java))
        assertEquals(listOf(AndroidStateStore::class.java), AppModule::class.java.declaredMethods
            .single { it.returnType == StateStore::class.java }.parameterTypes.toList())
        assertTrue(module.contains("File(context.filesDir, \"datastore/settings.json\")"))
        assertTrue(module.contains("File(context.filesDir, \"datastore/secrets.json\")"))
    }

    @Test fun `HTTP platform context is initialized only when the network provider is requested`() {
        val provider = source("di/AppModule.kt").substringAfter("fun httpTransport(").substringBefore("    @Provides")
        assertTrue(provider.contains("@ApplicationContext context: Context"))
        val initialize = provider.indexOf("OkHttp.initialize(context)")
        assertTrue(initialize >= 0 && initialize < provider.indexOf("OkHttpHttpTransport("))
    }

    @Test fun `all production HTTP clients use the initialized provider including cold workers`() {
        val kotlin = sources.resolve("kotlin")
        val files = kotlin.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        val client = Regex("\\bOkHttpClient(?:\\.Builder)?\\s*\\(")
        val transport = Regex("\\bOkHttpHttpTransport\\s*\\(")
        assertEquals(listOf("ch/lkmc/monkeyspaw/data/OkHttpHttpTransport.kt"),
            files.filter { client.containsMatchIn(it.readText()) }.map { it.relativeTo(kotlin).invariantSeparatorsPath })
        assertEquals(listOf("ch/lkmc/monkeyspaw/di/AppModule.kt"), files.filter {
            it.name != "OkHttpHttpTransport.kt" && transport.containsMatchIn(it.readText())
        }.map { it.relativeTo(kotlin).invariantSeparatorsPath })
    }

    @Test fun `profile installation is requested only by launcher startup through a data driver`() {
        val driver = sources.resolve("kotlin/ch/lkmc/monkeyspaw/data/ForegroundProfileInstaller.kt")
        assertTrue(driver.isFile)
        assertTrue(driver.readText().contains("initializeComponent(ProfileInstallerInitializer::class.java)"))
        val activity = source("MainActivity.kt")
        assertTrue(activity.contains("@Inject internal lateinit var profiles: ForegroundProfileInstaller"))
        assertTrue(activity.substringAfter("override fun onCreate(").contains("profiles.initialize()"))
        assertFalse(source("MonkeysPawApplication.kt").contains("ForegroundProfileInstaller"))
    }

    @Test
    fun `graph source guard counts exact constructors rather than similarly named types`() {
        assertEquals(1, constructorCount("LibraryService( MemoLibraryService(", "LibraryService"))
        assertEquals(1, constructorCount("DataStoreFactory.create( OtherDataStoreFactory.create( DataStoreFactoryXcreate(",
            "DataStoreFactory.create"))
    }

    @Test
    fun `manifest disables backups and permits declared entries including launcher join links in one process`() {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(File(sources, "AndroidManifest.xml"))
        validateManifest(document)
        val activities = document.getElementsByTagName("activity")
        val viewers = (0 until activities.length).map { activities.item(it) as org.w3c.dom.Element }.filter { activity ->
            val actions = activity.getElementsByTagName("action")
            (0 until actions.length).any {
                (actions.item(it) as org.w3c.dom.Element).getAttributeNS(androidNamespace, "name") == "android.intent.action.VIEW"
            }
        }
        assertEquals(listOf(".MainActivity"), viewers.map { it.getAttributeNS(androidNamespace, "name") })
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
        val allowed = setOf(".MainActivity", ".entry.FillActivity", ".ime.MonkeysPawImeService", ".entry.PromptTileService",
            ".entry.PromptWidgetProvider", ".entry.PromptShortcutActivity", ".entry.ProcessTextActivity",
            ".entry.ShareReceiverActivity", "androidx.startup.InitializationProvider")
        val elements = document.getElementsByTagName("*")
        for (index in 0 until elements.length) {
            val element = elements.item(index) as org.w3c.dom.Element
            assertFalse(element.hasAttributeNS(androidNamespace, "process"))
            if (element.tagName in setOf("activity", "activity-alias", "service", "receiver", "provider")) {
                assertTrue(element.getAttributeNS(androidNamespace, "name") in allowed)
            }
            if (element.tagName == "provider") {
                assertEquals("false", element.getAttributeNS(androidNamespace, "exported"))
                assertEquals("\${applicationId}.androidx-startup", element.getAttributeNS(androidNamespace, "authorities"))
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
