package ch.lkmc.monkeyspaw.core.format

import ch.lkmc.monkeyspaw.core.domain.format.*
import kotlin.test.*

internal class PromptFieldSettingsTest {
    private fun parse(source: String) = PromptCodec.parse(source, "a.md")
    private fun settings(document: PromptDocument) = assertNotNull(PromptCodec.fieldSettings(document)).first { it.name == "topic" }
    private fun edit(settings: PromptFieldSettings, document: PromptDocument) = PromptCodec.editingField(settings, document, "a.md")

    @Test fun `projection includes implicit and unused fields but not builtins and opening changes nothing`() {
        val source = "---\n# keep\nfields:\n  unused: {}\n---\n{{topic}} {{date}} {{topic}} {{clipboard}} {{time}}\r\n"
        val document = parse(source)
        assertEquals(listOf("topic", "unused"), PromptCodec.fieldSettings(document)?.map { it.name })
        val settings = settings(document)
        assertTrue(settings.isImplicit)
        assertNull(settings.defaultValue)
        assertEquals(source, edit(settings, document).source)
    }

    @Test fun `implicit settings become a declaration and drive rendering`() {
        val document = parse("{{topic}} / {{topic}}\r\n")
        val draft = settings(document).copy(kind = FieldKind.CHOICE, label = "A topic", description = "Pick one",
            defaultValue = "earth", optional = true, remember = false,
            options = listOf(PromptFieldOptionSettings("Earth", "earth"), PromptFieldOptionSettings("Literal", "{{other}}")))
        val changed = edit(draft, document)
        assertTrue(changed.canRender)
        assertEquals(1, changed.frontMatter.fields.size)
        val field = changed.effectiveFields.single()
        assertFalse(field.isImplicit)
        assertTrue(field.optional)
        assertFalse(field.remember)
        assertEquals("A topic", field.label)
        assertEquals("Pick one", field.description)
        assertEquals(document.body, changed.body)
        assertEquals("earth / earth\r\n", PromptRenderer.render(changed, emptyMap()))
        assertEquals("{{other}} / {{other}}\r\n", PromptRenderer.render(changed, mapOf("topic" to "{{other}}")))
    }

    @Test fun `changed properties preserve identity other declarations and retained option metadata`() {
        val document = parse("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\nprivate: true\nfields:\n  topic:\n    type: choice\n    hint: keep-field\n    options:\n    - {label: A, value: a, custom: keep-a}\n    - {label: B, value: b, custom: keep-b}\n    default: b\n  other: {label: Other, custom: keep-other}\nmodel: {provider: custom}\n---\n  {{topic}} {{other}} 👋 e\u0301\r\n")
        val current = settings(document)
        val draft = current.copy(options = listOf(current.options[1].copy(label = "Bee", value = "beta")),
            defaultValue = "beta", remember = false)
        val changed = edit(draft, document)
        assertEquals(document.frontMatter.id, changed.frontMatter.id)
        assertTrue(changed.frontMatter.isPrivate)
        assertEquals(document.frontMatter.fields.last(), changed.frontMatter.fields.last())
        assertEquals(document.body, changed.body)
        for (text in listOf("hint: keep-field", "custom: keep-b", "custom: keep-other", "provider: custom")) {
            assertTrue(text in changed.source, text)
        }
        assertFalse("keep-a" in changed.source)
        assertFalse("optional:" in changed.source)
        assertFalse("label: topic" in changed.source)
        assertEquals(listOf(FieldOption("Bee", "beta")), changed.effectiveFields.first().options)
    }

    @Test fun `choice validation distinguishes absent and empty defaults and switching type drops options`() {
        val document = parse("{{topic}}")
        var draft = settings(document).copy(kind = FieldKind.CHOICE)
        assertEquals(PromptFieldSettingsIssue.MISSING_OPTIONS, draft.validationIssue)
        assertFailsWith<PromptWriteError> { edit(draft, document) }
        draft = draft.copy(options = listOf(PromptFieldOptionSettings("Empty", "")), defaultValue = "no match")
        assertEquals(PromptFieldSettingsIssue.INVALID_DEFAULT, draft.validationIssue)
        assertFailsWith<PromptWriteError> { edit(draft, document) }
        draft = draft.copy(defaultValue = "")
        assertNull(draft.validationIssue)
        val choice = edit(draft, document)
        assertEquals("", settings(choice).defaultValue)
        val noDefault = edit(settings(choice).copy(defaultValue = null), choice)
        assertFalse("default:" in noDefault.source)
        val multiline = edit(settings(noDefault).copy(kind = FieldKind.MULTILINE, defaultValue = "First\nSecond"), noDefault)
        assertEquals(FieldKind.MULTILINE, multiline.effectiveFields.single().kind)
        assertEquals("First\nSecond", multiline.effectiveFields.single().defaultValue)
        assertFalse("options:" in multiline.source)
    }

    @Test fun `incomplete body stays repairable while bad headers and unknown fields fail closed`() {
        val draft = settings(parse("{{topic}}")).copy(label = "Topic")
        val changed = edit(draft, parse("{{topic}} {{"))
        assertNotNull(PromptCodec.fieldSettings(changed))
        assertTrue(changed.issues.any { it.code == PromptIssueCode.UNBALANCED_OPENER })
        assertFailsWith<PromptWriteError> { PromptCodec.write(changed) }
        for (source in listOf("No fields", "---\nformat: 2\n---\n{{topic}}", "---\nfields: [broken\n---\n{{topic}}")) {
            assertFailsWith<PromptWriteError> { edit(draft, parse(source)) }
        }
    }

    @Test fun `choice default uses the existing canonical equivalence rule`() {
        val document = parse("---\nfields:\n  topic: {type: choice, options: [é], default: e\u0301}\n---\n{{topic}}")
        assertTrue(document.canRender)
        val draft = settings(document).copy(label = "Topic")
        assertNull(draft.validationIssue)
        assertEquals("e\u0301", edit(draft, document).effectiveFields.single().defaultValue)
    }
}
