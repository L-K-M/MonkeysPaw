package ch.lkmc.monkeyspaw.core.domain.ranking

/** Stored title/path bytes break ties without normalization or signed-byte comparisons. */
internal object Utf8Order : Comparator<ByteArray> {
    override fun compare(left: ByteArray, right: ByteArray): Int {
        for (index in 0 until minOf(left.size, right.size)) {
            val comparison = (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
            if (comparison != 0) return comparison
        }
        return left.size.compareTo(right.size)
    }
}
