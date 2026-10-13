package ch.lkmc.monkeyspaw.core.domain.format

import java.math.BigInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PromptCodecTest {
    private fun read(header: String, body: String = "Body") = PromptCodec.parse("---\n$header\n---\n$body", "Fallback.md")
    private fun codes(document: ParsedPrompt) = document.decodingIssues.map { it.code }

    @Test fun invalidUtf8IsNeverRepairedAndSizeWinsBeforeDecode() {
        val invalid = listOf(byteArrayOf(0x80.toByte()), byteArrayOf(0xc0.toByte(), 0xaf.toByte()),
            byteArrayOf(0xe2.toByte(), 0x82.toByte()), byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()),
            byteArrayOf(0xf4.toByte(), 0x90.toByte(), 0x80.toByte(), 0x80.toByte()))
        for (bytes in invalid) {
            val document = PromptCodec.parseFile(bytes, "Fallback.md")
            assertEquals(listOf(PromptIssueCode.INVALID_UTF8), codes(document))
            assertEquals("", document.source)
            assertEquals("", document.body)
            assertTrue(document.frontMatter.isPrivate)
        }
        val oversized = ByteArray(PromptCodec.maxSourceBytes + 1) { 0x80.toByte() }
        assertEquals(listOf(PromptIssueCode.SOURCE_TOO_LARGE), codes(PromptCodec.parseFile(oversized, "Fallback.md")))
        val replacement = PromptCodec.parseFile("\uFFFD".toByteArray(), "Fallback.md")
        assertEquals("\uFFFD", replacement.body)
        assertTrue(replacement.decodingIssues.isEmpty())
    }

    @Test fun bomRemainsBodyDataAndRoundTripsWithoutStripping() {
        for (source in listOf("\uFEFF", "\uFEFF---\ntitle: Hidden\n---\nBody", "\uFEFF\uFEFFBody")) {
            val document = PromptCodec.parseFile(source.toByteArray(), "Fallback.md")
            assertEquals(source, document.source)
            assertEquals(source, document.body)
            assertEquals("Fallback", document.frontMatter.title)
            assertNull(document.preservedHeader)
            assertTrue(document.decodingIssues.isEmpty())
        }
        assertEquals("\uFEFFBody", read("title: Present", "\uFEFFBody").body)
        assertEquals(listOf(PromptIssueCode.INVALID_UTF8), codes(PromptCodec.parseFile(
            byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte(), 0x80.toByte()), "Fallback.md")))
    }

    @Test fun delimiterRulesPreserveExactBodyAndSource() {
        for (newline in listOf("\n", "\r\n")) {
            val body = "  e\u0301 🐒\r\nend\r"
            val source = "---${newline}title: Present${newline}---${newline}$body"
            val document = PromptCodec.parse(source, "Fallback.md")
            assertEquals(source, document.source)
            assertEquals(body, document.body)
            assertEquals("Present", document.frontMatter.title)
            assertTrue(document.decodingIssues.isEmpty())
            assertEquals("", PromptCodec.parse("---${newline}---", "Fallback.md").body)
        }
        for (source in listOf("---\rtitle: Value\r---\rBody", " ---\nBody", "--- \nBody", "\n---\nBody")) {
            assertEquals(source, PromptCodec.parse(source, "Fallback.md").body)
        }
        val unclosed = PromptCodec.parse("---\nprivate: false\n--- \nBody", "Fallback.md")
        assertEquals("private: false\n--- \nBody", unclosed.body)
        assertEquals(listOf(PromptIssueCode.UNCLOSED_FRONT_MATTER), codes(unclosed))
        assertTrue(unclosed.frontMatter.isPrivate)
        assertEquals("", PromptCodec.parse("---", "Fallback.md").body)
        // A lone CR inside the YAML header is a YAML line break, but never a delimiter terminator.
        assertEquals("Value", read("title: Value\rprivate: false").frontMatter.title)
    }

    @Test fun emptyHeadersAreMapsButExplicitNullAndOtherRootsFailClosed() {
        for (header in listOf("", "# comment", "{}", "!!null ''")) {
            val document = read(header)
            assertNotNull(document.preservedHeader)
            assertTrue(document.decodingIssues.isEmpty())
            assertFalse(document.frontMatter.isPrivate)
        }
        for (header in listOf("null", "~", "[one, two]", "literal")) {
            val document = read(header)
            assertEquals(listOf(PromptIssueCode.FRONT_MATTER_NOT_MAPPING), codes(document))
            assertTrue(document.frontMatter.isPrivate)
        }
        val multiple = read("title: First\n...\n--- second")
        assertEquals(listOf(PromptIssueCode.INVALID_YAML), codes(multiple))
        assertEquals("Fallback", multiple.frontMatter.title)
        assertTrue(multiple.frontMatter.isPrivate)
    }

    @Test fun yamlVersionDirectivesAcceptOnlySwiftSupportedVersions() {
        for (version in listOf("1.1", "1.2")) {
            val document = read("%YAML $version\n--- {title: Retained}")
            assertTrue(document.decodingIssues.isEmpty())
            assertEquals("Retained", document.frontMatter.title)
        }
        for (version in listOf("1.0", "1.3", "2.0")) {
            val document = read("%YAML $version\n--- {title: Lost, private: false}")
            assertEquals(listOf(PromptIssueCode.INVALID_YAML), codes(document))
            assertTrue(document.frontMatter.isPrivate)
            assertEquals(PromptIssueLocation.FrontMatter(2, 1), document.decodingIssues.single().location)
        }
    }

    @Test fun forbiddenScalarsAndTagsRemainLiteralOnlyWhenStrings() {
        val forbidden = listOf("y", "Y", "yEs", "n", "yes", "NO", "On", "off", "True", "FALSE",
            "010", "08", "09", "+010", "-010", "0b10", "+0x10", "-0o10", "1_000", "1.2_3",
            "1:20", "1:20.5", "2026-10-09", "2026-10-09T12:00:00Z", "=", "<<", "-.5", ".5e3")
        for (scalar in forbidden) {
            assertEquals(listOf(PromptIssueCode.NON_PORTABLE_SCALAR), codes(read("x: $scalar")), scalar)
            for (literal in listOf("'$scalar'", "\"$scalar\"", "!!str $scalar", "! $scalar")) {
                assertTrue(read("x: $literal").decodingIssues.isEmpty(), literal)
            }
        }
        for (tag in listOf("!!timestamp 2026-10-09", "!!binary SGVsbG8=", "!custom value", "!!set {a: null}")) {
            assertEquals(listOf(PromptIssueCode.NON_PORTABLE_TAG), codes(read("x: $tag")), tag)
        }
        assertEquals(listOf(PromptIssueCode.MERGE_KEY), codes(read("<<: {x: value}")))
        assertEquals(listOf(PromptIssueCode.NON_PORTABLE_SCALAR), codes(read("x: !!bool YES")))
        assertTrue(read("x: !!float .5e3\ninteger: !!int '10'\nz: !!seq [true, false]\nm: !!map {a: !!str on}").decodingIssues.isEmpty())
        assertTrue(read("x: |\n  on\n  &anchor *alias\nfolded: >\n  010\n  yes").decodingIssues.isEmpty())
        assertTrue(read("x: [-+01, ++01, 0X10, 0O10]").decodingIssues.isEmpty())
    }

    @Test fun anchorsRetainSiblingsButUndefinedAndRecursiveAliasesDiscardHeaders() {
        for (rejected in listOf("x: &a value\nother: *a", "x: &a [value]\nother: *a", "x: &a {key: value}\nother: *a")) {
            val document = read("title: Retained\nprivate: false\n$rejected")
            assertEquals(listOf(PromptIssueCode.ANCHOR_OR_ALIAS, PromptIssueCode.ANCHOR_OR_ALIAS), codes(document))
            assertEquals("Retained", document.frontMatter.title)
            assertFalse(document.frontMatter.isPrivate)
            assertEquals(document.decodingIssues[0].location, document.decodingIssues[1].location)
        }
        val keyed = read("title: Retained\nprivate: false\n? &a title\n: rejected")
        assertEquals(listOf(PromptIssueCode.ANCHOR_OR_ALIAS), codes(keyed))
        assertEquals("Retained", keyed.frontMatter.title)
        assertEquals(PromptIssueLocation.FrontMatter(4, 3), keyed.decodingIssues[0].location)
        for (header in listOf("x: *missing", "x: &a [*a]", "x: &a {? *a : value}")) {
            val document = read("title: Lost\nprivate: false\n$header")
            assertEquals(listOf(PromptIssueCode.INVALID_YAML), codes(document))
            assertEquals("Fallback", document.frontMatter.title)
            assertTrue(document.frontMatter.isPrivate)
        }
        assertTrue(read("x: '*literal &literal'\nother: middle&anchor middle*alias").decodingIssues.isEmpty())
    }

    @Test(timeout = 10000) fun nestedAliasKeysAreRejectedWithoutExpansion() {
        val depth = 128
        val header = buildString {
            append("title: Retained\nprivate: false\nseed: &n0 [value]\n")
            for (index in 1..depth) append("level$index: &n$index [*n${index - 1}, *n${index - 1}]\n")
        }
        for (key in listOf("[*n128]", "{? *n128 : value}", "{nested: *n128}", "[{nested: [*n128]}]")) {
            val document = read("$header? $key\n: rejected", "  🐒 {{topic}}\r\n")
            assertEquals(List(depth + 2) { PromptIssueCode.ANCHOR_OR_ALIAS }, codes(document))
            assertEquals("Retained", document.frontMatter.title)
            assertFalse(document.frontMatter.isPrivate)
            assertEquals("  🐒 {{topic}}\r\n", document.body)
        }
    }

    @Test fun syntaxAndTypedDuplicatesHaveDistinctRecovery() {
        for (header in listOf("x: first\nx: second", "x: &a {k: first, k: second}", "x: &a value\nk: first\nk: second")) {
            val document = read("title: Lost\nprivate: false\n$header")
            assertEquals(listOf(PromptIssueCode.DUPLICATE_KEY), codes(document))
            assertEquals("Fallback", document.frontMatter.title)
            assertTrue(document.frontMatter.isPrivate)
            assertNull(document.preservedHeader)
        }
        for (header in listOf("1: first\n+1: second", "0x10: first\n0o20: second", "1.0: first\n!!float 1: second",
            "null: first\n~: second", "a: first\n'a': second", "? {a: 1, b: 2}\n: first\n? {b: +2, a: +1}\n: second")) {
            val document = read("title: Retained\nprivate: false\n$header")
            assertEquals(listOf(PromptIssueCode.DUPLICATE_KEY), codes(document), header)
            assertEquals("Retained", document.frontMatter.title)
            assertFalse(document.frontMatter.isPrivate)
            assertNotNull(document.preservedHeader)
        }
        val ambiguous = read("private: false\n'private': true\nfields: {x: {optional: true, 'optional': false, remember: true, 'remember': false}}")
        assertEquals(List(3) { PromptIssueCode.DUPLICATE_KEY }, codes(ambiguous))
        assertTrue(ambiguous.frontMatter.isPrivate)
        assertFalse(ambiguous.frontMatter.fields.single().optional)
        assertFalse(ambiguous.frontMatter.fields.single().remember)
        assertTrue(read("1: integer\n1.0: float\n'1': string\n? [1, 2]\n: sequence\n? {a: 1}\n: mapping").decodingIssues.isEmpty())
    }

    @Test fun exactFloatIdentityPreservesPrecisionAndHugeExponents() {
        assertTrue(read("1.0000000000000001: a\n1.0000000000000002: b\n1e9999: c\n2e9999: d").decodingIssues.isEmpty())
        for (keys in listOf("1.00: a\n!!float 1: b", "-0.0: a\n0.0: b", ".NaN: a\n.nan: b", "1e999999999999999999999999: a\n10e999999999999999999999998: b")) {
            assertEquals(listOf(PromptIssueCode.DUPLICATE_KEY), codes(read(keys)), keys)
        }
        assertEquals(listOf(PromptIssueCode.NON_PORTABLE_SCALAR), codes(read("!!float invalid: value")))
    }

    @Test fun syntaxDuplicateLocationUsesSwiftKeyOrdering() {
        val document = read("? [z]\n: first\n? [aa]\n: first\n? [z]\n: second\n? [aa]\n: second")
        assertEquals(listOf(PromptIssueCode.DUPLICATE_KEY), codes(document))
        assertEquals(PromptIssueLocation.FrontMatter(4, 3), document.decodingIssues.single().location)
        assertTrue(document.frontMatter.isPrivate)
    }

    @Test(timeout = 20000) fun hugeRadixVersionsAndKeysHaveNoMachineWordCeiling() {
        val digits = PromptCodec.maxSourceBytes - 256
        for ((prefix, digit, bits) in listOf(Triple("0x", 'f', 4), Triple("0o", '7', 3))) {
            val document = read("format: $prefix${digit.toString().repeat(digits)}")
            val expected = BigInteger.ONE.shiftLeft(digits * bits).subtract(BigInteger.ONE).toString()
            assertEquals(expected, document.frontMatter.format.decimalValue)
            assertEquals(listOf(PromptIssueCode.UNSUPPORTED_FORMAT), codes(document))
            assertTrue(document.isReadOnly)
            assertTrue(read("format: $prefix${"0".repeat(digits - 1)}1").decodingIssues.isEmpty())
        }
        val hex = "0x" + "f".repeat(2000)
        val decimal = BigInteger(hex.substring(2), 16).toString()
        assertEquals(listOf(PromptIssueCode.DUPLICATE_KEY), codes(read("? $hex\n: a\n? +$decimal\n: b")))
    }

    @Test fun sourceByteCapPrecedesYamlAndPreservesTextRecovery() {
        val exact = "x".repeat(PromptCodec.maxSourceBytes)
        assertTrue(PromptCodec.parse(exact, "Fallback.md").decodingIssues.isEmpty())
        for (source in listOf(exact + "x", "é".repeat(PromptCodec.maxSourceBytes / 2 + 1), "---\nx: [broken\n" + exact)) {
            val text = PromptCodec.parse(source, "Fallback.md")
            assertEquals(listOf(PromptIssueCode.SOURCE_TOO_LARGE), codes(text))
            assertEquals(source, text.source)
            assertEquals(source, text.body)
            assertTrue(text.frontMatter.isPrivate)
            assertEquals("", PromptCodec.parseFile(source.toByteArray(), "Fallback.md").body)
        }
    }

    @Test(timeout = 10000) fun deeplyNestedLiteralValuesDoNotUseRecursiveJvmTraversal() {
        val depth = 10000
        val document = read("x: ${"[".repeat(depth)}value${"]".repeat(depth)}")
        assertTrue(document.decodingIssues.isEmpty())
        assertEquals("Body", document.body)
    }

    @Test fun metadataOrderFallbackAndSafeDiagnosticLocations() {
        val document = read("id: 01k6z4v9kqwzx7mpq4t8znb2pd\ntitle: 1\ndescription: false\ntags: [good, 1]\nprivate: on\nformat: 0\nfields: {x: {type: future, label: 1, optional: yes, remember: 'true'}}")
        assertEquals("01K6Z4V9KQWZX7MPQ4T8ZNB2PD", document.frontMatter.id)
        assertEquals("Fallback", document.frontMatter.title)
        assertEquals(listOf("good"), document.frontMatter.tags)
        assertEquals(listOf(PromptIssueCode.NON_PORTABLE_SCALAR, PromptIssueCode.NON_PORTABLE_SCALAR,
            PromptIssueCode.INVALID_METADATA_TYPE, PromptIssueCode.INVALID_METADATA_TYPE, PromptIssueCode.INVALID_METADATA_TYPE,
            PromptIssueCode.INVALID_METADATA_TYPE, PromptIssueCode.INVALID_FORMAT, PromptIssueCode.UNKNOWN_FIELD_TYPE,
            PromptIssueCode.INVALID_FIELD_PROPERTY, PromptIssueCode.INVALID_FIELD_BOOLEAN, PromptIssueCode.INVALID_FIELD_BOOLEAN), codes(document))
        val location = PromptCodec.parse("---\r\nprivate: on\r\n---\r\nBody", "sensitive_filename.md")
        assertEquals(PromptIssueLocation.FrontMatter(2, 10), location.decodingIssues.first().location)
        val scalarColumn = read("x: {\"🐒\": on}")
        assertEquals(PromptIssueLocation.FrontMatter(2, 10), scalarColumn.decodingIssues.first().location)
        for (issue in document.decodingIssues + location.decodingIssues) {
            assertFalse(issue.message.contains("sensitive_filename"))
            assertFalse(issue.message.contains("private: on"))
        }
    }

    @Test fun choiceDefaultsUseSwiftCanonicalEqualityWithoutChangingStoredText() {
        val document = read("fields: {x: {type: choice, options: [é], default: \"e\\u0301\"}}", "{{x}}")
        assertTrue(document.decodingIssues.isEmpty())
        val field = document.frontMatter.fields.single()
        assertEquals("e\u0301", field.defaultValue)
        assertEquals("é", field.options.single().value)
    }

    @Test fun unicodeYamlBreaksSeparateMetadataWithoutChangingSourceOrBody() {
        for (separator in listOf('\u0085', '\u2028', '\u2029')) {
            val body = "Body${separator}exact"
            val header = "title: Retained${separator}private: false"
            val document = read(header, body)
            assertTrue(document.decodingIssues.isEmpty(), separator.code.toString())
            assertEquals("Retained", document.frontMatter.title)
            assertFalse(document.frontMatter.isPrivate)
            assertEquals(body, document.body)
            assertEquals("---\n$header\n---\n$body", document.source)
            assertEquals(listOf(PromptIssueCode.INVALID_YAML), codes(read("title: a${separator}b")))
        }
    }

    @Test fun unicodeYamlBreaksKeepScalarMeaningAcrossEveryStyle() {
        for (separator in listOf('\u0085', '\u2028', '\u2029')) {
            val expected = if (separator == '\u0085') "first second" else "first${separator}second"
            for (value in listOf("first${separator}  second", "'first${separator}  second'", "\"first${separator}  second\"")) {
                assertEquals(expected, read("title: $value").frontMatter.title, value)
            }
            val literal = if (separator == '\u0085') "first\nsecond" else "first${separator}second"
            assertEquals(literal, read("title: |-\n  first${separator}  second").frontMatter.title)
            assertEquals(expected, read("title: >-\n  first${separator}  second").frontMatter.title)
            val keep = if (separator == '\u0085') '\n' else separator
            assertEquals("first${keep}second\n$keep\n", read("title: |+\n  first${separator}  second\n$separator").frontMatter.title)
        }
    }

    @Test fun unicodeYamlMarksCountBreaksAndInteriorBomsAsSwiftDoes() {
        for (separator in listOf('\u0085', '\u2028', '\u2029')) {
            val document = read("title: Retained${separator}private: on")
            assertEquals(listOf(PromptIssueCode.NON_PORTABLE_SCALAR, PromptIssueCode.INVALID_METADATA_TYPE), codes(document))
            assertEquals(PromptIssueLocation.FrontMatter(3, 10), document.decodingIssues.first().location)
        }
        assertEquals(PromptIssueLocation.FrontMatter(2, 16), read("x: {a: '\uFEFF', b: on}").decodingIssues.single().location)
    }

    @Test fun adaptedQuotedEscapesAndRawBackslashesRemainDistinct() {
        val document = read("title: \"a\\L\\P\\u2028\\U0001F412\\x41\\N\\\\L\"\n" +
            "description: '\\L\\P'\ntags: [\\L, \\P]")
        assertTrue(document.decodingIssues.isEmpty())
        assertEquals("a\u2028\u2029\u2028🐒A\u0085\\L", document.frontMatter.title)
        assertEquals("\\L\\P", document.frontMatter.description)
        assertEquals(listOf("\\L", "\\P"), document.frontMatter.tags)
        val block = read("title: |-\n  \\L\\P\n  literal\u2028  last\n")
        assertEquals("\\L\\P\nliteral\u2028last", block.frontMatter.title)
    }

    @Test fun adaptedFoldingKeepsBlankLinesEscapedBreaksAndCompactIndentation() {
        for (separator in listOf('\u2028', '\u2029')) {
            assertEquals("a${separator}${separator}b", read("title: \"a${separator} ${separator}  b\"").frontMatter.title)
            assertEquals("ab", read("title: \"a\\${separator}  b\"").frontMatter.title)
            assertEquals("a${separator}  indented\nlast", read("title: >-\n  a${separator}    indented\n  last\n").frontMatter.title)
            val nested = read("fields:\n  x:\n    description: |2-\n      a${separator}      b\n", "{{x}}")
            assertEquals("a${separator}b", nested.frontMatter.fields.single().description)
            val compact = read("fields:\n  x:\n    type: choice\n    options:\n    - label: |2-\n        a${separator}        b\n      value: ab\n", "{{x}}")
            assertTrue(compact.decodingIssues.isEmpty())
            assertEquals("a${separator}b", compact.frontMatter.fields.single().options.single().label)
        }
    }

    @Test fun yamlEscapesCannotConstructInvalidUnicodeScalars() {
        for (escape in listOf("\\uD800", "\\uDFFF", "\\U0000D800", "\\uD83D\\uDC12", "\\U00110000")) {
            val document = read("title: Retained\nprivate: false\nx: \"$escape\"")
            assertEquals(listOf(PromptIssueCode.INVALID_YAML), codes(document), escape)
            assertEquals("Fallback", document.frontMatter.title)
            assertTrue(document.frontMatter.isPrivate)
            assertEquals("Body", document.body)
        }
        assertEquals("🐒", read("title: \"\\U0001F412\"").frontMatter.title)
    }

    @Test fun invalidAnchorNamesTakeSwiftSyntaxRecovery() {
        for (declaration in listOf("seed: &é value", "seed: &bad#name value", "seed: &é {key: value}")) {
            val document = read("title: Lost\nprivate: false\n$declaration")
            assertEquals(listOf(PromptIssueCode.INVALID_YAML), codes(document), declaration)
            assertEquals("Fallback", document.frontMatter.title)
            assertTrue(document.frontMatter.isPrivate)
        }
    }
}
