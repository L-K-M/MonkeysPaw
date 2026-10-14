package ch.lkmc.monkeyspaw.ui.fill

import android.content.Intent.ACTION_PROCESS_TEXT
import android.content.Intent.ACTION_SEND
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.entry.CapturedTextRequest
import kotlin.test.*

internal class CapturedTextFieldChoiceTest {
    @Test fun firstEffectiveMultilineWinsInBodyOrderNotDeclarationOrder() {
        val document = prompt("""
            ---
            fields:
              unused:
                type: multiline
              second:
                type: multiline
              first:
                type: multiline
              text:
                type: text
            ---
            {{text}} {{first}} {{second}} {{first}}
        """.trimIndent())
        val choice = start(document)
        assertEquals(listOf("text", "first", "second"), choice.candidates.map { it.name })
        assertEquals("first", choice.selectedField)
        assertEquals(mapOf("text" to "", "first" to "captured", "second" to ""), choice.values)
        assertEquals("second", choice.select("second").selectedField)
        assertEquals("text", choice.select("text").selectedField)
        assertFailsWith<IllegalArgumentException> { choice.select("unused") }
    }

    @Test fun firstExplicitOrImplicitTextIsTheFallback() {
        for (body in listOf("{{implicit}} {{explicit}}", "{{explicit}} {{implicit}}")) {
            val document = prompt("---\nfields:\n  explicit:\n    default: default\n---\n$body")
            val choice = start(document)
            assertEquals(document.effectiveFields.first().name, choice.selectedField)
            assertTrue(choice.candidates.single { it.name == "implicit" }.isImplicit)
        }
        val document = prompt("---\nfields:\n  long:\n    type: multiline\n---\n{{implicit}} {{long}}")
        assertEquals("long", start(document).selectedField)
    }

    @Test fun choicesBuiltinsAndFieldlessPromptsNeverReceiveCapture() {
        val documents = listOf(
            prompt("---\nfields:\n  choice:\n    type: choice\n    options: [one, two]\n    default: one\n---\n{{choice}}"),
            prompt("{{clipboard}} {{date}} {{time}}"),
            prompt("literal body"),
        )
        for (document in documents) {
            val choice = start(document)
            assertNull(choice.selectedField)
            assertTrue(choice.candidates.isEmpty())
            assertFalse(choice.values.values.contains("captured"))
            for (name in listOf("choice", "clipboard", "date", "time", "unknown")) {
                assertFailsWith<IllegalArgumentException> { choice.select(name) }
            }
            val text = PromptRenderer.render(document, choice.values, PromptBuiltinValues("clip", "date", "time"))
            assertFalse(text.contains("captured"))
        }
        assertEquals("two", start(documents.first()).edit("choice", "two").values["choice"])
        assertFailsWith<IllegalArgumentException> { start(documents[1]).edit("clipboard", "edited") }
    }

    @Test fun movingAndIgnoringCaptureRestorePriorRememberedOrDefaultPrefills() {
        val document = prompt("---\nfields:\n  first:\n    default: default first\n  second:\n    default: default second\n---\n{{first}} {{second}}")
        val prefills = mutableMapOf("first" to "remembered first", "second" to "", "clipboard" to "ignored")
        val original = start(document, prefills)
        prefills["first"] = "later mutation"
        assertEquals(mapOf("first" to "captured", "second" to ""), original.values)
        val moved = original.select("second")
        assertEquals(mapOf("first" to "remembered first", "second" to "captured"), moved.values)
        assertEquals(mapOf("first" to "remembered first", "second" to ""), moved.select(null).values)
        assertEquals(original.values, moved.select("first").values)
        assertEquals(mapOf("first" to "default first", "second" to "default second"), start(document).select(null).values)
        assertEquals("captured", original.values["first"])
    }

    @Test fun userEditsIncludingEmptyTextWinAcrossMovesAndIgnore() {
        val document = prompt("{{first}} {{second}} {{third}}")
        val original = start(document, mapOf("first" to "remembered", "second" to "prior", "third" to "third prefill"))
        val edited = original.edit("first", "user first").edit("second", "")
        val moved = edited.select("second")
        assertEquals(mapOf("first" to "user first", "second" to "", "third" to "third prefill"), moved.values)
        assertEquals(moved.values, moved.select(null).values)
        assertEquals(moved.values, moved.select("first").values)
        val third = moved.select("third")
        assertEquals("captured", third.values["third"])
        assertEquals("third prefill", third.select(null).values["third"])
        assertEquals("captured", original.values["first"])
        assertEquals("prior", original.values["second"])
    }

    @Test fun changingPromptRecomputesAssignmentWithoutLeakingSameNamedEdits() {
        val first = prompt("---\nfields:\n  shared:\n    type: multiline\n---\n{{shared}} {{other}}")
        val second = prompt("---\nfields:\n  other:\n    type: multiline\n  shared:\n    default: new default\n---\n{{shared}} {{other}}")
        val retained = start(first).edit("shared", "first prompt edit").select("other")
        val next = start(second)
        assertEquals("other", next.selectedField)
        assertEquals(mapOf("shared" to "new default", "other" to "captured"), next.values)
        assertEquals("first prompt edit", retained.values["shared"])
        assertEquals("captured", retained.values["other"])
    }

    @Test fun selectionReadOnlyAndShareUseTheSameFieldChoice() {
        val document = prompt("---\nfields:\n  long:\n    type: multiline\n---\n{{short}} {{long}}")
        val requests = listOf(
            CapturedTextRequest.parse(ACTION_PROCESS_TEXT, "text/plain", "capture", false),
            CapturedTextRequest.parse(ACTION_PROCESS_TEXT, "text/plain", "capture"),
            CapturedTextRequest.parse(ACTION_SEND, "text/plain", "capture"),
        )
        for (request in requests) {
            val choice = CapturedTextFieldChoice.start(document, request)
            assertEquals("long", choice.selectedField)
            assertEquals("capture", choice.values["long"])
        }
    }

    @Test fun captureIsLiteralAndRenderingRemainsSinglePass() {
        val text = " \t{{clipboard}} {{other}} e\u0301 🐒\r\n\u2028 "
        val request = CapturedTextRequest.parse(ACTION_SEND, "text/plain", text)
        val document = prompt("{{field}}|{{field}}|{{clipboard}}")
        val choice = CapturedTextFieldChoice.start(document, request)
        assertEquals(text, choice.values["field"])
        val rendered = PromptRenderer.render(document, choice.values, PromptBuiltinValues(clipboard = "builtin snapshot"))
        assertEquals("$text|$text|builtin snapshot", rendered)
        assertContentEquals("$text|$text|builtin snapshot".encodeToByteArray(), rendered.encodeToByteArray())
    }

    private fun prompt(source: String): PromptDocument = PromptCodec.parse(source, "capture.md").also { assertTrue(it.canRender, it.issues.toString()) }
    private fun start(document: PromptDocument, prefills: Map<String, String> = emptyMap()) =
        CapturedTextFieldChoice.start(document, CapturedTextRequest.parse(ACTION_SEND, "text/plain", "captured"), prefills)
}
