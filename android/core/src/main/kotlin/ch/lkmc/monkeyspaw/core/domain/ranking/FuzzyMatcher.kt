package ch.lkmc.monkeyspaw.core.domain.ranking

internal class FuzzyText(text: String) {
    val scalars: IntArray = SearchNormalizer.normalize(text).codePoints().toArray()
    val wordStarts: BooleanArray = BooleanArray(scalars.size) {
        it == 0 || !SearchNormalizer.isWordScalar(scalars[it - 1])
    }
}

/** §5.4: maximize m + 2W + C over subsequence alignments in O(mn) time / O(n) space. */
internal object FuzzyMatcher {
    fun score(term: IntArray, text: FuzzyText): Double? {
        val m = term.size
        val n = text.scalars.size
        if (m == 0 || m > n) return null

        var previous = IntArray(n) { -1 }
        var current = IntArray(n) { -1 }
        for ((termIndex, scalar) in term.withIndex()) {
            var bestEarlier = -1
            var found = false
            for (position in 0 until n) {
                if (position > 0) bestEarlier = maxOf(bestEarlier, previous[position - 1])
                current[position] = -1
                if (text.scalars[position] != scalar) continue

                val bonus = 1 + if (text.wordStarts[position]) 2 else 0
                if (termIndex == 0) {
                    current[position] = bonus
                } else if (bestEarlier >= 0) {
                    val consecutive = if (position > 0 && previous[position - 1] >= 0) {
                        previous[position - 1] + 1
                    } else -1
                    current[position] = maxOf(bestEarlier, consecutive) + bonus
                }
                found = found || current[position] >= 0
            }
            if (!found) return null

            val swap = previous
            previous = current
            current = swap
        }
        val raw = previous.max()
        return raw.toDouble() / (4 * m.toDouble() - 1) * (1 + m.toDouble() / n.toDouble()) / 2
    }
}
