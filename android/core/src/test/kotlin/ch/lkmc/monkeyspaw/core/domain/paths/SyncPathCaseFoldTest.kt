package ch.lkmc.monkeyspaw.core.domain.paths

import java.nio.file.Files
import java.nio.file.Path
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SyncPathCaseFoldTest {
    @Test
    fun `table ranges are sorted disjoint scalar valid and idempotent`() {
        val ranges = SyncPathCaseFold.ranges
        assertTrue(ranges.isNotEmpty())
        assertEquals(ranges.map { it.first }.sorted(), ranges.map { it.first })
        val inputs = mutableSetOf<Int>()
        for (range in ranges) {
            assertTrue(range.first <= range.last && range.step > 0)
            assertEquals(0, (range.last - range.first) % range.step)
            for (value in range.first..range.last step range.step) {
                assertTrue(inputs.add(value), "Duplicate fold input")
                assertTrue(isScalar(value) && isScalar(value + range.delta))
                val replacement = scalar(value + range.delta)
                assertEquals(replacement, SyncPathCaseFold.fold(scalar(value)))
                assertEquals(replacement, SyncPathCaseFold.fold(replacement))
            }
        }
        for ((value, replacement) in SyncPathCaseFold.exceptions) {
            assertTrue(inputs.add(value), "Duplicate fold input")
            assertTrue(isScalar(value))
            assertFalse(replacement.isEmpty())
            assertTrue(replacement.codePoints().allMatch(::isScalar))
            assertEquals(replacement, SyncPathCaseFold.fold(scalar(value)))
            assertEquals(replacement, SyncPathCaseFold.fold(replacement))
        }
    }

    @Test
    fun `generated entries and every scalar fold match the frozen Swift source`() {
        val source = Files.readString(Path.of(System.getProperty("monkeyspaw.syncFoldReference")))
        assertTrue(source.contains("Unicode 17.0.0"))
        assertTrue(source.contains("ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"))
        val rangePattern = Regex("MappingRange\\(first: 0x([0-9A-F]+), last: 0x([0-9A-F]+), step: (\\d+), delta: (-?\\d+)\\)")
        val ranges = rangePattern.findAll(source).map {
            SyncPathCaseFold.MappingRange(it.groupValues[1].toInt(16), it.groupValues[2].toInt(16),
                it.groupValues[3].toInt(), it.groupValues[4].toInt())
        }.toList()
        assertEquals(source.split("MappingRange(first:").size - 1, ranges.size)
        assertEquals(ranges, SyncPathCaseFold.ranges)

        val exceptionPattern = Regex("^\\s*0x([0-9A-F]+): \"((?:\\\\u\\{[0-9A-F]+\\})+)\",$", RegexOption.MULTILINE)
        val escapePattern = Regex("\\\\u\\{([0-9A-F]+)\\}")
        val entries = exceptionPattern.findAll(source).map { match ->
            match.groupValues[1].toInt(16) to escapePattern.findAll(match.groupValues[2])
                .joinToString("") { scalar(it.groupValues[1].toInt(16)) }
        }.toList()
        assertTrue(entries.isNotEmpty())
        assertEquals(Regex("^\\s*0x.*:", RegexOption.MULTILINE).findAll(source).count(), entries.size)
        assertEquals(entries.size, entries.toMap().size)
        assertEquals(entries.toMap(), SyncPathCaseFold.exceptions)

        val reference = entries.toMap().toMutableMap()
        for (range in ranges) for (value in range.first..range.last step range.step) {
            reference[value] = scalar(value + range.delta)
        }
        val input = buildString { for (value in 0..0x10FFFF) if (isScalar(value)) appendCodePoint(value) }
        val expected = buildString {
            for (value in 0..0x10FFFF) if (isScalar(value)) append(reference[value] ?: scalar(value))
        }
        assertTrue(expected == SyncPathCaseFold.fold(input), "Fold mismatch across all valid Unicode scalars")
    }

    @Test
    fun `full C F folds exclude simple and Turkic alternatives regardless of locale`() {
        val saved = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("ii\u0307ssı", SyncPathCaseFold.fold("Iİẞı"))
            assertEquals("σσσssᎠᎠ", SyncPathCaseFold.fold("ΣςσßꭰᎠ"))
        } finally {
            Locale.setDefault(saved)
        }
    }

    private fun isScalar(value: Int): Boolean = value in 0..0x10FFFF && value !in 0xD800..0xDFFF
}
