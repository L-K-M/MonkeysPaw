package ch.lkmc.monkeyspaw.data

import kotlin.test.*

internal class ImeActivityGuardTest {
    @Test fun `only a foreground Fill owner suppresses our IME and pause is idempotent`() {
        val guard = ImeActivityGuard()
        val owner = Any()
        assertFalse(guard.inFillActivity)
        guard.resume(owner, 26)
        assertTrue(guard.inFillActivity)
        guard.pause(owner)
        guard.pause(owner)
        assertFalse(guard.inFillActivity)
    }

    @Test fun `old activity teardown cannot clear a newer foreground Fill owner`() {
        val guard = ImeActivityGuard()
        val previous = Any()
        val next = Any()
        guard.resume(previous, 28)
        guard.resume(next, 28)
        guard.pause(previous)
        assertTrue(guard.inFillActivity)
        guard.pause(next)
        assertFalse(guard.inFillActivity)
    }

    @Test fun `legacy APIs own the resumed activity while multi-resume APIs wait for top status`() {
        for (api in listOf(26, 27, 28, 29, 34, 37)) {
            val guard = ImeActivityGuard()
            val owner = Any()
            guard.resume(owner, api)
            assertEquals(api < 29, guard.inFillActivity)
            if (api >= 29) {
                guard.topResumed(owner, true)
                assertTrue(guard.inFillActivity)
                // Another app can become top without pausing this Fill activity.
                guard.topResumed(owner, false)
                assertFalse(guard.inFillActivity)
                guard.topResumed(owner, true)
                assertTrue(guard.inFillActivity)
            }
            guard.pause(owner)
            assertFalse(guard.inFillActivity)
        }
    }

    @Test fun `old top-status and pause callbacks cannot clear a newer Fill owner`() {
        val guard = ImeActivityGuard()
        val previous = Any()
        val next = Any()
        guard.resume(previous, 37)
        guard.topResumed(previous, true)
        guard.resume(next, 37)
        guard.topResumed(next, true)
        guard.topResumed(previous, false)
        guard.pause(previous)
        assertTrue(guard.inFillActivity)
        guard.topResumed(next, false)
        assertFalse(guard.inFillActivity)
    }
}
