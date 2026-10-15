package ch.lkmc.monkeyspaw.ime

import ch.lkmc.monkeyspaw.di.AppModule
import ch.lkmc.monkeyspaw.data.AndroidClipboard
import ch.lkmc.monkeyspaw.data.AndroidImeGateway
import ch.lkmc.monkeyspaw.data.ImeTextDelivery
import ch.lkmc.monkeyspaw.data.ImeSwitchBack
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import java.io.File
import javax.inject.Inject
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import kotlin.test.*

/** Source/DI boundaries complement session tests; they do not execute a system IME binder. */
internal class ImeBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val app = sources.resolve("kotlin/ch/lkmc/monkeyspaw")
    private val core = File(checkNotNull(System.getProperty("monkeyspaw.coreSources")))
    private val namespace = "http://schemas.android.com/apk/res/android"
    private val forbidden = Regex("\\b(?:HttpTransport|OkHttp\\w*|SyncEngine|Assistant(?!TokenUsage\\b)\\w*|SecretStore|AndroidKeystore\\w*|WorkManager|WorkRequest|Logger|Log|Timber|Socket|URLConnection|URL|sendKeyEvent|sendKeyChar|performEditorAction|setComposingText|getTextBeforeCursor|getTextAfterCursor|getSelectedText|getSurroundingText|getExtractedText|requestCursorUpdates|SavedStateHandle|rememberSaveable)\\b")

    @Test fun `IME is exported only behind system binding permission with exact filter and metadata in one process`() {
        val manifest = xml("AndroidManifest.xml")
        val service = children(manifest, "service").single { it.attr("name") == ".ime.MonkeysPawImeService" }
        assertEquals("true", service.attr("exported"))
        assertEquals("android.permission.BIND_INPUT_METHOD", service.attr("permission"))
        val filters = children(service, "intent-filter")
        assertEquals(1, filters.size)
        assertEquals(listOf("android.view.InputMethod"), children(filters.single(), "action").map { it.attr("name") })
        assertTrue(children(filters.single(), "category").isEmpty())
        assertTrue(children(filters.single(), "data").isEmpty())
        val metadata = children(service, "meta-data").single()
        assertEquals("android.view.im", metadata.attr("name"))
        assertEquals("@xml/method", metadata.attr("resource"))
        for (element in children(manifest, "*") + manifest) assertFalse(element.hasAttributeNS(namespace, "process"))
        val method = xml("res/xml/method.xml")
        assertEquals("input-method", method.tagName)
        assertEquals("true", method.attr("supportsSwitchingToNextInputMethod"))
        assertFalse(method.hasAttributeNS(namespace, "settingsActivity"))
        val labels = children(xml("res/values/strings.xml"), "string").associate { it.getAttribute("name") to it.textContent }
        assertNotNull(labels[service.attr("label").removePrefix("@string/")])
        // INTERNET remains app-wide for the assistant/sync; graph reachability is the IME gate.
        assertEquals(1, children(manifest, "uses-permission").count { it.attr("name") == "android.permission.INTERNET" })
    }

    @Test fun `local graph constructor and provider closure cannot reach network secrets scheduling or logger`() {
        app.resolve("ime").listFiles { file -> file.extension == "kt" }!!.forEach { validateGraphSource(it.readText()) }
        val reached = graphClosure(ImeLocalGraph::class.java, ImeSessionController::class.java,
            ImeViewOwners::class.java, AndroidClipboard::class.java, AndroidImeGateway::class.java, ImeTextDelivery::class.java,
            ImeSwitchBack::class.java, FillViewModel::class.java, LibraryViewModel::class.java)
        assertTrue(reached.any { it.simpleName == "LibraryRepository" })
        assertTrue(reached.any { it.simpleName == "FillService" })
        assertTrue(reached.any { it.simpleName == "Clipboard" })
        assertTrue(reached.any { it.simpleName == "AndroidSettingsStore" })
        assertFalse(reached.any { it.simpleName == "CoroutineScope" })
        val graph = app.resolve("ime/ImeLocalGraph.kt").readText()
        assertTrue(graph.contains("ImeTextDelivery(gateway, session.isActive, copy)"))
        assertTrue(graph.contains("ViewModelProvider(owner, factory)"))
    }

    @Test fun `graph guard rejects inherited network access without project source`() {
        val error = assertFailsWith<AssertionError> { graphClosure(InheritedConnection::class.java) }
        assertEquals("URLConnection", error.message?.substringBefore('.'))
    }

    @Test fun `graph guard rejects inherited secret interfaces without project source`() {
        val error = assertFailsWith<AssertionError> { graphClosure(InheritedSecret::class.java) }
        assertEquals("SecretStore", error.message?.substringBefore('.'))
    }

    private abstract class InheritedConnection : javax.net.ssl.HttpsURLConnection(null)
    private interface InheritedSecret : ch.lkmc.monkeyspaw.core.ports.SecretStore

    private fun graphClosure(vararg roots: Class<*>): Set<Class<*>> {
        val providers = AppModule::class.java.declaredMethods.associateBy { it.returnType }
        val module = app.resolve("di/AppModule.kt").readText()
        val providerBodies = module.split("    @Provides").drop(1).associate { block ->
            Regex("fun (\\w+)\\(").find(block)!!.groupValues[1] to block
        }
        val reached = mutableSetOf<Class<*>>()
        val classSources = (app.walkTopDown() + core.walkTopDown()).filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                val source = file.readText()
                val pkg = Regex("(?m)^package (\\S+)").find(source)!!.groupValues[1]
                Regex("\\b(?:class|interface|object) (\\w+)").findAll(source).map { "$pkg.${it.groupValues[1]}" to source }
            }.groupBy({ it.first }, { it.second })
        fun visit(type: Class<*>) {
            if (!reached.add(type)) return
            assertFalse(forbidden.containsMatchIn(type.simpleName), type.simpleName)
            providers[type]?.let { provider ->
                validateGraphSource(providerBodies.getValue(provider.name))
                provider.parameterTypes.forEach(::visit)
            }
            type.declaredConstructors.filter { it.getAnnotation(Inject::class.java) != null }
                .flatMap { it.parameterTypes.toList() }.forEach(::visit)
            type.superclass?.let(::visit)
            type.interfaces.forEach(::visit)
            if (!type.name.startsWith("ch.lkmc.monkeyspaw.")) return
            classSources[type.name.substringBefore('$')]?.forEach(::validateGraphSource)
            type.declaredFields.filterNot { java.lang.reflect.Modifier.isStatic(it.modifiers) }
                .forEach { visit(it.type) }
        }
        roots.forEach(::visit)
        return reached
    }

    @Test fun `privacy source guard detects network construction reads logs and scheduling`() {
        for (code in listOf("HttpTransport", "OkHttpClient()", "SyncEngine()", "AssistantClient()", "SecretStore",
            "WorkManager.getInstance()", "Logger.getLogger()", "Log.d()", "getSurroundingText()", "getExtractedText()",
            "getSelectedText()", "SavedStateHandle", "rememberSaveable", "AssistantTokenUsageClient()",
            "AssistantTokenUsage(Logger.getLogger())", "@ApplicationScope scope", "AppModule.applicationScope(io)")) {
            assertFailsWith<AssertionError> { validateGraphSource(code) }
        }
    }

    @Test fun `history token counters remain an immutable value with no assistant behavior`() {
        val source = core.resolve("ch/lkmc/monkeyspaw/core/domain/llm/AssistantTypes.kt").readText()
        // Pin the entire bodyless declaration before allowing its name in local history codecs.
        assertTrue(source.contains("\ndata class AssistantTokenUsage(val inputTokens: Long, val outputTokens: Long)\n\ndata class AssistantResponse("))
        validateGraphSource("AssistantTokenUsage(1L, 2L)")
    }

    @Test fun `application startup only warms local index and service reads only allowed metadata without extracted UI`() {
        val application = app.resolve("MonkeysPawApplication.kt").readText()
        validateLocal(application)
        assertTrue(application.contains("scope.launch { library.refresh() }"))
        val service = app.resolve("ime/MonkeysPawImeService.kt").readText()
        validateLocal(service)
        assertTrue(service.contains("onEvaluateFullscreenMode(): Boolean = false"))
        assertTrue(service.contains("onCreateExtractTextView(): View? = null"))
        val gateway = app.resolve("data/AndroidImeGateway.kt").readText()
        validateLocal(gateway)
        assertTrue(gateway.contains("info?.inputType, info?.imeOptions ?: 0, service.currentInputConnection, inFillActivity()"))
        assertFalse(Regex("\\b(?:hintText|packageName|fieldId|initialSelStart|initialSelEnd|initialSurroundingText|onKeyDown|onKeyUp)\\b")
            .containsMatchIn(service))
        assertFalse(Regex("\\b(?:hintText|packageName|fieldId|initialSelStart|initialSelEnd|initialSurroundingText)\\b")
            .containsMatchIn(gateway))
        assertEquals(1, Regex("connection\\.commitText\\(").findAll(gateway).count())
        assertTrue(gateway.contains("editor.matches(editor())"))
        assertTrue(gateway.contains("service.window?.window?.attributes?.token"))
        assertFalse(service.contains("super.onFinishInput"))
        assertTrue(service.contains("@AndroidEntryPoint"))
        assertEquals(1, Regex("@Inject").findAll(service).count())
        assertTrue(service.contains("lateinit var localGraph: ImeLocalGraph"))
    }

    @Test fun `password screen branches before reused controls and inline hosts request no software keyboard or own IME inset`() {
        val screen = app.resolve("ime/ImeScreen.kt").readText()
        validateLocal(screen)
        assertPasswordBranch(screen)
        assertTrue(screen.contains("mode = LibraryMode.IME_PICKER"))
        assertFalse(screen.contains("OutlinedTextField"))
        assertFalse(Regex("\\b(?:LocalContext|File|LibraryRepository|Clipboard)\\b").containsMatchIn(screen))
        val library = app.resolve("ui/library/LibraryScreen.kt").readText()
        assertTrue(library.contains("KeyboardOptions(showKeyboardOnFocus = mode != LibraryMode.IME_PICKER)"))
        assertTrue(library.contains("favoriteEnabled = mode == LibraryMode.BROWSER"))
        val fill = app.resolve("ui/fill/FillScreen.kt").readText()
        assertTrue(fill.contains("if (state.input == FillInput.INLINE) it else it.imePadding()"))
    }

    @Test fun `password branch guard rejects a disabled password gate`() {
        val screen = app.resolve("ime/ImeScreen.kt").readText()
        assertFailsWith<AssertionError> { assertPasswordBranch(screen.replace("if (state.password)", "if (false)")) }
    }

    private fun assertPasswordBranch(screen: String) {
        val password = screen.indexOf("if (state.password)")
        assertTrue(password >= 0 && password < screen.indexOf("FillScreen(fill,"))
    }

    private fun validateLocal(source: String) {
        assertFalse(forbidden.containsMatchIn(source), forbidden.find(source)?.value)
    }

    private fun validateGraphSource(source: String) {
        validateLocal(source)
        assertFalse(Regex("\\b(?:ApplicationScope|applicationScope)\\b").containsMatchIn(source), "Application scope")
    }

    private fun xml(path: String): Element = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(sources.resolve(path)).documentElement
    private fun children(element: Element, tag: String): List<Element> = element.getElementsByTagName(tag).let { nodes ->
        (0 until nodes.length).map { nodes.item(it) as Element }
    }
    private fun Element.attr(name: String): String = getAttributeNS(namespace, name)
}
