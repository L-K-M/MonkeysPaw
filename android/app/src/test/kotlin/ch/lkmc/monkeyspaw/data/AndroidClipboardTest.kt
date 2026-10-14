package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StoreError
import java.util.concurrent.CancellationException
import kotlin.test.*

internal class AndroidClipboardTest {
    @Test
    fun `constructing the driver does not read and a write carries raw sensitive text without reading`() {
        val access = FakeAccess()
        val driver = AndroidClipboard(access)
        assertEquals(0, access.reads)
        assertEquals(0, access.writes)
        val raw = "{{raw}}\n\t<value>"
        driver.writeText(raw)
        assertTrue(access.text == raw)
        assertEquals(mapOf("android.content.extra.IS_SENSITIVE" to true), access.extras)
        assertEquals(0, access.reads)
        assertEquals(1, access.writes)
    }

    @Test
    fun `null empty and raw reads complete once on the calling thread`() {
        for (text in listOf(null, "", "{{raw}}\n")) {
            val access = FakeAccess().apply { this.text = text }
            val driver = AndroidClipboard(access)
            val thread = Thread.currentThread()
            val results = mutableListOf<String?>()
            driver.readText { assertSame(thread, Thread.currentThread()); results.add(it) }
            assertEquals(1, results.size)
            assertTrue(results.single() == text)
            assertEquals(1, access.reads)
            assertEquals(0, access.writes)
        }
    }

    @Test
    fun `a service read failure completes once as unavailable without exposing its body`() {
        val access = FakeAccess().apply { error = SecurityException("private system service error") }
        val results = mutableListOf<String?>()
        AndroidClipboard(access).readText(results::add)
        assertEquals(1, results.size)
        assertNull(results.single())
        assertEquals(1, access.reads)
    }

    @Test
    fun `a completion failure is not swallowed or completed a second time`() {
        val failure = IllegalStateException()
        var completions = 0
        val error = assertFailsWith<IllegalStateException> {
            AndroidClipboard(FakeAccess()).readText { completions++; throw failure }
        }
        assertSame(failure, error)
        assertEquals(1, completions)
    }

    @Test
    fun `write failure is sanitized preserves prior clipboard and never falls back to reading`() {
        val access = FakeAccess().apply { text = "prior"; error = SecurityException("private system service error") }
        val error = assertFailsWith<StoreError.IOFailure> { AndroidClipboard(access).writeText("new") }
        assertNull(error.cause)
        assertTrue(access.text == "prior")
        assertEquals(0, access.reads)
        assertEquals(1, access.writes)
    }

    @Test
    fun `write cancellation and interruption preserve their control signal`() {
        val cancelled = CancellationException()
        val access = FakeAccess().apply { error = cancelled }
        assertSame(cancelled, assertFailsWith<CancellationException> { AndroidClipboard(access).writeText("value") })
        val interrupted = InterruptedException()
        access.error = interrupted
        try {
            assertSame(interrupted, assertFailsWith<InterruptedException> { AndroidClipboard(access).writeText("value") })
            assertTrue(Thread.currentThread().isInterrupted)
        } finally { Thread.interrupted() }
    }

    private class FakeAccess : AndroidClipboardAccess {
        var text: String? = null
        var extras: Map<String, Boolean>? = null
        var reads = 0
        var writes = 0
        var error: Exception? = null
        override fun readText(): String? {
            reads++
            error?.let { throw it }
            return text
        }
        override fun writeText(text: String, extras: Map<String, Boolean>) {
            writes++
            error?.let { throw it }
            this.text = text
            this.extras = extras
        }
    }
}
