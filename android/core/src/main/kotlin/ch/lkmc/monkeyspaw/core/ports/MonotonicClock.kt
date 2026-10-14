package ch.lkmc.monkeyspaw.core.ports

/** Same time base for an intent and all its HTTP requests; never UTC/wall time.
 * Compute remaining time as deadlineNanos - nowNanos(), preserving nanoTime wraparound.
 */
fun interface MonotonicClock {
    fun nowNanos(): Long
}
