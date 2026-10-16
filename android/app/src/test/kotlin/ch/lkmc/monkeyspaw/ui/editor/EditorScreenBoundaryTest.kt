package ch.lkmc.monkeyspaw.ui.editor

import java.io.File
import kotlin.test.*

internal class EditorScreenBoundaryTest {
    private val root = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val packageRoot = root.resolve("kotlin/ch/lkmc/monkeyspaw")
    private val assistantService = Regex("\\bAssistantService\\b")
    private val screenServices = Regex("\\b(?:AssistantAcceptance|AssistantSavePermit|EditingService|LibraryRepository)\\w*")

    @Test
    fun `network guard catches service types and companion references`() {
        for (reference in listOf("val service: AssistantService", "ch.lkmc.monkeyspaw.core.services.AssistantService.create()")) {
            assertTrue(assistantService.containsMatchIn(reference), reference)
        }
    }

    @Test
    fun `screen guard catches compound acceptance types`() {
        for (reference in listOf("AssistantAcceptanceEditor", "AssistantAcceptanceOutcome")) {
            assertTrue(screenServices.containsMatchIn(reference), reference)
        }
    }

    @Test
    fun `editor screens render completed intents and library selection goes through the guard`() {
        val screen = packageRoot.resolve("ui/editor/EditorScreen.kt").readText()
        for (intent in listOf("onEdit", "onSave", "onRename", "onMove", "onDelete", "onRestore", "onDecision", "onConflict")) {
            assertTrue(screen.contains(intent), intent)
        }
        assertTrue(screen.contains("EditorSourceField(state.source, state.relativePath, state.quoteSelection, state.canEdit, onEdit, onClearQuote)"))
        val field = packageRoot.resolve("ui/editor/EditorSourceField.kt").readText()
        assertTrue(field.contains("readOnly = !editable"))
        assertTrue(field.contains("editorSourceValue(field, source, quote)"))
        assertTrue(screen.contains("selected.canRestore && state.canCommand"))
        val activity = packageRoot.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("editor.onSelectionChanged = library::selectFromEditor"))
        assertTrue(activity.contains("onEdit = { assistantReview.close(); editor.open(it) }"))
        assertTrue(activity.contains("if (editing.isOpen) EditorScreen("))
        assertTrue(activity.contains("editor::resolveDecision"))
        assertTrue(activity.contains("editor.refresh()"))
    }

    @Test
    fun `editor has no clipboard delivery learning automatic apply or network dependencies`() {
        val editor = packageRoot.resolve("ui/editor").walkTopDown().filter { it.extension == "kt" }.map { it.readText() }.joinToString("\n")
        val forbidden = Regex("\\b(?:Clipboard|FillService|writeText|readText|recordUse|recordCopy|URL|HttpTransport|AssistantClient)\\b")
        assertFalse(forbidden.containsMatchIn(editor))
        val code = editor.replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
        assertFalse(assistantService.containsMatchIn(code))
        val screen = packageRoot.resolve("ui/editor/EditorScreen.kt").readText()
        assertFalse(screenServices.containsMatchIn(screen))
        assertTrue(editor.contains("val source: String"))
        val values = root.resolve("res/values/editor_strings.xml").readText()
        for (tab in listOf("edit", "preview", "fields", "history")) assertTrue(values.contains("name=\"editor_$tab\""))
    }
}
