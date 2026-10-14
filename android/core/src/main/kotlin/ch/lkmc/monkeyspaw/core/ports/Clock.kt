package ch.lkmc.monkeyspaw.core.ports

import java.time.Instant

fun interface Clock {
    fun now(): Instant
}
