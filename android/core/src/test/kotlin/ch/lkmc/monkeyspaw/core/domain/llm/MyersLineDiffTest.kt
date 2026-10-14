package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class MyersLineDiffTest {
    @Test fun shortestScriptsMatchAnIndependentSmallLcsOracle() {
        val sequences = listOf(emptyList<String>()) + (1..4).flatMap { length ->
            (0 until (1 shl length)).map { mask -> (0 until length).map { if (mask and (1 shl it) == 0) "a" else "b" } }
        }
        for (old in sequences) for (new in sequences) {
            val rows = MyersLineDiff.compare(old.joinToString("") { "$it\n" }, new.joinToString("") { "$it\n" })
            val table = Array(old.size + 1) { IntArray(new.size + 1) }
            for (i in old.indices) for (j in new.indices) table[i + 1][j + 1] =
                if (old[i] == new[j]) table[i][j] + 1 else maxOf(table[i][j + 1], table[i + 1][j])
            assertEquals(old.size + new.size - 2 * table[old.size][new.size], rows.count { it.kind != LineDiffLine.Kind.UNCHANGED })
            assertContentEquals(old.joinToString("") { "$it\n" }.toByteArray(), project(rows, LineDiffLine.Kind.ADDED))
            assertContentEquals(new.joinToString("") { "$it\n" }.toByteArray(), project(rows, LineDiffLine.Kind.REMOVED))
            assertEquals((1..old.size).toList(), rows.mapNotNull { it.originalLine })
            assertEquals((1..new.size).toList(), rows.mapNotNull { it.mergedLine })
            for (row in rows) {
                assertEquals(row.kind == LineDiffLine.Kind.ADDED, row.originalLine == null)
                assertEquals(row.kind == LineDiffLine.Kind.REMOVED, row.mergedLine == null)
            }
        }
    }

    @Test fun byteCapsAndSearchBoundsAreTypedAndDeterministic() {
        val atCap = "😀".repeat(Limits.maxPromptBytes / 4)
        assertContentEquals(atCap.toByteArray(), MyersLineDiff.compare(atCap, atCap).single().bytes)
        for ((old, new) in listOf(atCap + "x" to "", "" to atCap + "x")) {
            assertEquals(LineDiffError.SourceTooLarge, assertFailsWith<LineDiffError> { MyersLineDiff.compare(old, new) })
        }
        val old = (0 until 1000).joinToString("") { "old$it\n" }
        val new = (0 until 1000).joinToString("") { "new$it\n" }
        repeat(2) {
            assertEquals(LineDiffError.ComparisonTooComplex, assertFailsWith<LineDiffError> { MyersLineDiff.compare(old, new) })
        }
    }

    @Test fun tiesAndExactUnicodeLineEndingsRemainStableWithDefensiveBytes() {
        val rows = MyersLineDiff.compare("a\nb\na\n", "a\na\nb\n")
        assertEquals(listOf("unchanged", "removed", "unchanged", "added"), rows.map { it.kind.rawValue })
        repeat(10) { assertEquals(rows, MyersLineDiff.compare("a\nb\na\n", "a\na\nb\n")) }
        for ((old, new) in listOf("é\n" to "e\u0301\n", "😀\r\n" to "😀\n", "a\n" to "a", "\r" to "\n")) {
            val replaced = MyersLineDiff.compare(old, new)
            assertEquals(listOf(LineDiffLine.Kind.REMOVED, LineDiffLine.Kind.ADDED), replaced.map { it.kind })
            assertContentEquals(old.toByteArray(), replaced[0].bytes)
            assertContentEquals(new.toByteArray(), replaced[1].bytes)
        }
        rows[0].bytes.fill(0)
        assertEquals("a\n", rows[0].text)
        assertFailsWith<UnsupportedOperationException> { (rows as MutableList).clear() }
    }

    private fun project(rows: List<LineDiffLine>, excluding: LineDiffLine.Kind): ByteArray =
        rows.filter { it.kind != excluding }.flatMap { it.bytes.asIterable() }.toByteArray()
}
