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
    private val forbidden = Regex("\\b(?:HttpTransport|OkHttp\\w*|SyncEngine|SyncScheduler|AndroidSyncTlsTrust|PlatformInitializer|ProfileInstallerInitializer|ForegroundProfileInstaller|AppInitializer|Assistant(?!(?:TokenUsage|Access)\\b)\\w*|SecretStore|AndroidKeystore\\w*|WorkManager|WorkRequest|JobScheduler|AlarmManager|Logger|Log|Timber|print|println|Socket|URLConnection|URL(?=\\s*(?:\\(|\\.|::))|sendKeyEvent|sendKeyChar|performEditorAction|setComposingText|getTextBeforeCursor|getTextAfterCursor|getSelectedText|getSurroundingText|getExtractedText|getInitialTextBeforeCursor|getInitialTextAfterCursor|getInitialSelectedText|takeSnapshot|requestCursorUpdates|SavedStateHandle|rememberSaveable|ProcessBuilder|Runtime)\\b|\\bSystem\\.(?:out|err)\\b|\\bjava\\.net\\.URL\\b|::\\s*URL\\b|^URL$")
    // Shared local save methods name contracts without holding a provider or assistant session.
    private val localSaveReferences = setOf("AssistantAcceptance", "AssistantAcceptanceConflict", "AssistantAcceptanceEditor",
        "AssistantAcceptanceFailure", "AssistantAcceptanceOutcome", "AssistantAccessState", "AssistantCandidate",
        "AssistantCommittedPrompt", "AssistantEditorSnapshot", "AssistantMutationAccess", "AssistantSaveDestination",
        "AssistantSavePermit", "AssistantSaveRefusal")
    private val helperSources by lazy {
        indexSources((app.walkTopDown() + core.walkTopDown()).filter { it.isFile && it.extension == "kt" }.map { it.readText() })
    }

    private fun indexSources(sources: Sequence<String>): Map<String, List<String>> =
        sources.flatMap { source ->
            val pkg = Regex("(?m)^package (\\S+)").find(source)!!.groupValues[1]
            // Follow local constructions and object calls that reflection cannot see.
            // Same-line annotations with arguments and imported members still need semantic analysis.
            val modifiers = "(?:(?:@[\\w.]+|private|internal|public|expect|actual|external|infix|operator|suspend|inline|tailrec|sealed|data|abstract|open|value|enum|annotation|final)\\s+)*"
            val functions = Regex("(?m)^${modifiers}fun (?:<[^\\n>]+> )?(?:[^\\n(]+\\.)?(\\w+)\\(").findAll(source).toList()
            val types = Regex("(?m)^$modifiers(?:fun )?(?:class|interface|object) (\\w+)").findAll(source).toList()
            val properties = Regex("(?m)^${modifiers}(?:(?:const|lateinit)\\s+)?(?:val|var) \\w+").findAll(source).toList()
            val starts = (functions + types + properties).map { it.range.first }.sorted()
            val header = Regex("(?m)^(?:package|import) [^\\n]+").findAll(source).joinToString("\n") { it.value }
            fun body(start: Int): String = source.substring(start, starts.firstOrNull { it > start } ?: source.length)
            // File initialization and shared property access remain conservatively in every closure.
            val initializers = properties.joinToString("\n") { body(it.range.first) }
            (functions + types).asSequence().map { declaration ->
                // Follow each declaration's calls without pulling in unrelated siblings.
                "$pkg.${declaration.groupValues[1]}" to "$header\n${body(declaration.range.first)}\n$initializers"
            }
        }.groupBy({ it.first }, { it.second })

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
        assertTrue(reached.any { it.simpleName == "AndroidSyncStartup" })
        assertTrue(reached.any { it.simpleName == "SyncLocalGraph" })
        assertTrue(reached.any { it.simpleName == "SyncEngineGraph" })
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

    @Test fun `local save references do not admit assistant sessions or provider access`() {
        val library = core.resolve("ch/lkmc/monkeyspaw/core/services/LibraryService.kt").readText()
        val access = core.resolve("ch/lkmc/monkeyspaw/core/services/AssistantAcceptance.kt").readText()
        assertTrue(library.contains("private val assistantAccess: AssistantAccess = AssistantAccess.LOCAL,"))
        assertTrue(access.contains("val LOCAL = AssistantAccess { AssistantAccessState.PRIVATE_PROMPT }"))
        val module = app.resolve("di/AppModule.kt").readText()
        assertTrue(module.contains("LibraryService(prompts, state, clock, entropy, access)"))
        assertTrue(module.contains("fun assistantAccess(): AssistantAccess = AssistantAccess.LOCAL"))
        for (name in localSaveReferences) {
            validateGraphSource(name)
            // Source references are allowed; an instance in the runtime graph remains forbidden.
            val error = assertFailsWith<AssertionError> {
                graphClosure(Class.forName("ch.lkmc.monkeyspaw.core.services.$name"))
            }
            assertEquals(name, error.message?.substringBefore('.'))
        }
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
        val validatedSources = mutableSetOf<String>()
        fun visit(type: Class<*>) {
            if (!reached.add(type)) return
            assertFalse(forbidden.containsMatchIn(type.simpleName), type.simpleName)
            providers[type]?.let { provider ->
                validateGraphSource(providerBodies.getValue(provider.name), visited = validatedSources, resolutionSource = module)
                provider.parameterTypes.forEach(::visit)
            }
            type.declaredConstructors.filter { it.getAnnotation(Inject::class.java) != null }
                .flatMap { it.parameterTypes.toList() }.forEach(::visit)
            type.superclass?.let(::visit)
            type.interfaces.forEach(::visit)
            if (!type.name.startsWith("ch.lkmc.monkeyspaw.")) return
            helperSources[type.name.substringBefore('$')]?.forEach { validateGraphSource(it, visited = validatedSources) }
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
            "AssistantTokenUsage(Logger.getLogger())", "@ApplicationScope scope", "AppModule.applicationScope(io)",
            "AssistantAccessClient()", "AssistantSavePermit(SecretStore)", "AssistantAcceptance(AssistantClient())",
            "AssistantAccess { Logger.getLogger() }")) {
            assertFailsWith<AssertionError> { validateGraphSource(code) }
        }
    }

    @Test fun `privacy source guard rejects indirect sync scheduling stdout and initial target reads`() {
        for (code in listOf("SyncScheduler()", "AndroidSyncTlsTrust()", "PlatformInitializer()", "ProfileInstallerInitializer()",
            "ForegroundProfileInstaller(context)", "AppInitializer.getInstance(context)", "JobScheduler()", "AlarmManager()",
            "println(privateValue)", "System.err.write(privateBytes)", "getInitialTextBeforeCursor(1, 0)",
            "getInitialTextAfterCursor(1, 0)", "getInitialSelectedText(0)", "takeSnapshot()")) {
            assertFailsWith<AssertionError>(code) { validateGraphSource(code) }
        }
    }

    @Test fun `source guard follows top-level helper calls and callback references transitively`() {
        val helpers = mapOf("warmLocalIndex" to listOf("fun warmLocalIndex() = onReady(::notifyReady)"),
            "notifyReady" to listOf("fun notifyReady() = Logger.getLogger(\"private\")"))
        for (source in listOf("warmLocalIndex()", "launch(::warmLocalIndex)")) {
            assertFailsWith<AssertionError> { validateGraphSource(source, helpers) }
        }
        validateGraphSource("unrelatedLocalCall()", helpers)
        val qualified = mapOf("other.prepare" to listOf("fun prepare() = Logger.getLogger(\"private\")"))
        validateGraphSource("package local\nfun work() = prepare()", qualified)
        assertFailsWith<AssertionError> {
            validateGraphSource("package local\nimport other.prepare as ready\nfun work() = ready()", qualified)
        }
    }

    @Test fun `source guard follows constructed helpers and object members transitively`() {
        for (declaration in listOf("class Helper", "object Helper", "interface Helper", "fun interface Helper",
            "value class Helper(val value: Int)", "enum class Helper")) {
            val helpers = indexSources(sequenceOf("package other\n$declaration { fun run() = nested() }",
                "package other\nfun nested() = OkHttpClient()"))
            assertTrue("other.Helper" in helpers, declaration)
            for (call in listOf("Helper()", "Helper.run()", "launch(::Helper)")) {
                assertFailsWith<AssertionError>("$declaration: $call") {
                    validateGraphSource("package local\nimport other.Helper\nfun work() = $call", helpers)
                }
            }
        }
    }

    @Test fun `local save contract names cannot disguise app helper capabilities`() {
        for (name in listOf("AssistantAcceptance", "AssistantAcceptanceConflict", "AssistantAcceptanceEditor",
            "AssistantAcceptanceFailure", "AssistantAcceptanceOutcome", "AssistantAccessState", "AssistantCandidate",
            "AssistantCommittedPrompt", "AssistantEditorSnapshot", "AssistantMutationAccess", "AssistantSaveDestination",
            "AssistantSavePermit", "AssistantSaveRefusal")) {
            val helpers = indexSources(sequenceOf("package other\nclass $name(private val connection: " +
                "javax.net.ssl.HttpsURLConnection) { fun send() = connection.connect() }"))
            assertFailsWith<AssertionError>(name) {
                validateGraphSource("package local\nimport other.$name\n" +
                    "fun work(connection: javax.net.ssl.HttpsURLConnection) = $name(connection).send()", helpers)
            }
        }
    }

    @Test fun `source guard indexes annotated and additional function modifiers`() {
        for (declaration in listOf("@PublishedApi internal inline fun prepare()", "actual fun prepare()",
            "expect fun prepare()", "external fun prepare()", "infix fun Any.prepare(other: Any)")) {
            val helpers = indexSources(sequenceOf("package other\n$declaration = SecretStore()"))
            assertTrue("other.prepare" in helpers, declaration)
            assertFailsWith<AssertionError>(declaration) {
                validateGraphSource("package local\nimport other.prepare\nfun work() = prepare()", helpers)
            }
        }
    }

    @Test fun `explicit helper aliases take precedence over wildcard imports`() {
        val helpers = mapOf("other.prepare" to listOf("fun prepare() = SyncScheduler()"))
        for (source in listOf("package local\nimport other.*\nimport other.prepare as ready\nfun work() = ready()",
            "package local\nimport other.*\nfun work() = prepare()")) {
            assertFailsWith<AssertionError> { validateGraphSource(source, helpers) }
        }
    }

    @Test fun `privacy source guard rejects subprocess escapes`() {
        for (source in listOf("ProcessBuilder(commands).start()", "Runtime.getRuntime().exec(command)")) {
            assertFailsWith<AssertionError>(source) { validateGraphSource(source) }
        }
    }

    @Test fun `type traversal preserves local values while following their private helpers`() {
        val helpers = indexSources(sequenceOf("package other\nclass Local\nclass Remote { fun run() = OkHttpClient() }"))
        validateGraphSource("package local\nimport other.Local\nfun work() = Local()", helpers)
        assertFailsWith<AssertionError> {
            validateGraphSource("package local\nimport other.Remote\nfun work() = Remote()", helpers)
        }
        val indirect = indexSources(sequenceOf("package other\nclass Local { fun run() = prepare() }\n" +
            "private fun prepare() = WorkManager.getInstance()"))
        assertFailsWith<AssertionError> {
            validateGraphSource("package local\nimport other.Local\nfun work() = Local()", indirect)
        }
        validateGraphSource("fun localValue() = \"<sync server URL>\"")
        for (source in listOf("java.net.URL", "URL(address)", "URL::class", "::URL", "URL")) {
            assertFailsWith<AssertionError>(source) { validateGraphSource(source) }
        }
    }

    @Test fun `local helper declarations exclude siblings but retain actual forbidden calls`() {
        val source = "package other\nclass Local { fun run() = prepare() }\n" +
            "private fun prepare() = Unit\nclass Remote { fun run() = HttpTransport() }"
        val local = "package local\nimport other.Local\nfun work() = Local()"
        validateGraphSource(local, indexSources(sequenceOf(source)))
        for (call in listOf("Remote()", "HttpTransport()", "SyncEngine()", "SecretStore()",
            "WorkManager.getInstance()", "AppModule.applicationScope(io)")) {
            val mutant = source.replace("prepare() = Unit", "prepare() = $call")
            assertFailsWith<AssertionError>(call) {
                validateGraphSource(local, indexSources(sequenceOf(mutant)))
            }
        }
    }

    @Test fun `declaration traversal retains file initializers around unrelated siblings`() {
        for (initializer in listOf("private val eager = HttpTransport()", "val eager by lazy { SecretStore() }")) {
            for (declarations in listOf("$initializer\nclass Unrelated\nfun prepare() = Unit",
                "fun prepare() = Unit\nclass Unrelated\n$initializer")) {
                val helpers = indexSources(sequenceOf("package other\n$declarations"))
                assertFailsWith<AssertionError>(declarations) {
                    validateGraphSource("package local\nimport other.prepare\nfun work() = prepare()", helpers)
                }
            }
        }
    }

    @Test fun `provider bodies resolve helper aliases without scanning unrelated module imports`() {
        val context = "package local\nimport other.Helper as Ready\nimport other.SecretStore"
        val helpers = indexSources(sequenceOf("package other\nclass Helper { fun run() = SyncScheduler() }"))
        validateGraphSource("fun provide() = Unit", helpers, resolutionSource = context)
        assertFailsWith<AssertionError> {
            validateGraphSource("fun provide() = Ready()", helpers, resolutionSource = context)
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
        assertLocalStartup(application)
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

    @Test fun `startup comments preserve the exact local call boundary`() {
        val application = app.resolve("MonkeysPawApplication.kt").readText()
            .replace("scope.launch {", "// Warm the local index.\n        scope.launch {")
        assertLocalStartup(application)
        for (call in listOf("prepareBackground()", "HttpTransport()", "SyncEngine()",
            "SecretStore()", "WorkManager.getInstance()")) {
            assertFailsWith<AssertionError>(call) {
                assertLocalStartup(application.replace("scope.launch {", "$call\n        scope.launch {"))
            }
        }
    }

    private fun assertLocalStartup(application: String) {
        validateLocal(application)
        assertTrue(application.contains("scope.launch { library.refresh() }"))
        assertEquals(listOf("library: LibraryRepository", "scope: CoroutineScope"),
            Regex("lateinit var ([^\\n]+)").findAll(application).map { it.groupValues[1] }.toList())
        val startup = application.substringAfter("override fun onCreate() {").substringBefore("\n    }")
            .lineSequence().filterNot { it.trimStart().startsWith("//") }.joinToString("\n").trim()
        assertEquals("super.onCreate()\n        scope.launch { library.refresh() }", startup)
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

    private fun validateLocal(source: String, allowedReferences: Set<String> = emptySet()) {
        val violation = forbidden.findAll(source).firstOrNull { it.value !in allowedReferences }
        assertNull(violation, violation?.value)
    }

    private fun validateGraphSource(source: String, helpers: Map<String, List<String>> = helperSources,
        visited: MutableSet<String> = mutableSetOf(), resolutionSource: String = source) {
        val callPatterns = mutableMapOf<String, Regex>()
        fun visit(current: String, context: String = current) {
            if (!visited.add(current)) return
            validateLocal(current, localSaveReferences)
            assertFalse(Regex("\\b(?:ApplicationScope|applicationScope)\\b").containsMatchIn(current), "Application scope")
            val pkg = Regex("(?m)^package (\\S+)").find(context)?.groupValues?.get(1)
            // Only Core declares these contracts; app helpers cannot borrow their exemptions.
            if (pkg != "ch.lkmc.monkeyspaw.core.services") {
                Regex("\\b(?:class|interface|object)\\s+(\\w+)").findAll(current).forEach {
                    validateLocal(it.groupValues[1])
                }
            }
            val imports = Regex("(?m)^import ([\\w.*]+)(?: as (\\w+))?").findAll(context).toList()
            for ((qualified, definitions) in helpers) {
                val name = qualified.substringAfterLast('.')
                val namespace = qualified.substringBeforeLast('.', "")
                val imported = imports.firstOrNull { it.groupValues[1] == qualified }
                    ?: imports.firstOrNull { it.groupValues[1] == "$namespace.*" }
                val visible = namespace.isEmpty() || namespace == pkg || imported != null
                val alias = imported?.groupValues?.get(2)?.ifEmpty { null } ?: name
                val call = if (visible) Regex.escape(alias) else Regex.escape(qualified)
                val pattern = callPatterns.getOrPut(call) { Regex("\\b$call\\s*(?:\\(|\\.)|::\\s*$call\\b") }
                if (pattern.containsMatchIn(current)) {
                    definitions.forEach { visit(it) }
                }
            }
        }
        visit(source, resolutionSource)
    }

    private fun xml(path: String): Element = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(sources.resolve(path)).documentElement
    private fun children(element: Element, tag: String): List<Element> = element.getElementsByTagName(tag).let { nodes ->
        (0 until nodes.length).map { nodes.item(it) as Element }
    }
    private fun Element.attr(name: String): String = getAttributeNS(namespace, name)
}
