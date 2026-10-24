package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits
import kotlin.test.*

class PromptRenderLimitTest {
    private val chunkBytes = 1024
    private val exactRepeats = 2048

    private fun repeatedDefault(value: String, suffix: String = ""): PromptDocument =
        PromptCodec.parse("---\nfields: {x: {default: " + value + "}}\n---\n" +
            "{{x}}".repeat(exactRepeats) + suffix, "Limit.md").also { assertTrue(it.canRender) }

    @Test fun repeatedDefaultsCannotExpandBeyondTwoMiB() {
        val document = repeatedDefault("a".repeat(chunkBytes), "{{x}}")
        assertEquals(PromptRenderError.OutputTooLarge,
            assertFailsWith<PromptRenderError> { PromptRenderer.render(document) })
        assertEquals(PromptRenderError.OutputTooLarge,
            assertFailsWith<PromptRenderError> { PromptRenderer.preview(document) })
    }

    @Test fun exactTwoMiBBoundaryAllowsAsciiAndMultibyteDefaults() {
        for (chunk in listOf("a".repeat(chunkBytes), "é".repeat(512), "🐒".repeat(256))) {
            val document = repeatedDefault(chunk)
            val rendered = PromptRenderer.render(document)
            assertEquals(Limits.maxRenderedPromptBytes, rendered.encodeToByteArray().size)
            assertTrue(PromptRenderer.preview(document) == rendered)
            val over = repeatedDefault(chunk, "!")
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> { PromptRenderer.render(over) })
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> { PromptRenderer.preview(over) })
        }
    }

    @Test fun suppliedValuesAndClipboardHaveTheSameUtf8Boundary() {
        val field = PromptCodec.parse("{{x}}{{x}}", "Field.md")
        val clipboard = PromptCodec.parse("{{clipboard}}{{clipboard}}", "Clipboard.md")
        for (value in listOf("a".repeat(Limits.maxRenderedPromptBytes / 2),
            "é".repeat(Limits.maxRenderedPromptBytes / 4), "🐒".repeat(Limits.maxRenderedPromptBytes / 8))) {
            assertEquals(Limits.maxRenderedPromptBytes,
                PromptRenderer.render(field, mapOf("x" to value)).encodeToByteArray().size)
            assertEquals(Limits.maxRenderedPromptBytes,
                PromptRenderer.render(clipboard, builtins = PromptBuiltinValues(clipboard = value)).encodeToByteArray().size)
            assertEquals(Limits.maxRenderedPromptBytes,
                PromptRenderer.preview(clipboard, PromptBuiltinValues(clipboard = value)).encodeToByteArray().size)
            val over = value + "!"
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> { PromptRenderer.render(field, mapOf("x" to over)) })
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> { PromptRenderer.render(clipboard, builtins = PromptBuiltinValues(clipboard = over)) })
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> { PromptRenderer.preview(clipboard, PromptBuiltinValues(clipboard = over)) })
        }
    }

    @Test fun oversizedSingleValueIsRefusedWithoutIncludingItsContent() {
        val document = PromptCodec.parse("{{x}}", "Field.md")
        val privateValue = "private".repeat(Limits.maxRenderedPromptBytes / 7 + 1)
        val error = assertFailsWith<PromptRenderError> { PromptRenderer.render(document, mapOf("x" to privateValue)) }
        assertEquals(PromptRenderError.OutputTooLarge, error)
        assertFalse(error.toString().contains("private"))
    }

    @Test fun surrogatePairsAcrossSubstitutionsUseTheirCombinedUtf8Size() {
        for (middle in listOf("", "{{empty}}")) {
            val document = PromptCodec.parse("---\nfields: {empty: {optional: true}}\n---\n" +
                "{{prefix}}{{hi}}" + middle + "{{lo}}", "Boundary.md")
            val pieces = mapOf("prefix" to "a".repeat(Limits.maxRenderedPromptBytes - 2),
                "hi" to "\uD83D", "lo" to "\uDC12", "empty" to "")
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> { PromptRenderer.render(document, pieces) })
            val atLimit = PromptRenderer.render(document,
                pieces + ("prefix" to "a".repeat(Limits.maxRenderedPromptBytes - 4)))
            assertEquals(Limits.maxRenderedPromptBytes, atLimit.encodeToByteArray().size)
            assertTrue(atLimit.endsWith("🐒"))
        }
    }

    @Test fun previewPreservesMarkersSnapshotsEscapesAndSinglePassDefaults() {
        val document = PromptCodec.parse("---\nfields:\n  x: {default: '{{clipboard}}'}\n" +
            "  choice: {type: choice, options: [one, two]}\n  optional: {optional: true}\n---\n" +
            "{{x}}|{{choice}}|{{optional}}|{{implicit}}|{{clipboard}}|{{date}}|{{time}}|\\{{literal}}", "Preview.md")
        assertTrue(document.canRender)
        assertEquals("{{clipboard}}|{choice}|{optional}|{implicit}|{clipboard}|{date}|{time}|{{literal}}",
            PromptRenderer.preview(document))
        assertEquals("{{clipboard}}|{choice}|{optional}|{implicit}||2026-10-24|13:15|{{literal}}",
            PromptRenderer.preview(document, PromptBuiltinValues(clipboard = "", date = "2026-10-24", time = "13:15")))
    }
}
