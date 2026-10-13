package ch.lkmc.monkeyspaw.core.domain

import java.time.Instant

/** Validated 128-bit ULID. ASCII case-insensitive input; uppercase output. */
@ConsistentCopyVisibility
data class ULID private constructor(val rawValue: String) {
    companion object {
        private const val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        private const val maxTimestamp = (1L shl 48) - 1

        fun parse(value: String): ULID? {
            if (value.length != 26) return null
            val upper = value.map { if (it in 'a'..'z') it - 32 else it }.joinToString("")
            if (upper[0] !in '0'..'7' || upper.any { it !in alphabet }) return null
            return ULID(upper)
        }

        /** No clock, entropy source or monotonic state is consulted. */
        fun generate(at: Instant, entropy: ByteArray): ULID {
            val milliseconds = try {
                at.toEpochMilli()
            } catch (_: ArithmeticException) {
                throw ULIDGenerationError.InvalidTimestamp
            }
            if (milliseconds !in 0..maxTimestamp) throw ULIDGenerationError.InvalidTimestamp
            if (entropy.size != Limits.ulidEntropyBytes) throw ULIDGenerationError.InvalidEntropyLength

            var timestamp = milliseconds
            val characters = CharArray(26)
            for (index in 9 downTo 0) {
                characters[index] = alphabet[(timestamp and 31).toInt()]
                timestamp = timestamp ushr 5
            }
            for (index in 0 until 16) {
                var value = 0
                for (bit in 0 until 5) {
                    val offset = index * 5 + bit
                    value = (value shl 1) or ((entropy[offset / 8].toInt() ushr (7 - offset % 8)) and 1)
                }
                characters[index + 10] = alphabet[value]
            }
            return ULID(characters.concatToString())
        }
    }
}

sealed class ULIDGenerationError private constructor(message: String) : IllegalArgumentException(message) {
    object InvalidTimestamp : ULIDGenerationError("Supply a timestamp within the ULID millisecond range.")
    object InvalidEntropyLength : ULIDGenerationError("Supply exactly ten entropy bytes.")
}
