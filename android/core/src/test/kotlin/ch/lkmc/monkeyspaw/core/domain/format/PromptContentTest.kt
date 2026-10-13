package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PromptContentTest {
    private fun read(body: String, header: String? = null): PromptDocument =
        PromptCodec.parse(if (header == null) body else "---\n$header\n---\n$body", "Fallback.md")

    @Test fun multibyteLocationsAreBodyByteOffsetsAndRetainFirstUse() {
        val body = "é🐒e\u0301\r\n{{ a b }} {{uuid}} {{uuid}} {{unfinished"
        val document = read(body, "private: on\nfields: {unused: {}}")
        assertEquals(listOf(PromptIssueCode.NON_PORTABLE_SCALAR, PromptIssueCode.INVALID_METADATA_TYPE,
            PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNBALANCED_OPENER,
            PromptIssueCode.RESERVED_FIELD_NAME, PromptIssueCode.UNUSED_FIELD), document.issues.map { it.code })
        fun offset(text: String) = body.substring(0, body.indexOf(text)).toByteArray().size
        assertEquals(11, offset("{{ a b }}"))
        assertEquals(PromptIssueLocation.Body(11), document.issues[2].location)
        assertEquals(PromptIssueLocation.Body(offset("{{unfinished")), document.issues[3].location)
        assertEquals(PromptIssueLocation.Body(offset("{{uuid}}")), document.issues[4].location)
        assertEquals(PromptIssueLocation.FrontMatter(3, 10), document.issues[5].location)
        assertEquals(document.issues, PromptValidator.validate(document))
    }

    @Test fun asciiNamesAndOnlySpaceTabAreAcceptedRegardlessOfLocale() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            val document = read("{{ I }} {{i}} {{_a-9}} {{é}} {{𐐀}} {{\u00a0x}} {{x\n}} {{x y}} {{9x}}")
            assertEquals(listOf("I", "i", "_a-9"), document.template.names)
            assertEquals(List(6) { PromptIssueCode.INVALID_PLACEHOLDER }, document.issues.map { it.code })
            assertEquals(listOf("I", "i", "_a-9"), document.effectiveFields.map { it.name })
            assertTrue(document.canRender)
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test fun escapeConsumesExactlyOneBackslashAndNestedConstructUsesNextCloser() {
        val template = Template.parse("\\\\{{x}} {{outer {{inner}} tail {{ok}} \\{{")
        assertEquals(listOf(TemplateToken.Literal("\\"), TemplateToken.EscapedOpener,
            TemplateToken.Literal("x}} {{outer {{inner}} tail "), TemplateToken.Placeholder("ok"),
            TemplateToken.Literal(" "), TemplateToken.EscapedOpener), template.tokens)
        assertEquals(listOf("ok"), template.names)
        assertEquals(listOf(PromptIssue(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueLocation.Body(8))), template.issues)
    }

    @Test fun effectiveFieldsUseFirstBodyOrderAndExcludeBuiltinsAndDeferredNames() {
        val document = read("{{new}} {{b}} {{a}} {{b}} {{date}} {{uuid}} {{selection}}",
            "fields:\n  a: {type: multiline, label: A, optional: true, remember: false}\n  b: {}\n  unused: {}")
        assertEquals(listOf("a", "b", "unused"), document.frontMatter.fields.map { it.name })
        assertEquals(listOf("new", "b", "a"), document.effectiveFields.map { it.name })
        assertEquals(PromptField("new", isImplicit = true), document.effectiveFields[0])
        assertEquals(FieldKind.MULTILINE, document.effectiveFields[2].kind)
        assertEquals(listOf(BuiltinName.DATE), document.template.builtins)
        assertEquals(listOf(PromptIssueCode.RESERVED_FIELD_NAME, PromptIssueCode.RESERVED_FIELD_NAME,
            PromptIssueCode.UNUSED_FIELD), document.issues.map { it.code })
    }

    @Test fun suppliedEmptyOverridesDefaultAndRequiredValuesAreNotTrimmed() {
        val document = read("{{x}}", "fields: {x: {default: fallback}}")
        assertEquals("fallback", PromptRenderer.render(document))
        assertEquals(PromptRenderError.MissingRequiredValue("x"),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(document, mapOf("x" to "")) })
        for (whitespace in listOf(" ", "\t\n", "\u00a0")) {
            assertEquals(whitespace, PromptRenderer.render(document, mapOf("x" to whitespace)))
        }
        val optional = read("{{x}}", "fields: {x: {default: fallback, optional: true}}")
        assertEquals("", PromptRenderer.render(optional, mapOf("x" to "")))
    }

    @Test fun choiceValidatesMembershipAndAllowsEmptyOnlyWhenOptional() {
        val optional = read("{{x}}", "fields: {x: {type: choice, options: [allowed], optional: true}}")
        assertEquals("", PromptRenderer.render(optional))
        assertEquals("allowed", PromptRenderer.render(optional, mapOf("x" to "allowed")))
        for (value in listOf("ALLOWED", " allowed", " ", "forbidden")) {
            assertEquals(PromptRenderError.InvalidChoiceValue("x"),
                assertFailsWith<PromptRenderError> { PromptRenderer.render(optional, mapOf("x" to value)) })
        }
        val required = read("{{x}}", "fields: {x: {type: choice, options: [allowed]}}")
        assertEquals(PromptRenderError.MissingRequiredValue("x"),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(required) })
        val explicitEmptyDefault = read("{{x}}", "fields: {x: {type: choice, options: [allowed], default: '', optional: true}}")
        assertFalse(explicitEmptyDefault.canRender)
        assertEquals(PromptRenderError.InvalidPrompt,
            assertFailsWith<PromptRenderError> { PromptRenderer.render(explicitEmptyDefault) })
    }

    @Test fun choiceUsesSwiftCanonicalEqualityAndEmitsTheSuppliedSpelling() {
        val document = read("{{x}}", "fields: {x: {type: choice, options: ['é'], default: 'e\u0301'}}")
        assertTrue(document.issues.isEmpty())
        for (value in listOf("é", "e\u0301")) {
            assertContentEquals(value.toByteArray(), PromptRenderer.render(document, mapOf("x" to value)).toByteArray())
        }
        assertContentEquals("e\u0301".toByteArray(), PromptRenderer.render(document).toByteArray())
    }

    @Test fun missingBuiltinDiffersFromEmptyAndFieldValuesCannotOverrideIt() {
        val document = read("{{clipboard}}{{clipboard}}")
        assertEquals(listOf(BuiltinName.CLIPBOARD), document.template.builtins)
        assertTrue(document.effectiveFields.isEmpty())
        assertEquals(PromptRenderError.MissingBuiltin(BuiltinName.CLIPBOARD),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(document, mapOf("clipboard" to "override")) })
        assertEquals("", PromptRenderer.render(document, mapOf("clipboard" to "override"), PromptBuiltinValues(clipboard = "")))
        assertEquals("rawraw", PromptRenderer.render(document, builtins = PromptBuiltinValues(clipboard = "raw")))
    }

    @Test fun failuresFollowFormatValidationFieldAndBuiltinPrecedence() {
        val future = read("{{unfinished", "format: 99999999999999999999999999999999999999")
        assertEquals(PromptRenderError.UnsupportedFormat(future.frontMatter.format),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(future) })
        assertEquals(PromptRenderError.InvalidPrompt,
            assertFailsWith<PromptRenderError> { PromptRenderer.render(read("{{clipboard}} {{x}} {{unfinished")) })

        val fields = read("{{time}} {{b}} {{a}} {{clipboard}}",
            "fields: {a: {}, b: {type: choice, options: [valid]}}")
        assertEquals(PromptRenderError.InvalidChoiceValue("b"),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(fields, mapOf("b" to "bad")) })
        assertEquals(PromptRenderError.MissingRequiredValue("b"),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(fields) })
        assertEquals(PromptRenderError.MissingRequiredValue("a"),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(fields, mapOf("b" to "valid")) })
        assertEquals(PromptRenderError.MissingBuiltin(BuiltinName.TIME),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(fields, mapOf("b" to "valid", "a" to "filled")) })
    }

    @Test fun renderingIsRawSinglePassAcrossUnicodeBoundaries() {
        val document = read("e{{accent}}\r\n  {{x}} {{date}} \\{{x}}")
        val output = PromptRenderer.render(document, mapOf("accent" to "\u0301", "x" to "<raw>& {{date}}\n🐒"),
            PromptBuiltinValues(date = "{{x}}"))
        assertContentEquals("e\u0301\r\n  <raw>& {{date}}\n🐒 {{x}} {{x}}".toByteArray(), output.toByteArray())
    }

    @Test fun warningsRenderAndMalformedDeclarationsRemainVisible() {
        val warnings = read("{{#if x}}", "fields: {unused: {}}")
        assertEquals(listOf(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNUSED_FIELD), warnings.issues.map { it.code })
        assertTrue(warnings.canRender)
        assertEquals("{{#if x}}", PromptRenderer.render(warnings))
        val invalid = read("{{x}}", "fields: {x: {type: future}}")
        assertEquals(listOf("x"), invalid.effectiveFields.map { it.name })
        assertFalse(invalid.canRender)
    }

    @Test fun futureVersionPreservesSourceAndBodyButIsUndeliverable() {
        val version = "9".repeat(4000)
        val body = "  🐒\r\n{{topic}}"
        val source = "---\nformat: $version\nextension: {future: value}\n---\n$body"
        val document = PromptCodec.parse(source, "Future.md")
        assertContentEquals(source.toByteArray(), document.source.toByteArray())
        assertContentEquals(body.toByteArray(), document.body.toByteArray())
        assertEquals(version, document.frontMatter.format.decimalValue)
        assertTrue(document.isReadOnly)
        assertFalse(document.canRender)
        assertEquals(PromptRenderError.UnsupportedFormat(document.frontMatter.format),
            assertFailsWith<PromptRenderError> { PromptRenderer.render(document, mapOf("topic" to "filled")) })
    }

    @Test fun sourceBoundPreventsTemplateScanningAndDuplicateSizeErrors() {
        val source = "é".repeat(Limits.maxPromptBytes / 2) + "{{unfinished"
        val document = read(source)
        assertEquals(source, document.body)
        assertEquals(listOf(PromptIssueCode.SOURCE_TOO_LARGE), document.issues.map { it.code })
        assertTrue(document.template.tokens.isEmpty())
        assertTrue(document.effectiveFields.isEmpty())
        val standalone = Template.parse(source)
        assertEquals(listOf(TemplateToken.Literal(source)), standalone.tokens)
        assertEquals(listOf(PromptIssue(PromptIssueCode.SOURCE_TOO_LARGE)), standalone.issues)
        val exact = Template.parse("é".repeat(Limits.maxPromptBytes / 2))
        assertTrue(exact.issues.isEmpty())
    }

    @Test fun standaloneTemplateNeverRepairsMalformedUtf16IntoLiteralText() {
        for (body in listOf("\uD800{{x}}", "{{x}}\uDC00", "\uD800\uD800")) {
            val template = Template.parse(body)
            assertEquals(listOf(PromptIssue(PromptIssueCode.INVALID_UTF8)), template.issues)
            assertTrue(template.tokens.isEmpty())
            assertTrue(template.names.isEmpty())
            assertEquals(listOf(PromptIssueCode.INVALID_UTF8), read(body).issues.map { it.code })
        }
    }

    @Test fun diagnosticsAndTypedErrorsNeverDescribeSensitiveNamesOrValues() {
        val marker = "sensitive_marker_123"
        val required = read("{{$marker}}")
        val error = assertFailsWith<PromptRenderError> { PromptRenderer.render(required) }
        assertEquals(PromptRenderError.MissingRequiredValue(marker), error)
        assertFalse(error.toString().contains(marker))
        assertFalse(error.message.orEmpty().contains(marker))
        val invalid = read("{{$marker unfinished")
        assertFalse(invalid.issues.toString().contains(marker))
        val choice = read("{{x}}", "fields: {x: {type: choice, options: [allowed]}}")
        assertFalse(assertFailsWith<PromptRenderError> { PromptRenderer.render(choice, mapOf("x" to marker)) }
            .toString().contains(marker))
    }
}
