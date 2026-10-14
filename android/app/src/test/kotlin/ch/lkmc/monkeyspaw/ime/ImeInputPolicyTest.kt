package ch.lkmc.monkeyspaw.ime

import android.text.InputType.*
import android.view.inputmethod.EditorInfo.*
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.ime.ImeInputPolicy.Decision
import ch.lkmc.monkeyspaw.ime.ImeInputPolicy.Insertion
import ch.lkmc.monkeyspaw.ime.ImeInputPolicy.Learning
import ch.lkmc.monkeyspaw.ime.ImeInputPolicy.Session
import kotlin.test.*

internal class ImeInputPolicyTest {
    @Test fun everyEditorRowHasTheExpectedSingleAndMultilineDecision() {
        val rows = listOf(
            Triple(null, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(TYPE_CLASS_TEXT, Insertion.SINGLE_LINE, Decision.INSERT),
            Triple(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_IME_MULTI_LINE, Insertion.SINGLE_LINE, Decision.INSERT),
            Triple(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, Insertion.MULTI_LINE, Decision.INSERT),
            Triple(TYPE_NULL, Insertion.SINGLE_LINE, Decision.INSERT),
            Triple(0x00080090, Insertion.SINGLE_LINE, Decision.INSERT),
            Triple(TYPE_CLASS_NUMBER, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(TYPE_CLASS_NUMBER or TYPE_NUMBER_FLAG_DECIMAL or TYPE_NUMBER_FLAG_SIGNED, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(TYPE_CLASS_PHONE, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(TYPE_CLASS_DATETIME, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(TYPE_CLASS_DATETIME or TYPE_DATETIME_VARIATION_DATE, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(TYPE_CLASS_DATETIME or TYPE_DATETIME_VARIATION_TIME, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
            Triple(0x0000000f, Insertion.COPY_ONLY, Decision.COPY_INSTEAD),
        )
        for ((input, insertion, singleLine) in rows) {
            val policy = ImeInputPolicy.classify(input)
            assertEquals(insertion, policy.insertion, input.toString())
            assertTrue(policy.promptsAllowed)
            assertEquals(singleLine, policy.decide("literal {{braces}}", true))
            assertEquals(if (insertion == Insertion.MULTI_LINE) Decision.INSERT else Decision.COPY_INSTEAD,
                policy.decide("first\nsecond", true))
            assertEquals(Decision.COPY_INSTEAD, policy.decide("single", false))
        }
    }

    @Test fun allFourPasswordVariantsWinOverEveryOtherPrerequisite() {
        val passwords = listOf(
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD,
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_PASSWORD,
            TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD,
        )
        for (input in passwords) for (flags in listOf(0, TYPE_TEXT_FLAG_MULTI_LINE, TYPE_MASK_FLAGS)) {
            val policy = ImeInputPolicy.classify(input or flags, IME_FLAG_NO_PERSONALIZED_LEARNING)
            assertEquals(Insertion.PASSWORD, policy.insertion)
            assertFalse(policy.promptsAllowed)
            for (session in Session.entries) for (connection in listOf(false, true)) {
                for (render in listOf(null, "", "single", "first\nsecond")) {
                    assertEquals(Decision.HIDE_PROMPTS, policy.decide(render, connection, session))
                }
            }
        }
    }

    @Test fun classAndVariationMasksHandleMixedBitsWithoutFalsePasswordMatches() {
        // Fixed platform encodings keep the expected result independent of implementation masks.
        for (inputClass in 0..15) for (variation in 0..255) {
            val base = inputClass or (variation shl 4)
            for (flags in listOf(0, 0x00020000, 0x00040000, 0x00080000, 0xffff0000.toInt())) {
                val expected = when {
                    base in listOf(0x81, 0x91, 0xe1, 0x12) -> Insertion.PASSWORD
                    inputClass == 1 && flags and 0x00020000 != 0 -> Insertion.MULTI_LINE
                    inputClass == 1 || inputClass == 0 -> Insertion.SINGLE_LINE
                    else -> Insertion.COPY_ONLY
                }
                assertEquals(expected, ImeInputPolicy.classify(base or flags).insertion,
                    "class=$inputClass variation=$variation flags=$flags")
            }
        }
        assertEquals(Insertion.COPY_ONLY, ImeInputPolicy.classify(TYPE_CLASS_TEXT or TYPE_CLASS_NUMBER).insertion)
        assertEquals(Insertion.SINGLE_LINE, ImeInputPolicy.classify(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI).insertion)
        assertEquals(Insertion.COPY_ONLY, ImeInputPolicy.classify(TYPE_CLASS_NUMBER or TYPE_TEXT_VARIATION_PASSWORD).insertion)
    }

    @Test fun retiredThenBlockedAttemptsPrecedeCopyFallbacks() {
        for (input in listOf(null, TYPE_NULL, TYPE_CLASS_TEXT, TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, TYPE_CLASS_NUMBER)) {
            val policy = ImeInputPolicy.classify(input)
            for (connection in listOf(false, true)) {
                assertEquals(Decision.CANCEL, policy.decide("valid", connection, Session.RETIRED))
                assertEquals(Decision.CANCEL, policy.decide(null, connection, Session.RETIRED))
                assertEquals(Decision.BLOCK, policy.decide(null, connection))
            }
        }
        val invalidRenders = listOf(
            PromptCodec.parse("{{broken", "invalid.md") to emptyMap<String, String>(),
            PromptCodec.parse("---\nformat: 2\n---\nfuture", "future.md") to emptyMap(),
            PromptCodec.parse("{{clipboard}}", "builtin.md") to emptyMap(),
            PromptCodec.parse("{{required}}", "required.md") to mapOf("required" to ""),
            PromptCodec.parse("---\nfields:\n  language:\n    type: choice\n    options: [Rust, Python]\n---\n{{language}}", "choice.md") to mapOf("language" to "other"),
        )
        for ((document, values) in invalidRenders) {
            assertFailsWith<PromptRenderError> { PromptRenderer.render(document, values) }
            val render = runCatching { PromptRenderer.render(document, values) }.getOrNull()
            assertEquals(Decision.BLOCK, ImeInputPolicy.classify(null).decide(render, false))
        }
    }

    @Test fun everyLineSeparatorIsCheckedInFinalBodyFieldAndBuiltinOutput() {
        val field = PromptCodec.parse("before{{value}}after", "field.md")
        val builtin = PromptCodec.parse("before{{clipboard}}{{date}}{{time}}after", "builtin.md")
        for (separator in listOf("\n", "\r", "\r\n", "\u000b", "\u000c", "\u0085", "\u2028", "\u2029")) {
            val inserted = "A${separator}B"
            val renders = listOf(
                PromptRenderer.render(PromptCodec.parse(inserted, "body.md")),
                PromptRenderer.render(field, mapOf("value" to inserted)),
                PromptRenderer.render(builtin, builtins = PromptBuiltinValues(inserted, "", "")),
                PromptRenderer.render(builtin, builtins = PromptBuiltinValues("", inserted, "")),
                PromptRenderer.render(builtin, builtins = PromptBuiltinValues("", "", inserted)),
            )
            for (text in renders) {
                assertTrue(text.contains(inserted))
                val before = text.encodeToByteArray()
                for (input in listOf(TYPE_NULL, 0x00080090, TYPE_NULL or TYPE_TEXT_FLAG_MULTI_LINE,
                    TYPE_CLASS_TEXT, TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_IME_MULTI_LINE)) {
                    assertEquals(Decision.COPY_INSTEAD, ImeInputPolicy.classify(input).decide(text, true))
                }
                assertEquals(Decision.INSERT, ImeInputPolicy.classify(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE).decide(text, true))
                assertContentEquals(before, text.encodeToByteArray())
            }
        }
    }

    @Test fun defaultAndChoiceLineBreaksAreNotFlattened() {
        for (declaration in listOf("default: \"A\\nB\"", "type: choice\n    options: [\"A\\nB\"]\n    default: \"A\\nB\"")) {
            val document = PromptCodec.parse("---\nfields:\n  value:\n    $declaration\n---\n{{value}}", "defaults.md")
            assertEquals("A\nB", PromptRenderer.render(document))
            assertEquals(Decision.COPY_INSTEAD, ImeInputPolicy.classify(TYPE_CLASS_TEXT).decide(PromptRenderer.render(document), true))
        }
        assertEquals(Decision.INSERT, ImeInputPolicy.classify(TYPE_CLASS_TEXT).decide(" \t{{literal}} e\u0301 🐒 ", true))
    }

    @Test fun learningOptOutIsIndependentOfActionAndMultilinePermission() {
        for (input in listOf(null, TYPE_NULL, 0x00080090, TYPE_CLASS_TEXT, TYPE_CLASS_NUMBER,
            TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD)) {
            for (action in 0..255) {
                val flags = IME_FLAG_FORCE_ASCII or IME_FLAG_NO_ENTER_ACTION or IME_FLAG_NO_EXTRACT_UI or
                    IME_FLAG_NO_FULLSCREEN or IME_FLAG_NAVIGATE_NEXT or IME_FLAG_NAVIGATE_PREVIOUS or IME_FLAG_NO_ACCESSORY_ACTION
                val normal = ImeInputPolicy.classify(input, flags or action)
                val ephemeral = ImeInputPolicy.classify(input, flags or action or IME_FLAG_NO_PERSONALIZED_LEARNING)
                assertEquals(Learning.NORMAL, normal.learning)
                assertEquals(Learning.EPHEMERAL, ephemeral.learning)
                assertEquals(normal.insertion, ephemeral.insertion)
                for (text in listOf("single", "multi\nline")) {
                    assertEquals(ImeInputPolicy.classify(input).decide(text, true), normal.decide(text, true))
                    assertEquals(normal.decide(text, true), ephemeral.decide(text, true))
                }
            }
        }
        assertEquals(Learning.NORMAL, ImeInputPolicy.classify(TYPE_CLASS_TEXT or IME_FLAG_NO_PERSONALIZED_LEARNING).learning)
    }
}
