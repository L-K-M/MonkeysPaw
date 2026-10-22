package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptEdit
import ch.lkmc.monkeyspaw.core.domain.format.PromptForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PromptMutationsTest {
    private fun parse(source: String, filename: String = "Probe.md") = PromptCodec.parse(source, filename)
    private fun editing(edit: PromptEdit, source: String, filename: String = "Probe.md") =
        PromptMutations.editing(edit, parse(source, filename), filename)

    @Test fun `form projects editable metadata only`() {
        val form = PromptForm.of(parse("---\ntitle: T\ndescription: D\ntags: [a]\nprivate: true\n---\nBody text"))
        assertNotNull(form)
        assertEquals("T", form.title)
        assertEquals("D", form.description)
        assertEquals(listOf("a"), form.tags)
        assertTrue(form.isPrivate)
        assertEquals("Body text", form.body)

        val sparse = PromptForm.of(parse("---\ntitle: T\n---\nBody"))
        assertNotNull(sparse)
        assertEquals("", sparse.description)
        assertEquals(emptyList(), sparse.tags)
        assertFalse(sparse.isPrivate)
        assertEquals("Probe", PromptForm.of(parse("Plain body"))?.title)
    }

    @Test fun `metadata edits preserve identity format fields and unknown nested metadata`() {
        val source = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\ntitle: Old\nfavorite: true\n" +
            "fields:\n  topic:\n    type: choice\n    options: [a, b]\n    default: a\n" +
            "extension:\n  deep: {keep: [1, '2'], flag: false}\nz-last: 'quoted value'\nformat: 1\n" +
            "---\nBody {{topic}} tail"
        val document = parse(source)
        val changed = PromptMutations.editing(PromptEdit.Title("New"), document, "Probe.md")
        assertEquals("01K6Z4V9KQWZX7MPQ4T8ZNB2PD", changed.frontMatter.id?.rawValue)
        assertEquals("New", changed.frontMatter.title)
        assertTrue(changed.frontMatter.favorite)
        assertEquals(document.frontMatter.fields, changed.frontMatter.fields)
        assertEquals("Body {{topic}} tail", changed.body)

        val written = PromptCodec.write(changed)
        for (retained in listOf("id: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD", "extension:", "deep:", "z-last:", "format: 1")) {
            assertTrue(retained in written, retained)
        }
        assertEquals(changed.frontMatter, parse(written).frontMatter)
    }

    @Test fun `edits keep optional key presence and unknown key order`() {
        val tagged = editing(PromptEdit.Tags(listOf("one", "two")), "---\ntitle: T\ndescription: Keep\n---\nBody")
        assertEquals("Keep", tagged.frontMatter.description)
        assertTrue("description: Keep" in PromptCodec.write(tagged))

        val bare = editing(PromptEdit.Tags(listOf("one")), "---\ntitle: T\n---\nBody")
        assertNull(bare.frontMatter.description)
        assertFalse("description" in PromptCodec.write(bare))

        val added = editing(PromptEdit.Description("Added"), "---\ntitle: T\n---\nBody")
        assertEquals("Added", added.frontMatter.description)
        assertTrue("description: Added" in PromptCodec.write(added))

        val reordered = editing(PromptEdit.Title("New"), "---\nzeta: 1\ntitle: Old\nalpha: 2\n---\nBody")
        val written = PromptCodec.write(reordered)
        assertTrue(written.indexOf("zeta:") < written.indexOf("alpha:"), written)
    }

    @Test fun `unbalanced bodies stay editable and body edits repair the template`() {
        val source = "---\ntitle: T\n---\nUnclosed {{name and more"
        val document = parse(source)
        assertEquals(listOf(PromptIssueCode.UNBALANCED_OPENER), document.issues.map { it.code })
        assertNotNull(PromptForm.of(document))
        assertEquals(PromptWriteError.InvalidPrompt,
            assertFailsWith<PromptWriteError> { PromptCodec.write(document) })

        val renamed = PromptMutations.editing(PromptEdit.Title("Fixed"), document, "Probe.md")
        assertEquals("Fixed", renamed.frontMatter.title)
        assertEquals("Unclosed {{name and more", renamed.body)
        assertEquals(listOf(PromptIssueCode.UNBALANCED_OPENER), renamed.issues.map { it.code })
        assertEquals(PromptWriteError.InvalidPrompt,
            assertFailsWith<PromptWriteError> { PromptCodec.write(renamed) })

        val repaired = PromptMutations.editing(PromptEdit.Body("Closed {{name}}"), document, "Probe.md")
        assertEquals("Closed {{name}}", repaired.body)
        assertEquals("T", repaired.frontMatter.title)
        assertTrue(repaired.issues.isEmpty())
        PromptCodec.write(repaired)
    }

    @Test fun `body edits retain the exact raw header bytes`() {
        val source = "---\ntitle :  'Weird'\nx-custom  :  spaced\n---\nOld body"
        val changed = editing(PromptEdit.Body("New body"), source)
        assertEquals("---\ntitle :  'Weird'\nx-custom  :  spaced\n---\nNew body", changed.source)
        assertEquals("Weird", changed.frontMatter.title)
        assertEquals("New body", changed.body)
    }

    @Test fun `metadata edits retain the exact body bytes`() {
        val body = "first\r\n---\r\nstill body ---\r\n\u0085end"
        val changed = editing(PromptEdit.IsPrivate(true), "---\ntitle: T\n---\n$body")
        assertEquals(body, changed.body)
        assertEquals("---\ntitle: T\nprivate: true\n---\n$body", changed.source)
        assertEquals(body, parse(PromptCodec.write(changed)).body)
    }

    @Test fun `a closing delimiter at end of file keeps the header closed`() {
        val changed = editing(PromptEdit.Body("New body"), "---\ntitle: Kept\n---")
        assertEquals("---\ntitle: Kept\n---\nNew body", changed.source)
        assertEquals("Kept", changed.frontMatter.title)
        assertEquals("New body", changed.body)
        assertTrue(changed.decodingIssues.isEmpty())
    }

    @Test fun `plain bodies starting with a delimiter stay body bytes`() {
        for (replacement in listOf("---", "---\nplain", "---\r\nplain")) {
            val changed = editing(PromptEdit.Body(replacement), "Just text")
            assertEquals("---\n---\n$replacement", changed.source)
            assertEquals(replacement, changed.body, replacement)
            assertTrue(changed.decodingIssues.isEmpty(), replacement)
            assertEquals("Probe", changed.frontMatter.title)
        }
        // A retained header keeps a leading delimiter out of the YAML entirely.
        val headed = editing(PromptEdit.Body("---\nrest"), "---\ntitle: T\n---\nold")
        assertEquals("---\nrest", headed.body)
        assertEquals("T", headed.frontMatter.title)
    }

    @Test fun `malformed and future headers refuse form edits`() {
        for (source in listOf(
            "---\ntitle: [broken\n---\nBody",
            "---\ntitle: first\ntitle: second\n---\nBody",
            "---\nprivate: on\n---\nBody",
            "---\nformat: 2\n---\nBody",
            "---\nliteral\n---\nBody",
            "---\ntitle: Unclosed\n",
        )) {
            val document = parse(source)
            assertNull(PromptForm.of(document), source)
            for (edit in listOf(PromptEdit.Title("Nope"), PromptEdit.Body("Nope"))) {
                assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> {
                    PromptMutations.editing(edit, document, "Probe.md") }, "$source $edit")
            }
        }
    }

    @Test fun `no-op edits return the document and keep the exact source`() {
        val source = "---\ntitle :  'Same'\ndescription: Text\ntags: [one, two]\nprivate: true\n---\nExact body"
        val document = parse(source)
        for (edit in listOf(PromptEdit.Title("Same"), PromptEdit.Description("Text"),
            PromptEdit.Tags(listOf("one", "two")), PromptEdit.IsPrivate(true), PromptEdit.Body("Exact body"))) {
            assertSame(document, PromptMutations.editing(edit, document, "Probe.md"), edit.toString())
        }
        assertEquals(source, document.source)

        // An absent optional key also makes an empty description a no-op.
        val bare = parse("---\ntitle: T\n---\nBody")
        assertSame(bare, PromptMutations.editing(PromptEdit.Description(""), bare, "Probe.md"))
        // The filename fallback keeps a plain document untouched.
        val plain = parse("Body only")
        assertSame(plain, PromptMutations.editing(PromptEdit.Title("Probe"), plain, "Probe.md"))
    }
}
