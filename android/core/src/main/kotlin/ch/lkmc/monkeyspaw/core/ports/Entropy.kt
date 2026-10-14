package ch.lkmc.monkeyspaw.core.ports

fun interface Entropy {
    /** Return exactly count bytes or throw a sanitized failure. */
    fun bytes(count: Int): ByteArray
}
