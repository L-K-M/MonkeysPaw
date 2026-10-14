package ch.lkmc.monkeyspaw.entry

import ch.lkmc.monkeyspaw.core.ports.LearningPolicy
import java.util.UUID
import kotlin.test.*

internal class FillHandoffStoreTest {
    private fun payload() = FillHandoff(LearningPolicy.EPHEMERAL, null, null)

    @Test fun `opaque token consumes only once and wrong tokens do not consume it`() {
        val store = FillHandoffStore()
        val payload = payload()
        val token = store.offer(payload)
        assertEquals(token, UUID.fromString(token).toString())
        assertNull(store.consume(UUID.randomUUID().toString()))
        assertSame(payload, store.consume(token))
        assertNull(store.consume(token))
    }

    @Test fun `replacement bounds memory and cancellation cannot clear a newer token`() {
        val store = FillHandoffStore()
        val old = store.offer(payload())
        val current = payload()
        val new = store.offer(current)
        store.clear(old)
        assertNull(store.consume(old))
        assertSame(current, store.consume(new))
    }

    @Test fun `failed launch clears its payload and allows an explicit retry`() {
        val store = FillHandoffStore()
        val tokens = mutableListOf<String>()
        var failLaunch = true
        val launcher = FillHandoffLauncher(store) {
            tokens.add(it)
            if (failLaunch) throw IllegalStateException("private launch error")
        }
        assertFalse(launcher.open(payload()))
        assertNull(store.consume(tokens.single()))
        failLaunch = false
        val retried = payload()
        assertTrue(launcher.open(retried))
        assertSame(retried, store.consume(tokens.last()))
    }

    @Test fun `duplicate and reentrant launches issue one token and cancel removes it`() {
        val store = FillHandoffStore()
        val tokens = mutableListOf<String>()
        lateinit var launcher: FillHandoffLauncher
        launcher = FillHandoffLauncher(store) {
            tokens.add(it)
            assertFalse(launcher.open(payload()))
        }
        assertTrue(launcher.open(payload()))
        assertFalse(launcher.open(payload()))
        assertEquals(1, tokens.size)
        launcher.cancel()
        assertNull(store.consume(tokens.single()))
        assertTrue(launcher.open(payload()))
        launcher.cancel()
        assertNull(store.consume(tokens.last()))
    }

    @Test fun `process loss cannot recover a payload and diagnostic strings redact content`() {
        val token = FillHandoffStore().offer(payload())
        assertNull(FillHandoffStore().consume(token))
        assertEquals("FillHandoff(<redacted>)", payload().toString())
        assertFalse(FillRequest(EntrySource.IME_HANDOFF, handoffToken = token).toString().contains(token))
    }

    @Test fun `cancellation during launch reports failure and drops the offered payload`() {
        val store = FillHandoffStore()
        lateinit var token: String
        lateinit var launcher: FillHandoffLauncher
        launcher = FillHandoffLauncher(store) { token = it; launcher.cancel() }
        assertFalse(launcher.open(payload()))
        assertNull(store.consume(token))
    }

    @Test fun `an old launch failure cannot clear a replacement after reentrant cancellation`() {
        val store = FillHandoffStore()
        val replacement = payload()
        val tokens = mutableListOf<String>()
        lateinit var launcher: FillHandoffLauncher
        launcher = FillHandoffLauncher(store) {
            tokens.add(it)
            if (tokens.size == 1) {
                launcher.cancel()
                assertTrue(launcher.open(replacement))
                throw IllegalStateException("old launch failed")
            }
        }
        assertFalse(launcher.open(payload()))
        assertNull(store.consume(tokens.first()))
        assertSame(replacement, store.consume(tokens.last()))
    }
}
