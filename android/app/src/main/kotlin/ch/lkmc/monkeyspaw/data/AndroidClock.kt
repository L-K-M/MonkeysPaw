package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.Clock
import java.time.Instant
import java.time.ZoneId

/** Core's FillService owns snapshot timing; neither source is cached by the driver. */
internal class AndroidClock(
    private val instant: () -> Instant = Instant::now,
    private val localZone: () -> ZoneId = ZoneId::systemDefault,
) : Clock {
    override fun now(): Instant = instant()
    fun zone(): ZoneId = localZone()
}
