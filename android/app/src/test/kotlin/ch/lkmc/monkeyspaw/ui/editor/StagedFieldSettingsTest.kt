package ch.lkmc.monkeyspaw.ui.editor

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptFieldSettingsIssue
import kotlin.test.*

internal class StagedFieldSettingsTest {
    private fun stage(source: String) = StagedFieldSettings.of(
        assertNotNull(PromptCodec.fieldSettings(PromptCodec.parse(source, "a.md"))).single())

    /** A field commit bound before an earlier row was removed must still reach its own option. */
    @Test
    fun `delayed option callbacks follow their choice after an earlier row is removed`() {
        var staged = stage("---\nfields:\n  topic: {type: choice, options: [A, B, C]}\n---\n{{topic}}")
        val ids = staged.rows.map { it.id }
        // Row bindings keep whatever identity the composition captured for them.
        val lateA = { staged = staged.editOption(ids[0]) { it.copy(label = "Late A") } }
        val delayedB = { staged = staged.editOption(ids[1]) { it.copy(label = "Edited B") } }
        val delayedCValue = { staged = staged.editOption(ids[2]) { it.copy(value = "see") } }

        staged = staged.removeOption(ids[0])
        delayedB()
        delayedCValue()
        assertEquals(listOf("Edited B", "C"), staged.settings.options.map { it.label })
        assertEquals(listOf("B", "see"), staged.settings.options.map { it.value })

        lateA()
        staged = staged.addOption()
        lateA()
        assertEquals(listOf("Edited B", "C", ""), staged.settings.options.map { it.label })
        assertEquals(listOf("B", "see", ""), staged.settings.options.map { it.value })
        assertEquals(listOf(1, 2, null), staged.settings.options.map { it.originalIndex })
    }

    /** Row ids are unique, never recycled, and survive unrelated staged edits. */
    @Test
    fun `row ids are stable and never recycled while validation follows the staged options`() {
        var staged = stage("---\nfields:\n  topic: {type: choice, options: [A, B]}\n---\n{{topic}}")
        val first = staged.rows.map { it.id }
        assertEquals(first.size, first.distinct().size)

        staged = staged.edit { it.copy(label = "Renamed") }
        assertEquals(first, staged.rows.map { it.id })
        staged = staged.editOption(first[0]) { it.copy(label = "One") }
        assertEquals(first, staged.rows.map { it.id })
        assertEquals(staged.settings.options, staged.rows.map { it.option })

        val removed = first[0]
        staged = staged.removeOption(removed)
        val beforeAdds = staged.rows.map { it.id }
        staged = staged.addOption().addOption()
        val ids = staged.rows.map { it.id }
        assertEquals(ids.size, ids.distinct().size)
        assertFalse(removed in ids)
        assertEquals(first[1], ids.first())
        assertTrue((ids - beforeAdds).none { it in first })

        val kept = staged
        staged = staged.editOption(removed) { it.copy(label = "Zombie") }
        staged = staged.removeOption(removed)
        assertEquals(kept, staged)

        for (id in staged.rows.map { it.id }) staged = staged.removeOption(id)
        assertTrue(staged.settings.options.isEmpty())
        assertEquals(PromptFieldSettingsIssue.MISSING_OPTIONS, staged.settings.validationIssue)
    }
}
