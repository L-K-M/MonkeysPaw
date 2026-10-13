package ch.lkmc.monkeyspaw.core.domain.paths

import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UCharacterCategory
import com.ibm.icu.text.Normalizer2

/** ICU supplies pinned Unicode properties and NFC; sync folding has its own frozen table. */
internal object UnicodeText {
    fun nfc(text: String): String {
        // Swift strings contain scalars. Never let JVM UTF-8 encoding repair a lone surrogate.
        require(text.codePoints().noneMatch { it in 0xD800..0xDFFF }) { "Use Unicode scalar text." }
        return Normalizer2.getNFCInstance().normalize(text)
    }

    fun isControlOrFormat(scalar: Int): Boolean = when (UCharacter.getType(scalar)) {
        UCharacterCategory.CONTROL.toInt(), UCharacterCategory.FORMAT.toInt() -> true
        else -> false
    }

    /** ASCII slash bytes cannot occur inside a multibyte scalar. Keep empty segments. */
    fun slashSegments(bytes: ByteArray): List<ByteArray> {
        val segments = mutableListOf<ByteArray>()
        var start = 0
        for (index in bytes.indices) {
            if (bytes[index] != 47.toByte()) continue
            segments.add(bytes.copyOfRange(start, index))
            start = index + 1
        }
        segments.add(bytes.copyOfRange(start, bytes.size))
        return segments
    }
}
