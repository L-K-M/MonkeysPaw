package ch.lkmc.monkeyspaw.core

import kotlin.test.Test
import kotlin.test.assertEquals

class AppIdentityTest {
    @Test
    fun `display name matches the shared product identity`() {
        assertEquals("Monkey's Paw", AppIdentity.displayName)
    }
}
