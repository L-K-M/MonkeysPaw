package ch.lkmc.monkeyspaw.core.domain.ranking

import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UCharacterCategory
import com.ibm.icu.text.Normalizer2

/** Search comparison folding is separate from the frozen sync path transform. */
internal object SearchNormalizer {
    fun normalize(text: String): String {
        val scalars = text.codePoints().toArray()
        require(scalars.none { it in 0xD800..0xDFFF }) { "Use Unicode scalar text." }
        val folded = buildString {
            for (scalar in scalars) {
                when (scalar) {
                    in 0x41..0x5A -> appendCodePoint(scalar + 32)
                    in 0..0x7F -> appendCodePoint(scalar)
                    // Foundation folds Cherokee toward lowercase and leaves these newer folds alone.
                    in 0x13A0..0x13EF -> appendCodePoint(scalar + 0x97D0)
                    in 0x13F0..0x13F5 -> appendCodePoint(scalar + 8)
                    in 0xAB70..0xABBF, in 0x13F8..0x13FD,
                    in 0x1C80..0x1C89, 0xA7CB, 0xA7CC, 0xA7CE, 0xA7D2, 0xA7D4, 0xA7DA, 0xA7DC,
                    in 0x10D50..0x10D65, in 0x16EA0..0x16EB8 -> appendCodePoint(scalar)
                    else -> append(UCharacter.foldCase(String(Character.toChars(scalar)), true))
                }
            }
        }
        return precompose(folded)
    }

    // Swift Set<String> still compares canonically equivalent strings when CF's
    // precomposition leaves an out-of-order Tibetan decomposition in the scalar text.
    fun tagKey(text: String): String = nfc.normalize(normalize(text))

    fun isWordScalar(scalar: Int): Boolean = !outsideFoundationWordSet(scalar) && when (UCharacter.getType(scalar)) {
        UCharacterCategory.UPPERCASE_LETTER.toInt(),
        UCharacterCategory.LOWERCASE_LETTER.toInt(),
        UCharacterCategory.TITLECASE_LETTER.toInt(),
        UCharacterCategory.MODIFIER_LETTER.toInt(),
        UCharacterCategory.OTHER_LETTER.toInt(),
        UCharacterCategory.NON_SPACING_MARK.toInt(),
        UCharacterCategory.COMBINING_SPACING_MARK.toInt(),
        UCharacterCategory.ENCLOSING_MARK.toInt(),
        UCharacterCategory.DECIMAL_DIGIT_NUMBER.toInt(),
        UCharacterCategory.LETTER_NUMBER.toInt(),
        UCharacterCategory.OTHER_NUMBER.toInt() -> true
        else -> false
    }

    // CFStringNormalize groups by original combining classes, and its expanding-mark
    // decomposition calls retain a 64-scalar bound even after the buffer grows.
    // Preserve that comparison behavior rather than broadening search via sync's NFC.
    // Reference: swift-corelibs-foundation/Sources/CoreFoundation/CFString.c, CFStringNormalize.
    private fun precompose(text: String): String {
        if (text.all { it.code < 128 }) return text
        val input = text.codePoints().toArray()
        val output = mutableListOf<Int>()
        var index = 0
        while (index < input.size) {
            val scalar = input[index++]
            val buffer = mutableListOf<Int>()
            if (combiningClass(scalar) == 0 && scalar !in 0xAC00..0xD7A3) {
                decomposition(scalar)?.let { buffer.addAll(it.toList()) }
            }
            if (index < input.size || buffer.isEmpty()) {
                val next = if (buffer.isEmpty()) scalar else input[index]
                if (combiningClass(next) != 0) {
                    if (buffer.isEmpty()) {
                        if (output.isNotEmpty()) buffer.add(output.removeAt(output.lastIndex))
                    } else index++
                    appendDecomposed(buffer, next)
                    while (index < input.size && combiningClass(input[index]) != 0) {
                        appendDecomposed(buffer, input[index++])
                    }
                    buffer.sortBy(::combiningClass)
                }
            }

            if (buffer.size > 1) {
                var base = buffer[0]
                var lastClass = 0
                val retained = mutableListOf<Int>()
                for (next in buffer.drop(1)) {
                    val nextClass = combiningClass(next)
                    val combined = if (lastClass == 0 || nextClass > lastClass) composePair(base, next) else null
                    if (combined != null) {
                        base = combined
                    } else {
                        retained.add(next)
                        if (lastClass == 0 || nextClass > lastClass) lastClass = nextClass
                    }
                }
                output.add(base)
                output.addAll(retained)
                continue
            }

            var base = buffer.firstOrNull() ?: scalar
            // CF's inclusive Jamo endpoints are part of the existing comparison path.
            if (base in 0x1100..0x1113 && index < input.size && input[index] in 0x1161..0x1176) {
                val vowel = input[index++] - 0x1161
                val trailing = if (index < input.size && input[index] in 0x11A7..0x11C3) input[index++] - 0x11A7 else 0
                base = 0xAC00 + ((base - 0x1100) * 21 + vowel) * 28 + trailing
            } else {
                while (index < input.size && isMark(input[index]) && combiningClass(input[index]) == 0) {
                    base = composePair(base, input[index]) ?: break
                    index++
                }
            }
            // Bridging CF's inclusive invalid Jamo compositions repairs lone UTF-16 surrogates.
            output.add(if (base in 0xD800..0xDFFF) 0xFFFD else base)
        }
        return buildString { output.forEach(::appendCodePoint) }
    }

    private fun appendDecomposed(buffer: MutableList<Int>, scalar: Int) {
        val decomposition = decomposition(scalar)
        if (decomposition == null) {
            buffer.add(scalar)
        } else if (buffer.size > decompositionBufferSize || decomposition.size <= decompositionBufferSize - buffer.size) {
            buffer.addAll(decomposition.toList())
        }
    }

    private fun decomposition(scalar: Int): IntArray? = if (outsideFoundationWordSet(scalar)) null
        else nfd.getDecomposition(scalar)?.codePoints()?.toArray()

    private fun composePair(base: Int, mark: Int): Int? = nfc.composePair(base, mark)
        .takeIf { it >= 0 && !outsideFoundationWordSet(it) }

    private fun combiningClass(scalar: Int): Int = if (outsideFoundationWordSet(scalar)) 0
        else UCharacter.getCombiningClass(scalar)

    private fun isMark(scalar: Int): Boolean = isWordScalar(scalar) && when (UCharacter.getType(scalar)) {
        UCharacterCategory.NON_SPACING_MARK.toInt(), UCharacterCategory.COMBINING_SPACING_MARK.toInt(),
        UCharacterCategory.ENCLOSING_MARK.toInt() -> true
        else -> false
    }

    private fun outsideFoundationWordSet(scalar: Int): Boolean {
        val position = wordExclusions.binarySearch(scalar)
        return position >= 0 || (-position - 1) % 2 == 1
    }

    private const val decompositionBufferSize = 64
    private val nfd = Normalizer2.getNFDInstance()
    private val nfc = Normalizer2.getNFCInstance()

    // Swift 6.4 Foundation's L/M/N bitmap is narrower than ICU 78.3's. Inclusive
    // ranges were compared over every scalar; shared goldens pin representative boundaries.
    private val wordExclusions = intArrayOf(
        0x088F, 0x088F, 0x0897, 0x0897, 0x0C5C, 0x0C5C, 0x0CDC, 0x0CDC,
        0x1ACF, 0x1ADD, 0x1AE0, 0x1AEB, 0x1C89, 0x1C8A,
        0xA7CB, 0xA7CF, 0xA7D2, 0xA7D2, 0xA7D4, 0xA7D4, 0xA7DA, 0xA7DC, 0xA7F1, 0xA7F1,
        0x105C0, 0x105F3, 0x10940, 0x10959, 0x10D40, 0x10D65, 0x10D69, 0x10D6D,
        0x10D6F, 0x10D85, 0x10EC2, 0x10EC7, 0x10EFA, 0x10EFC,
        0x11380, 0x11389, 0x1138B, 0x1138B, 0x1138E, 0x1138E, 0x11390, 0x113B5,
        0x113B7, 0x113C0, 0x113C2, 0x113C2, 0x113C5, 0x113C5, 0x113C7, 0x113CA,
        0x113CC, 0x113D3, 0x113E1, 0x113E2, 0x116D0, 0x116E3, 0x11B60, 0x11B67,
        0x11BC0, 0x11BE0, 0x11BF0, 0x11BF9, 0x11DB0, 0x11DDB, 0x11DE0, 0x11DE9,
        0x11F5A, 0x11F5A, 0x13460, 0x143FA, 0x16100, 0x16139, 0x16D40, 0x16D6C,
        0x16D70, 0x16D79, 0x16EA0, 0x16EB8, 0x16EBB, 0x16ED3, 0x16FF2, 0x16FF6,
        0x17000, 0x187FF, 0x18CFF, 0x18D1E, 0x18D80, 0x18DF2, 0x1CCF0, 0x1CCF9,
        0x1E5D0, 0x1E5FA, 0x1E6C0, 0x1E6DE, 0x1E6E0, 0x1E6F5, 0x1E6FE, 0x1E6FF,
        0x2B73A, 0x2B73F, 0x2CEA2, 0x2CEAD, 0x2EBF0, 0x2EE5D, 0x323B0, 0x33479,
    )
}
