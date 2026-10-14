package ch.lkmc.monkeyspaw.entry

import kotlin.test.*

internal class TileLaunchPolicyTest {
    @Test
    fun `API 26 through 33 uses the Intent overload`() {
        for (api in 26..33) assertFalse(TileLaunchPolicy.usesPendingIntent(api), "API $api")
    }

    @Test
    fun `API 34 and newer uses the PendingIntent overload`() {
        for (api in listOf(34, 35, 36, 37, 38)) assertTrue(TileLaunchPolicy.usesPendingIntent(api), "API $api")
    }

    @Test
    fun `unlocked click launches once without an unlock challenge`() {
        var launches = 0
        TileLaunchPolicy.click(false, { fail("An unlocked entry must not request unlock") }, { launches++ })
        assertEquals(1, launches)
    }

    @Test
    fun `locked click cannot launch until the platform invokes the successful unlock callback`() {
        val events = mutableListOf<String>()
        var successfulUnlock: (() -> Unit)? = null
        TileLaunchPolicy.click(true, { events += "unlock"; successfulUnlock = it }, { events += "launch" })
        assertEquals(listOf("unlock"), events)
        checkNotNull(successfulUnlock).invoke()
        assertEquals(listOf("unlock", "launch"), events)
    }

    @Test
    fun `cancelled unlock launches nothing and a later click can retry`() {
        var launches = 0
        TileLaunchPolicy.click(true, { /* The platform omits the callback when unlock is cancelled. */ }, { launches++ })
        assertEquals(0, launches)
        TileLaunchPolicy.click(false, { fail("Already unlocked") }, { launches++ })
        assertEquals(1, launches)
    }

    @Test
    fun `repeated clicks remain reusable and do not leave a stuck unlock or launch guard`() {
        var launches = 0
        val callbacks = mutableListOf<() -> Unit>()
        repeat(2) { TileLaunchPolicy.click(true, { callbacks += it }, { launches++ }) }
        assertEquals(0, launches)
        callbacks.forEach { it() }
        TileLaunchPolicy.click(false, { fail("Already unlocked") }, { launches++ })
        assertEquals(3, launches)
    }
}
