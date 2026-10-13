package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Expectations independently verified with the Swift 6.4 reference probe for K10. */
class SwiftParityEdgeTest {
    private fun parse(source: String) = PromptCodec.parse(source, "Probe.md")

    @Test
    fun `bare zero octal keys compare as decimal and binary keys retain Swift rejection`() {
        for ((source, column) in listOf("extension: {0o17: a, 15: b}" to 22, "extension: {0o0: a, 0: b}" to 21)) {
            val document = parse("---\n$source\n---\n")
            assertEquals(listOf(PromptIssue(PromptIssueCode.DUPLICATE_KEY, PromptIssueLocation.FrontMatter(2, column))), document.issues)
            assertFalse(document.canRender)
        }
        // Swift rejects 0b1 before writing but does not equate it with 1 for duplicate diagnostics.
        val binary = parse("---\nextension: {0b1: a, 1: b}\n---\n")
        assertEquals(listOf(PromptIssue(PromptIssueCode.NON_PORTABLE_SCALAR, PromptIssueLocation.FrontMatter(2, 13))), binary.issues)
        assertFalse(binary.canRender)
    }

    @Test
    fun `present null booleans emit issues and use fail closed values`() {
        val document = parse("---\nfavorite: null\nprivate: null\nfields: {x: {optional: null, remember: null}}\n---\n{{x}}")
        assertEquals(listOf(
            PromptIssue(PromptIssueCode.INVALID_METADATA_TYPE, PromptIssueLocation.FrontMatter(2, 11)),
            PromptIssue(PromptIssueCode.INVALID_METADATA_TYPE, PromptIssueLocation.FrontMatter(3, 10)),
            PromptIssue(PromptIssueCode.INVALID_FIELD_BOOLEAN, PromptIssueLocation.FrontMatter(4, 24)),
            PromptIssue(PromptIssueCode.INVALID_FIELD_BOOLEAN, PromptIssueLocation.FrontMatter(4, 40)),
        ), document.issues)
        assertFalse(document.frontMatter.favorite)
        assertTrue(document.frontMatter.isPrivate)
        assertFalse(document.frontMatter.fields.single().optional)
        assertFalse(document.frontMatter.fields.single().remember)
        assertFalse(document.canRender)
    }

    @Test
    fun `rendered output can exceed the source cap as in Swift`() {
        val document = parse("{{x}}{{x}}")
        val value = "a".repeat(Limits.maxPromptBytes + 1)
        val rendered = PromptRenderer.render(document, mapOf("x" to value))
        assertEquals(value + value, rendered)
        assertEquals(524_290, rendered.toByteArray(Charsets.UTF_8).size)
    }

    @Test
    fun `repeated undeclared deferred names produce one issue per distinct first use`() {
        val document = parse("é {{uuid}} {{uuid}} {{selection}} {{uuid}} {{selection}}")
        assertEquals(listOf("uuid", "selection"), document.template.names)
        assertEquals(emptyList(), document.effectiveFields)
        assertEquals(listOf(
            PromptIssue(PromptIssueCode.RESERVED_FIELD_NAME, PromptIssueLocation.Body(3)),
            PromptIssue(PromptIssueCode.RESERVED_FIELD_NAME, PromptIssueLocation.Body(21)),
        ), document.issues)
    }
}
