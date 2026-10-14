package ch.lkmc.monkeyspaw.ui.editor

import java.io.File
import kotlin.test.*

internal class EditorScreenBoundaryTest {
    private val root = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val packageRoot = root.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test
    fun `editor screens render completed intents and library selection goes through the guard`() {
        val screen = packageRoot.resolve("ui/editor/EditorScreen.kt").readText()
        for (intent in listOf("onEdit", "onSave", "onRename", "onMove", "onDelete", "onRestore", "onDecision", "onConflict")) {
            assertTrue(screen.contains(intent), intent)
        }
        assertTrue(screen.contains("readOnly = !state.canEdit"))
        assertTrue(screen.contains("selected.canRestore && state.canCommand"))
        val activity = packageRoot.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("editor.onSelectionChanged = library::selectFromEditor"))
        assertTrue(activity.contains("onEdit = { editor.open(it) }"))
        assertTrue(activity.contains("if (editing.isOpen) EditorScreen("))
        assertTrue(activity.contains("editor::resolveDecision"))
        assertTrue(activity.contains("editor.refresh()"))
    }

    @Test
    fun `editor has no clipboard delivery learning automatic apply or network dependencies`() {
        val editor = packageRoot.resolve("ui/editor").walkTopDown().filter { it.extension == "kt" }.map { it.readText() }.joinToString("\n")
        val forbidden = Regex("\\b(?:Clipboard|FillService|writeText|readText|recordUse|recordCopy|URL|HttpTransport|AssistantClient)\\b")
        assertFalse(forbidden.containsMatchIn(editor))
        assertFalse(Regex("(?:import[^\\n]*AssistantService|AssistantService\\s*\\()").containsMatchIn(editor))
        val screen = packageRoot.resolve("ui/editor/EditorScreen.kt").readText()
        assertFalse(Regex("\\b(?:AssistantAcceptance|AssistantSavePermit|EditingService|LibraryRepository)\\b").containsMatchIn(screen))
        assertTrue(editor.contains("val source: String"))
        val values = root.resolve("res/values/editor_strings.xml").readText()
        for (tab in listOf("edit", "preview", "fields", "history")) assertTrue(values.contains("name=\"editor_$tab\""))
    }
}
