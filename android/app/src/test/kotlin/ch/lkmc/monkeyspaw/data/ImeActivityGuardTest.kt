package ch.lkmc.monkeyspaw.data

import kotlin.test.*

internal class ImeActivityGuardTest {
    @Test fun `only a foreground Fill owner suppresses our IME and pause is idempotent`() {
        val guard = ImeActivityGuard()
        val owner = Any()
        assertFalse(guard.inFillActivity)
        guard.resume(owner)
        assertTrue(guard.inFillActivity)
        guard.pause(owner)
        guard.pause(owner)
        assertFalse(guard.inFillActivity)
    }

    @Test fun `old activity teardown cannot clear a newer foreground Fill owner`() {
        val guard = ImeActivityGuard()
        val previous = Any()
        val next = Any()
        guard.resume(previous)
        guard.resume(next)
        guard.pause(previous)
        assertTrue(guard.inFillActivity)
        guard.pause(next)
        assertFalse(guard.inFillActivity)
    }
}
