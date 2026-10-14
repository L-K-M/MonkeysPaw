package ch.lkmc.monkeyspaw.core.domain.ranking

import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UCharacterCategory
import com.ibm.icu.text.Normalizer2

/** §5.4: search owns its transform; only Unicode 17 C/F mapping data is shared with sync. */
object SearchNormalizer {
    fun normalize(text: String): String {
        // ASCII has only the A–Z fold and is already NFC.
        if (text.all { it.code < 0x80 }) return buildString(text.length) {
            for (scalar in text) append(if (scalar in 'A'..'Z') (scalar.code + 0x20).toChar() else scalar)
        }

        val scalars = text.codePoints().toArray()
        require(scalars.none { it in 0xD800..0xDFFF }) { "Use Unicode scalar text." }
        val folded = buildString {
            for (scalar in scalars) {
                val replacement = SyncPathCaseFold.exceptions[scalar]
                if (replacement != null) {
                    append(replacement)
                } else {
                    val range = SyncPathCaseFold.ranges.firstOrNull {
                        scalar in it.first..it.last && (scalar - it.first) % it.step == 0
                    }
                    appendCodePoint(scalar + (range?.delta ?: 0))
                }
            }
        }
        return nfc.normalize(folded)
    }

    internal fun isWordScalar(scalar: Int): Boolean = when (UCharacter.getType(scalar)) {
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

    private val nfc = Normalizer2.getNFCInstance()
}
