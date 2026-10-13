package ch.lkmc.monkeyspaw.core.syncapi

/** Patch presence is independent of a nullable value (§19 B2/B9). */
sealed interface OptionalValue<out T : Any> {
    data object Omitted : OptionalValue<Nothing>
    data object Null : OptionalValue<Nothing>
    data class Value<T : Any>(val value: T) : OptionalValue<T>
}
