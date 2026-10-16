package ch.lkmc.monkeyspaw.ui.editor

import androidx.compose.runtime.*
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.*

internal class EditorSourceFieldTest {
    @Test fun `editing the new file path retains source cursor and composition`() {
        val document = mutableStateOf(EditorUiState(relativePath = "Untitled.md", source = "A composing body", isNew = true))
        val recomposer = Recomposer(EmptyCoroutineContext)
        val composition = Composition(object : AbstractApplier<Unit>(Unit) {
            override fun insertTopDown(index: Int, instance: Unit) = Unit
            override fun insertBottomUp(index: Int, instance: Unit) = Unit
            override fun remove(index: Int, count: Int) = Unit
            override fun move(from: Int, to: Int, count: Int) = Unit
            override fun onClear() = Unit
        }, recomposer)
        lateinit var field: MutableState<TextFieldValue>
        lateinit var rendered: TextFieldValue
        fun render() {
            composition.setContent {
                val current = document.value
                field = rememberEditorSourceField(current.source!!)
                rendered = editorSourceValue(field.value, current.source, null)
            }
        }
        try {
            render()
            val editing = TextFieldValue(document.value.source!!, TextRange(8), TextRange(2, 11))
            field.value = editing
            render()
            assertEquals(editing, rendered)

            document.value = document.value.copy(relativePath = "Corrected.md")
            render()
            assertEquals(editing, rendered)

            document.value = document.value.copy(source = "Other document")
            render()
            assertEquals("Other document", rendered.text)
            assertEquals(TextRange.Zero, rendered.selection)
            assertNull(rendered.composition)
        } finally {
            composition.dispose()
            recomposer.close()
        }
    }

    @Test fun `external replacement clears composition owned by the previous text`() {
        val field = TextFieldValue("Old composing text", TextRange(8), TextRange(4, 13))
        for (source in listOf("New replacement text", "Short", "")) {
            val value = editorSourceValue(field, source, null)
            assertEquals(source, value.text)
            assertEquals(TextRange.Zero, value.selection)
            assertNull(value.composition, "Old composition must not apply to replacement text")
        }
    }

    @Test fun `typing and cursor movement retain composition for unchanged source`() {
        val field = TextFieldValue("😀 Cafe\u0301", TextRange(5), TextRange(3, 8))
        val value = editorSourceValue(field, field.text, null)
        assertEquals(field, value)
    }

    @Test fun `checked quote selects UTF16 range and replacement text drops old composition`() {
        val source = "😀 Cafe\u0301"
        val quote = ReviewQuoteSelection(3, 8)
        val field = TextFieldValue("Old composing text", TextRange(1), TextRange(4, 13))
        val value = editorSourceValue(field, source, quote)
        assertEquals("Cafe\u0301", value.text.substring(value.selection.start, value.selection.end))
        assertEquals(TextRange(3, 8), value.selection)
        assertNull(value.composition)
    }
}
