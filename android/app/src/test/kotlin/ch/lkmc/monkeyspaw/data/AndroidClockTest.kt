package ch.lkmc.monkeyspaw.data

import java.time.Instant
import java.time.ZoneId
import kotlin.test.*

internal class AndroidClockTest {
    @Test
    fun `clock and local zone delegate independently without caching or constructor reads`() {
        var instant = Instant.parse("2021-01-01T00:30:00Z")
        var zone = ZoneId.of("America/New_York")
        var reads = 0
        var zones = 0
        val clock = AndroidClock({ reads++; instant }, { zones++; zone })
        assertEquals(0, reads)
        assertEquals(0, zones)
        assertEquals(instant, clock.now())
        assertEquals(1, reads)
        assertEquals(0, zones)
        assertEquals(zone, clock.zone())
        instant = instant.plusSeconds(3600)
        zone = ZoneId.of("Asia/Kolkata")
        assertEquals(instant, clock.now())
        assertEquals(zone, clock.zone())
        assertEquals(2, reads)
        assertEquals(2, zones)
    }

    @Test
    fun `default clock uses wall time and the current system zone`() {
        val before = Instant.now()
        val clock = AndroidClock()
        val sampled = clock.now()
        val after = Instant.now()
        assertTrue(sampled >= before && sampled <= after)
        assertEquals(ZoneId.systemDefault(), clock.zone())
    }
}
