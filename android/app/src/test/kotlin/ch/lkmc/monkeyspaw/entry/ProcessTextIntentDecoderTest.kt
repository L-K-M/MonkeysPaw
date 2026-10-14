package ch.lkmc.monkeyspaw.entry

import android.content.Intent.*
import ch.lkmc.monkeyspaw.core.domain.Limits
import kotlin.test.*

internal class ProcessTextIntentDecoderTest {
    @Test fun `only actual Boolean false enables editable selection`() {
        val forged = object {
            override fun equals(other: Any?) = other == false
            override fun hashCode() = 0
        }
        for (flag in listOf(null, true, "false", 0, 1, forged)) {
            assertEquals(CapturedTextRequest.Source.READ_ONLY_SELECTION, decode(flag = flag)?.source)
        }
        assertEquals(CapturedTextRequest.Source.EDITABLE_SELECTION, decode(flag = false)?.source)
    }

    @Test fun `snapshot strips sequence styling without changing literal characters`() {
        val text = " \t{{clipboard}} e\u0301 🐒\r\n\u2028 "
        val buffer = StringBuilder(text)
        val styled = object : CharSequence by buffer { override fun toString() = buffer.toString() }
        val snapshot = assertNotNull(decode(text = styled))
        buffer.clear().append("changed")
        assertTrue(snapshot.text == text)
        assertTrue(snapshot.toString().contains("<redacted>"))
        assertFalse(snapshot.toString().contains(text))
        assertTrue(decode(text = " \n\t ")?.text == " \n\t ")
    }

    @Test fun `action and MIME are checked before any extras are read`() {
        for (action in listOf(null, "", ACTION_SEND, ACTION_VIEW, "ACTION_PROCESS_TEXT")) {
            assertNull(ProcessTextIntentDecoder.decode(action, "text/plain") { error("Must not read extras") })
        }
        for (mime in listOf(null, "", "text/*", "text/html", "TEXT/PLAIN", "text/plain; charset=utf-8")) {
            assertNull(ProcessTextIntentDecoder.decode(ACTION_PROCESS_TEXT, mime) { error("Must not read extras") })
        }
    }

    @Test fun `forged routing and unrelated payload extras are never read`() {
        val keys = mutableListOf<String>()
        val snapshot = ProcessTextIntentDecoder.decode(ACTION_PROCESS_TEXT, "text/plain") { key ->
            keys.add(key)
            when (key) {
                EXTRA_PROCESS_TEXT -> "selection"
                EXTRA_PROCESS_TEXT_READONLY -> false
                else -> error("Must not read routes, HTML, streams, URI or caller metadata")
            }
        }
        assertEquals(listOf(EXTRA_PROCESS_TEXT, EXTRA_PROCESS_TEXT_READONLY), keys)
        assertEquals(CapturedTextRequest.Source.EDITABLE_SELECTION, snapshot?.source)
    }

    @Test fun `missing wrong empty malformed and throwing text is rejected safely`() {
        for (payload in listOf(null, false, 9, byteArrayOf(1), listOf("value"), "", "\ud800", "\udc00")) {
            assertNull(decode(text = payload))
        }
        val text = object : CharSequence by "value" {
            override fun toString(): String = error("Untrusted diagnostic")
        }
        assertNull(decode(text = text))
        for (key in listOf(EXTRA_PROCESS_TEXT, EXTRA_PROCESS_TEXT_READONLY)) {
            assertNull(ProcessTextIntentDecoder.decode(ACTION_PROCESS_TEXT, "text/plain") {
                if (it == key) error("Untrusted parcel diagnostic") else "selection"
            })
        }
    }

    @Test fun `UTF-8 bound is inclusive with no partial capture`() {
        val cap = Limits.capturedTextCapBytes
        val boundary = "🐒".repeat(cap / 4)
        assertTrue(decode(text = boundary)?.text == boundary)
        assertNull(decode(text = boundary + "a"))
        assertNull(decode(text = "a".repeat(cap + 1)))
        val oversized = object : CharSequence by "small" {
            override val length = cap + 1
            override fun toString(): String = error("Must reject before snapshotting")
        }
        assertNull(decode(text = oversized))
    }

    private fun decode(text: Any? = "selection", flag: Any? = null) =
        ProcessTextIntentDecoder.decode(ACTION_PROCESS_TEXT, "text/plain") { key ->
            when (key) {
                EXTRA_PROCESS_TEXT -> text
                EXTRA_PROCESS_TEXT_READONLY -> flag
                else -> error("Unexpected extra")
            }
        }
}
