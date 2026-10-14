package ch.lkmc.monkeyspaw.core.ports

enum class DeliveryMode { COPY, IME_COMMIT, SELECTION_RESULT }
enum class LearningPolicy { NORMAL, EPHEMERAL }
enum class TextDeliveryResult { ACCEPTED, REFUSED, STALE }

/**
 * Synchronous effect on the driver's UI thread. Recheck the active session and target immediately
 * before the effect. ACCEPTED means the platform accepted it; REFUSED and STALE teach nothing.
 * Drivers support explicit COPY separately, never as an automatic fallback from another mode.
 */
fun interface TextDelivery {
    fun deliver(mode: DeliveryMode, text: String): TextDeliveryResult
}
