package ch.lkmc.monkeyspaw

import ch.lkmc.monkeyspaw.core.AppIdentity
import kotlin.test.Test
import kotlin.test.assertEquals

class AppIdentityTest {
    @Test
    fun `app consumes the JVM core identity`() {
        assertEquals("Monkey's Paw", AppIdentity.displayName)
    }
}
