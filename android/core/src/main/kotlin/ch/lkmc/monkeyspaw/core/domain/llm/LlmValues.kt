package ch.lkmc.monkeyspaw.core.domain.llm

import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UCharacterCategory
import java.util.Collections

internal fun <T> List<T>.immutableCopy(): List<T> = Collections.unmodifiableList(ArrayList(this))

/** Foundation CharacterSet.controlCharacters includes Unicode format characters. */
internal fun String.hasControls(): Boolean = codePoints().anyMatch {
    val category = UCharacter.getType(it)
    category == UCharacterCategory.CONTROL.toInt() || category == UCharacterCategory.FORMAT.toInt()
}

internal fun String.trimProviderWhitespace(): String = trim {
    UCharacter.isUWhiteSpace(it.code) || it == '\u200b'
}
