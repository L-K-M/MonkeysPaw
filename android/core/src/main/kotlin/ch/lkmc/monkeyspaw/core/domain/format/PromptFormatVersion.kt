package ch.lkmc.monkeyspaw.core.domain.format

/** Positive canonical decimal integer, with no machine-word ceiling. */
@ConsistentCopyVisibility
data class PromptFormatVersion private constructor(val decimalValue: String) {
    val isFuture: Boolean
        get() = decimalValue.length > current.decimalValue.length ||
            (decimalValue.length == current.decimalValue.length && decimalValue > current.decimalValue)

    companion object {
        val current = PromptFormatVersion("1")

        fun fromDecimal(value: String): PromptFormatVersion? {
            if (value.isEmpty() || value[0] == '0' || value.any { it !in '0'..'9' }) return null
            return PromptFormatVersion(value)
        }
    }
}
