package ch.lkmc.monkeyspaw.ime

import android.text.InputType.*
import android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING

/** Plain metadata only; Android constants are inlined and no framework objects are read. */
internal class ImeInputPolicy private constructor(
    val insertion: Insertion,
    val learning: Learning,
) {
    enum class Insertion { PASSWORD, COPY_ONLY, SINGLE_LINE, MULTI_LINE }
    enum class Learning { NORMAL, EPHEMERAL }
    enum class Session { ACTIVE, RETIRED }
    enum class Decision { HIDE_PROMPTS, CANCEL, BLOCK, COPY_INSTEAD, INSERT }

    val promptsAllowed: Boolean get() = insertion != Insertion.PASSWORD

    /**
     * Classify before opening/rendering a prompt, then recheck at delivery with fresh metadata.
     * A null render means validation or builtin/field resolution failed. This authorizes no effects.
     */
    fun decide(renderedText: String?, connectionReady: Boolean, session: Session = Session.ACTIVE): Decision {
        if (!promptsAllowed) return Decision.HIDE_PROMPTS
        if (session == Session.RETIRED) return Decision.CANCEL
        if (renderedText == null) return Decision.BLOCK
        if (!connectionReady || insertion == Insertion.COPY_ONLY) return Decision.COPY_INSTEAD
        if (insertion == Insertion.SINGLE_LINE && hasLineBreak(renderedText)) return Decision.COPY_INSTEAD
        return Decision.INSERT
    }

    companion object {
        fun classify(inputType: Int?, imeOptions: Int = 0): ImeInputPolicy {
            val learning = if (imeOptions and IME_FLAG_NO_PERSONALIZED_LEARNING != 0) Learning.EPHEMERAL else Learning.NORMAL
            if (inputType == null) return ImeInputPolicy(Insertion.COPY_ONLY, learning)

            val inputClass = inputType and TYPE_MASK_CLASS
            val variation = inputType and TYPE_MASK_VARIATION
            val password = when (inputClass) {
                TYPE_CLASS_TEXT -> variation == TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == TYPE_TEXT_VARIATION_VISIBLE_PASSWORD || variation == TYPE_TEXT_VARIATION_WEB_PASSWORD
                TYPE_CLASS_NUMBER -> variation == TYPE_NUMBER_VARIATION_PASSWORD
                else -> false
            }
            val insertion = when {
                password -> Insertion.PASSWORD
                inputClass == TYPE_CLASS_TEXT && inputType and TYPE_TEXT_FLAG_MULTI_LINE != 0 -> Insertion.MULTI_LINE
                inputClass == TYPE_CLASS_TEXT || inputClass == TYPE_NULL -> Insertion.SINGLE_LINE
                else -> Insertion.COPY_ONLY
            }
            return ImeInputPolicy(insertion, learning)
        }

        private fun hasLineBreak(text: String): Boolean = text.any {
            it == '\n' || it == '\r' || it == '\u000b' || it == '\u000c' ||
                it == '\u0085' || it == '\u2028' || it == '\u2029'
        }
    }
}
