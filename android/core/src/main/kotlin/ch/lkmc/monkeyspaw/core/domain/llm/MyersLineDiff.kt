package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.Limits

class LineDiffLine internal constructor(
    val kind: Kind,
    bytes: ByteArray,
    val originalLine: Int?,
    val mergedLine: Int?,
    placeholderWarnings: List<PlaceholderChange> = emptyList(),
) {
    enum class Kind(val rawValue: String) { UNCHANGED("unchanged"), REMOVED("removed"), ADDED("added") }

    private val storedBytes = bytes.copyOf()
    /** Exact UTF-8, including line endings and final-newline presence. */
    val bytes: ByteArray get() = storedBytes.copyOf()
    val text: String get() = storedBytes.toString(Charsets.UTF_8)
    val placeholderWarnings: List<PlaceholderChange> = placeholderWarnings.immutableCopy()

    override fun equals(other: Any?): Boolean = other is LineDiffLine && kind == other.kind &&
        storedBytes.contentEquals(other.storedBytes) && originalLine == other.originalLine &&
        mergedLine == other.mergedLine && placeholderWarnings == other.placeholderWarnings

    override fun hashCode(): Int = listOf(kind, storedBytes.contentHashCode(), originalLine,
        mergedLine, placeholderWarnings).hashCode()
}

sealed class LineDiffError private constructor(message: String) : Exception(message) {
    object SourceTooLarge : LineDiffError("The diff source exceeds the prompt size limit.")
    object ComparisonTooComplex : LineDiffError("The diff exceeds the comparison work limit.")

    final override fun toString(): String = message.orEmpty()
}

/** Myers' shortest edit script, preferring deletion when frontiers tie. Pure CPU work. */
object MyersLineDiff {
    fun compare(original: String, merged: String): List<LineDiffLine> {
        if (original.length > Limits.maxPromptBytes || merged.length > Limits.maxPromptBytes) throw LineDiffError.SourceTooLarge
        val oldBytes = original.toByteArray(Charsets.UTF_8)
        val newBytes = merged.toByteArray(Charsets.UTF_8)
        if (oldBytes.size > Limits.maxPromptBytes || newBytes.size > Limits.maxPromptBytes) throw LineDiffError.SourceTooLarge
        val old = lines(oldBytes)
        val new = lines(newBytes)
        var prefix = 0
        while (prefix < minOf(old.size, new.size) && old[prefix].contentEquals(new[prefix])) prefix++
        var suffix = 0
        while (suffix < minOf(old.size, new.size) - prefix &&
            old[old.size - suffix - 1].contentEquals(new[new.size - suffix - 1])) suffix++

        val result = (0 until prefix).mapTo(mutableListOf()) {
            LineDiffLine(LineDiffLine.Kind.UNCHANGED, old[it], it + 1, it + 1)
        }
        val oldEnd = old.size - suffix
        val newEnd = new.size - suffix
        if (prefix == oldEnd) {
            for (index in prefix until newEnd) result.add(LineDiffLine(LineDiffLine.Kind.ADDED, new[index], null, index + 1))
        } else if (prefix == newEnd) {
            for (index in prefix until oldEnd) result.add(LineDiffLine(LineDiffLine.Kind.REMOVED, old[index], index + 1, null))
        } else {
            result.addAll(edits(old.subList(prefix, oldEnd), new.subList(prefix, newEnd), prefix))
        }
        for (index in 0 until suffix) result.add(LineDiffLine(LineDiffLine.Kind.UNCHANGED, old[oldEnd + index],
            oldEnd + index + 1, newEnd + index + 1))
        return result.immutableCopy()
    }

    private fun lines(bytes: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var start = 0
        for (index in bytes.indices) {
            if (bytes[index] != 10.toByte()) continue
            result.add(bytes.copyOfRange(start, index + 1))
            start = index + 1
        }
        if (start < bytes.size) result.add(bytes.copyOfRange(start, bytes.size))
        return result
    }

    private fun edits(old: List<ByteArray>, new: List<ByteArray>, offset: Int): List<LineDiffLine> {
        val trace = mutableListOf<IntArray>()
        var work = 0
        for (distance in 0..(old.size + new.size)) {
            // Match Swift's shared bound on frontier storage and search steps.
            if (distance + 1 > Limits.maxPromptBytes - work) throw LineDiffError.ComparisonTooComplex
            work += distance + 1
            val frontier = IntArray(distance + 1)
            for (index in 0..distance) {
                val diagonal = 2 * index - distance
                var x = if (distance == 0) 0 else {
                    val previous = trace[distance - 1]
                    if (index == 0 || (index != distance && previous[index - 1] < previous[index])) previous[index]
                    else previous[index - 1] + 1
                }
                var y = x - diagonal
                while (x < old.size && y < new.size && old[x].contentEquals(new[y])) {
                    if (work >= Limits.maxPromptBytes) throw LineDiffError.ComparisonTooComplex
                    work++
                    x++
                    y++
                }
                frontier[index] = x
                if (x >= old.size && y >= new.size) {
                    trace.add(frontier)
                    return backtrack(trace, old, new, offset)
                }
            }
            trace.add(frontier)
        }
        throw LineDiffError.ComparisonTooComplex
    }

    private fun backtrack(trace: List<IntArray>, old: List<ByteArray>, new: List<ByteArray>, offset: Int): List<LineDiffLine> {
        var x = old.size
        var y = new.size
        val result = mutableListOf<LineDiffLine>()
        for (distance in trace.lastIndex downTo 1) {
            val index = (x - y + distance) / 2
            val previous = trace[distance - 1]
            val insertion = index == 0 || (index != distance && previous[index - 1] < previous[index])
            val previousX = previous[if (insertion) index else index - 1]
            val previousY = previousX - (x - y + if (insertion) 1 else -1)
            while (x > previousX && y > previousY) {
                result.add(LineDiffLine(LineDiffLine.Kind.UNCHANGED, old[x - 1], offset + x, offset + y))
                x--
                y--
            }
            if (insertion) {
                result.add(LineDiffLine(LineDiffLine.Kind.ADDED, new[y - 1], null, offset + y))
                y--
            } else {
                result.add(LineDiffLine(LineDiffLine.Kind.REMOVED, old[x - 1], offset + x, null))
                x--
            }
        }
        while (x > 0 && y > 0) {
            result.add(LineDiffLine(LineDiffLine.Kind.UNCHANGED, old[x - 1], offset + x, offset + y))
            x--
            y--
        }
        return result.asReversed()
    }
}
