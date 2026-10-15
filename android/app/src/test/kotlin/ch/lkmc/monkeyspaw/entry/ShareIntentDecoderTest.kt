package ch.lkmc.monkeyspaw.entry

import android.content.Intent.*
import ch.lkmc.monkeyspaw.core.domain.Limits
import kotlin.test.*

internal class ShareIntentDecoderTest {
    @Test fun `plain and styled sequences become a literal immutable snapshot`() {
        val text = " \t{{clipboard}} e\u0301 🐒\r\n\u2028 "
        val buffer = StringBuilder(text)
        val styled = object : CharSequence by buffer { override fun toString() = buffer.toString() }
        for (value in listOf(text, styled)) {
            val snapshot = assertNotNull(decode(value))
            assertEquals(CapturedTextRequest.Source.SHARE, snapshot.source)
            assertTrue(snapshot.text == text)
            assertTrue(snapshot.toString().contains("<redacted>"))
            assertFalse(snapshot.toString().contains(text))
        }
        val snapshot = assertNotNull(decode(styled))
        buffer.clear().append("changed")
        assertTrue(snapshot.text == text)
        assertTrue(decode(" \n\t ")?.text == " \n\t ")
    }

    @Test fun `unsupported action and exact MIME are rejected before reading extras`() {
        for (action in listOf(null, "", ACTION_PROCESS_TEXT, ACTION_SEND_MULTIPLE, ACTION_VIEW, "ACTION_SEND")) {
            var read = false
            assertNull(ShareIntentDecoder.decode(action, "text/plain") { read = true; error("Must not read extras") })
            assertFalse(read, "Extras read for unsupported action: $action")
        }
        for (mime in listOf(null, "", "text/*", "text/html", "TEXT/PLAIN", "text/plain; charset=utf-8")) {
            var read = false
            assertNull(ShareIntentDecoder.decode(ACTION_SEND, mime) { read = true; error("Must not read extras") })
            assertFalse(read, "Extras read for unsupported MIME: $mime")
        }
    }

    @Test fun `subject HTML URI stream selection flags and forged routes are ignored`() {
        val extras = mapOf(EXTRA_TEXT to "https://example.invalid/path", EXTRA_SUBJECT to "Subject",
            EXTRA_HTML_TEXT to "<b>HTML</b>", EXTRA_STREAM to "content://ignored/stream",
            EXTRA_PROCESS_TEXT_READONLY to false, FillActivity.promptPathExtra to "../../ignored",
            FillRoute.handoffTokenExtra to "ignored")
        val keys = mutableListOf<String>()
        val request = ShareIntentDecoder.decode(ACTION_SEND, "text/plain") {
            keys.add(it)
            extras[it]
        }
        assertEquals(listOf(EXTRA_TEXT), keys)
        assertEquals(CapturedTextRequest.Source.SHARE, request?.source)
        assertTrue(request?.text == extras[EXTRA_TEXT])
        assertNull(ShareIntentDecoder.decode(ACTION_SEND, "text/plain") { extras.filterKeys { it != EXTRA_TEXT }[it] })
    }

    @Test fun `missing empty wrong type and ill-formed Unicode are rejected`() {
        for (value in listOf(null, false, 9, byteArrayOf(1), listOf("value"), "", "\ud800", "\udc00", "a\ud800b")) {
            assertNull(decode(value))
        }
    }

    @Test fun `throwing extraction and sequence conversion fail without retaining diagnostic content`() {
        assertNull(ShareIntentDecoder.decode(ACTION_SEND, "text/plain") { error("Untrusted parcel diagnostic") })
        assertNull(decode(object : CharSequence by "value" {
            override fun toString(): String = error("Untrusted text diagnostic")
        }))
        assertNull(decode(object : CharSequence by "value" {
            override val length: Int get() = error("Untrusted length diagnostic")
        }))
    }

    @Test fun `inclusive UTF-8 cap rejects oversized text without partial capture`() {
        val cap = Limits.capturedTextCapBytes
        for (boundary in listOf("a".repeat(cap), "🐒".repeat(cap / 4), "€".repeat(cap / 3) + "a")) {
            assertTrue(decode(boundary)?.text == boundary)
            assertNull(decode(boundary + "a"))
        }
        var snapshotted = false
        assertNull(decode(object : CharSequence by "small" {
            override val length = cap + 1
            override fun toString(): String {
                snapshotted = true
                error("Must reject before snapshotting")
            }
        }))
        assertFalse(snapshotted, "Oversized sequence copied before rejection")
        assertNull(decode(object : CharSequence by "small" {
            override fun toString() = "a".repeat(cap + 1)
        }))
    }

    private fun decode(text: Any?) = ShareIntentDecoder.decode(ACTION_SEND, "text/plain") {
        assertEquals(EXTRA_TEXT, it)
        text
    }
}
