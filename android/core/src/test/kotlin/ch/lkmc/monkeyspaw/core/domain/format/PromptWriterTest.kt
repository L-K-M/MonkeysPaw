package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PromptWriterTest {
    private fun read(header: String, body: String = "Body") = PromptCodec.parse("---\n$header\n---\n$body", "Fallback.md")

    private fun roundTrip(document: PromptDocument, expected: String) {
        val written = PromptCodec.write(document)
        assertEquals(expected, written)
        val repeated = PromptCodec.parse(written, "Different.md")
        assertEquals(document.frontMatter.description, repeated.frontMatter.description)
        assertEquals(document.frontMatter.fields, repeated.frontMatter.fields)
        assertEquals(document.body, repeated.body)
        assertEquals(written, PromptCodec.write(repeated))
    }

    @Test fun optionalKeyPresenceAndContentOnlyWritingNeverAssignIdentity() {
        for (source in listOf("", "Plain\r\n", "\uFEFF---\nprivate: true\n---\nBody")) {
            val document = PromptCodec.parse(source, "Fallback.md")
            assertEquals(source, PromptCodec.write(document))
            assertNull(document.frontMatter.id)
        }
        for (header in listOf("", "# comment", "{}")) roundTrip(read(header), "---\n{}\n---\nBody")
        roundTrip(read("description: ''\ntags: []\nfavorite: false\nprivate: false"),
            "---\ndescription: \"\"\ntags: []\nfavorite: false\nprivate: false\n---\nBody")
        val text = PromptCodec.write(read("x: value"))
        assertFalse(text.contains("id:"))
        assertFalse(text.contains("title:"))
        assertFalse(text.contains("format:"))
        assertNull(PromptCodec.parse(text, "Fallback.md").frontMatter.id)
    }

    @Test fun commentsFlowPresentationAndNestedOrderNormalizeWithoutChangingBody() {
        val body = "\uFEFF  é e\u0301 🐾\r\n\t尾\r\n\r\n"
        val source = "---\r\n# discarded\r\nx: {z: [a, b], a: {second: 2, first: 1}}\r\ntitle: 'Exact'\r\n---\r\n$body"
        roundTrip(PromptCodec.parse(source, "Fallback.md"),
            "---\ntitle: Exact\nx:\n  z:\n  - a\n  - b\n  a:\n    second: 2\n    first: 1\n---\n$body")
    }

    @Test fun compositeKeysAndNestedCollectionsMatchBlockPresentation() {
        val header = "x:\n  ? {z: [a, b], a: value}\n  : [[a, b], {z: 2, a: 1}]\n  ? []\n  : {}\n  ? {}\n  : []"
        roundTrip(read(header), "---\nx:\n  ? z:\n    - a\n    - b\n    a: value\n  : - - a\n      - b\n    - z: 2\n      a: 1\n  []: {}\n  {}: []\n---\nBody")
    }

    @Test fun portableStringsUseLibyamlQuotingAndUppercaseEscapes() {
        val values = linkedMapOf(
            "" to "\"\"", "-" to "'-'", "a: b" to "'a: b'", "# leading" to "'# leading'",
            " leading" to "' leading'", "trailing " to "'trailing '", "a # b" to "'a # b'",
            "'single'" to "'''single'''", "\"double\"" to "'\"double\"'", "---ish" to "'---ish'",
            "a:b" to "a:b", ":b" to ":b", "?b" to "?b", "\\backslash" to "\\backslash",
            "🐾" to "\"\\U0001F43E\"", "a\uFEFFb" to "\"a\\uFEFFb\"",
            "a\u0000\u0007\b\t\n\u000B\u000C\r\u001B\u0085\u00A0\u2028\u2029\uFEFF\uFFFE\uFFFF" to
                "\"a\\0\\a\\b\\t\\n\\v\\f\\r\\e\\N\u00A0\\L\\P\\uFEFF\\uFFFE\\uFFFF\"",
        )
        for ((value, presentation) in values) {
            val header = YamlNode.Mapping(listOf(YamlNode.Entry(YamlNode.Scalar("x", YamlTag.STR), YamlNode.Scalar(value, YamlTag.STR))))
            val document = PromptDocument("", "Body", FrontMatter("Fallback"), Template.parse("Body"), preservedHeader = header)
            roundTrip(document, "---\nx: $presentation\n---\nBody")
        }
    }

    @Test fun longUnicodeKeysUseUtf8ByteLengthAndTheInclusive128ByteLimit() {
        for (key in listOf("a".repeat(128), "a".repeat(129), "é".repeat(64), "é".repeat(65), "🐾".repeat(33))) {
            val header = YamlNode.Mapping(listOf(YamlNode.Entry(YamlNode.Scalar(key, YamlTag.STR), YamlNode.Scalar("value", YamlTag.STR))))
            val document = PromptDocument("", "Body", FrontMatter("Fallback"), Template.parse("Body"), preservedHeader = header)
            val renderedKey = if (key.startsWith("🐾")) "\"" + "\\U0001F43E".repeat(33) + "\"" else key
            val expected = if (key.toByteArray().size <= 128) "$renderedKey: value" else "? $renderedKey\n: value"
            roundTrip(document, "---\n$expected\n---\nBody")
        }
    }

    @Test fun unicodeBreakPresentationAndScalarKeyBoundaryStayExact() {
        for ((value, expected) in mapOf(
            "first\u0085second" to "\"first\\Nsecond\"",
            "first\u2028second" to "'first\u2028  second'",
            "first\u2029second" to "'first\u2029  second'",
            "first\u2028 second" to "\"first\\L second\"",
            "first \u2029second" to "\"first \\Psecond\"",
        )) {
            val header = YamlNode.Mapping(listOf(YamlNode.Entry(YamlNode.Scalar("x", YamlTag.STR), YamlNode.Scalar(value, YamlTag.STR))))
            roundTrip(PromptDocument("", "Body", FrontMatter("Fallback"), Template.parse("Body"), preservedHeader = header),
                "---\nx: $expected\n---\nBody")
        }
        roundTrip(read("? \"a\\nb\"\n: value"), "---\n? \"a\\nb\"\n: value\n---\nBody")
    }

    @Test fun escapedDescriptionBreaksMatchSwiftBytesAndRetainTheirValues() {
        // Swift's writer keeps isolated LS/PS literal, including continuation indentation.
        val cases = listOf(
            Triple("a\\nb", "a\nb", "\"a\\nb\""),
            Triple("a\\rb", "a\rb", "\"a\\rb\""),
            Triple("a\\Nb", "a\u0085b", "\"a\\Nb\""),
            Triple("a\\Lb", "a\u2028b", "'a\u2028  b'"),
            Triple("a\\Pb", "a\u2029b", "'a\u2029  b'"),
            Triple("\\La", "\u2028a", "'\u2028  a'"),
            Triple("a\\L", "a\u2028", "'a\u2028  '"),
            Triple("a\\L\\Lb", "a\u2028\u2028b", "'a\u2028\u2028  b'"),
            Triple("\\Pa", "\u2029a", "'\u2029  a'"),
            Triple("a\\P", "a\u2029", "'a\u2029  '"),
            Triple("a\\P\\Pb", "a\u2029\u2029b", "'a\u2029\u2029  b'"),
            Triple("a'\\Lb", "a'\u2028b", "'a''\u2028  b'"),
            Triple("a\\L b", "a\u2028 b", "\"a\\L b\""),
            Triple("a \\Pb", "a \u2029b", "\"a \\Pb\""),
        )
        for ((escaped, value, presentation) in cases) {
            val document = read("description: \"$escaped\"", "Body\r\n")
            assertTrue(document.issues.isEmpty(), escaped)
            assertEquals(value, document.frontMatter.description, escaped)
            val expected = "---\ndescription: $presentation\n---\nBody\r\n"
            assertContentEquals(expected.toByteArray(Charsets.UTF_8), PromptCodec.write(document).toByteArray(Charsets.UTF_8), escaped)
            roundTrip(document, expected)
        }
    }

    @Test fun scalarSpellingsBeforeFinalUnicodeBreaksUseSwiftSensitiveQuoting() {
        for ((escape, br) in listOf("L" to '\u2028', "P" to '\u2029')) {
            for (base in listOf("", "true", "false", "null", "~", "1", "2.5", ".inf", "yes", "2026-10-13", "=", "<<")) {
                val document = read("description: \"$base\\$escape\"")
                assertEquals(base + br, document.frontMatter.description)
                roundTrip(document, "---\ndescription: \"$base\\$escape\"\n---\nBody")
            }
        }
    }

    @Test fun explicitNumericScalarsWithFinalBreaksMatchSwiftSingleAndDoubleQuotes() {
        for ((tag, base) in listOf("int" to "1", "float" to "2.5")) {
            for ((escape, br, presentation) in listOf(
                Triple("n", "\n", "'$base\n\n  '"),
                Triple("r", "\r", "\"$base\\r\""),
                Triple("N", "\u0085", "\"$base\\N\""),
                Triple("L", "\u2028", "'$base\u2028  '"),
                Triple("P", "\u2029", "'$base\u2029  '"),
            )) {
                val document = read("x: !!$tag \"$base\\$escape\"")
                assertTrue(document.issues.isEmpty(), "$tag/$escape")
                val expected = "---\nx: $presentation\n---\nBody"
                val written = PromptCodec.write(document)
                assertContentEquals(expected.toByteArray(Charsets.UTF_8), written.toByteArray(Charsets.UTF_8), "$tag/$escape")
                val reread = PromptCodec.parse(written, "Fallback.md")
                assertEquals(base + br, PortableYaml.string(reread.preservedHeader!!.entries.single().value), "$tag/$escape")
            }
        }
    }

    @Test fun finalBreaksRetainSwiftExplicitNullAndBooleanValidation() {
        for (escape in listOf("n", "r", "N", "L", "P")) {
            val document = read("x: !!null \"null\\$escape\"")
            assertTrue(document.issues.isEmpty(), escape)
            assertEquals("---\nx: null\n---\nBody", PromptCodec.write(document), escape)
            assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> {
                PromptCodec.write(read("x: !!bool \"true\\$escape\""))
            }, escape)
            assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> {
                PromptCodec.write(read("x: !!int \"1\\${escape}2\""))
            }, escape)
        }
    }

    @Test fun explicitTagsRetainTypesAndHugeFloatsWithoutDoubleRounding() {
        val header = "format: 0x1\nx: [!!int '10', !!float -0, !!float -.5, !!float .5e999999999999999999999, !!null '~', !!str 'true']"
        roundTrip(read(header), "---\nformat: 1\nx:\n- 10\n- -0.0\n- -5e-1\n- 5e999999999999999999998\n- null\n- \"true\"\n---\nBody")
    }

    @Test fun writerRefusesInvalidAndFutureContentWithoutExposingSource() {
        for (source in listOf("---\nx: [sensitive_marker\n---\nBody", "---\nprivate: on\n---\nBody", "{{unclosed")) {
            val error = assertFailsWith<PromptWriteError> { PromptCodec.write(PromptCodec.parse(source, "sensitive_filename.md")) }
            assertEquals(PromptWriteError.InvalidPrompt, error)
            assertFalse(error.toString().contains("sensitive"))
            assertNull(error.cause)
        }
        val future = read("format: 999999999999999999999999999\nprivate: on")
        assertEquals(PromptWriteError.UnsupportedFormat(future.frontMatter.format),
            assertFailsWith<PromptWriteError> { PromptCodec.write(future) })
    }

    @Test fun sourceAndCanonicalOutputHaveSeparateSizeChecksAndNoWrapping() {
        // Swift rejects reader errors first; only expansion of valid input uses SourceTooLarge.
        assertEquals("a".repeat(Limits.maxPromptBytes), PromptCodec.write(PromptCodec.parse("a".repeat(Limits.maxPromptBytes), "x.md")))
        assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> {
            PromptCodec.write(PromptCodec.parse("a".repeat(Limits.maxPromptBytes + 1), "x.md"))
        })
        val header = "---\nx: [a, b, c]\n---\n"
        val exact = PromptCodec.parse(header + "a".repeat(Limits.maxPromptBytes - header.toByteArray().size), "x.md")
        assertEquals(PromptWriteError.SourceTooLarge, assertFailsWith<PromptWriteError> { PromptCodec.write(exact) })
        val line = "a ".repeat(2000) + "z"
        val written = PromptCodec.write(read("x: '$line'"))
        assertTrue(written.contains("x: $line\n"))
    }

    @Test fun deeplyNestedOutputAndUnicodeContinuationExpansionFailAtTheCap() {
        val nested = read("x: " + "{nested: ".repeat(1000) + "value" + "}".repeat(1000))
        assertTrue(nested.issues.isEmpty())
        assertEquals(PromptWriteError.SourceTooLarge, assertFailsWith<PromptWriteError> { PromptCodec.write(nested) })
        val node = YamlNode.Scalar("a\u2028".repeat(4000), YamlTag.STR)
        val header = (1..100).fold<Int, YamlNode>(node) { value, _ ->
            YamlNode.Mapping(listOf(YamlNode.Entry(YamlNode.Scalar("x", YamlTag.STR), value)))
        } as YamlNode.Mapping
        val document = PromptDocument("", "Body", FrontMatter("Fallback"), Template.parse("Body"), preservedHeader = header)
        assertEquals(PromptWriteError.SourceTooLarge, assertFailsWith<PromptWriteError> { PromptCodec.write(document) })
    }
}
