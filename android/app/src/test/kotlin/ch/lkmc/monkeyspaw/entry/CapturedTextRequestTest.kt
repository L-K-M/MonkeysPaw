package ch.lkmc.monkeyspaw.entry

import android.content.Intent.ACTION_PROCESS_TEXT
import android.content.Intent.ACTION_SEND
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.entry.CapturedTextRequest.Rejection
import ch.lkmc.monkeyspaw.entry.CapturedTextRequest.Source
import kotlin.test.*

internal class CapturedTextRequestTest {
    @Test fun selectionDefaultsToReadOnlyUnlessTheFlagIsActuallyBooleanFalse() {
        val forgedFlag = object { override fun equals(other: Any?): Boolean = other == false; override fun hashCode() = 0 }
        for (readOnly in listOf(null, true, "false", "true", 0, 1, forgedFlag)) {
            assertEquals(Source.READ_ONLY_SELECTION, parse(ACTION_PROCESS_TEXT, readOnly = readOnly).source)
        }
        assertEquals(Source.EDITABLE_SELECTION, parse(ACTION_PROCESS_TEXT, readOnly = false).source)
        assertEquals(Source.SHARE, parse(ACTION_SEND, readOnly = false).source)
        assertEquals(Source.SHARE, parse(ACTION_SEND, readOnly = true).source)
    }

    @Test fun onlySupportedActionsAndExactPlainTextMimeAreAccepted() {
        for (action in listOf(null, "", "android.intent.action.SEND_MULTIPLE", "android.intent.action.VIEW", "ACTION_SEND")) {
            assertRejected(Rejection.UNSUPPORTED_ACTION) { parse(action) }
        }
        for (action in listOf(ACTION_SEND, ACTION_PROCESS_TEXT)) {
            for (mime in listOf(null, "", "text/*", "text/html", "TEXT/PLAIN", "text/plain; charset=utf-8", "image/png")) {
                assertRejected(Rejection.UNSUPPORTED_MIME) { parse(action, mime) }
            }
        }
    }

    @Test fun missingMistypedAndEmptyPayloadsFailWithoutRevealingContent() {
        for (action in listOf(ACTION_SEND, ACTION_PROCESS_TEXT)) {
            for (payload in listOf(null, 7, false, byteArrayOf(1, 2), listOf("private payload"))) {
                assertRejected(Rejection.INVALID_TEXT) { parse(action, text = payload) }
            }
            assertRejected(Rejection.EMPTY_TEXT) { parse(action, text = "") }
            assertRejected(Rejection.EMPTY_TEXT) { parse(action, text = StringBuilder()) }
        }
        val throwingText = object : CharSequence by "secret" {
            override fun toString(): String = error("private exception body")
        }
        val error = assertFailsWith<CapturedTextRequest.Rejected> { parse(ACTION_SEND, text = throwingText) }
        assertEquals(Rejection.INVALID_TEXT, error.reason)
        assertNull(error.cause)
        assertFalse(error.toString().contains("private exception body"))
    }

    @Test fun plainSnapshotsPreserveLiteralBracesWhitespaceAndUnicodeWithoutNormalization() {
        val text = " \t{{clipboard}} {{other}} e\u0301 🐒\r\n\u000b\u000c\u0085\u2028\u2029\u0000 "
        for (action in listOf(ACTION_SEND, ACTION_PROCESS_TEXT)) {
            val original = StringBuilder(text)
            val request = parse(action, text = original)
            original.clear().append("changed")
            assertEquals(text, request.text)
            assertContentEquals(text.encodeToByteArray(), request.text.encodeToByteArray())
            assertFalse(request.toString().contains(text))
            assertTrue(request.toString().contains("<redacted>"))
            assertEquals(" \t\r\n ", parse(action, text = " \t\r\n ").text)
        }
    }

    @Test fun utf8CapIsInclusiveForOneTwoThreeAndFourByteScalars() {
        assertEquals(256 * 1024, Limits.capturedTextCapBytes)
        for (action in listOf(ACTION_SEND, ACTION_PROCESS_TEXT)) {
            for (scalar in listOf("a", "é", "€", "🐒")) {
                val width = scalar.encodeToByteArray().size
                for (size in listOf(Limits.capturedTextCapBytes - 1, Limits.capturedTextCapBytes)) {
                    val text = scalar.repeat(size / width) + "a".repeat(size % width)
                    assertEquals(size, text.encodeToByteArray().size)
                    assertEquals(text, parse(action, text = text).text)
                }
                val excess = Limits.capturedTextCapBytes + 1
                val oversized = scalar.repeat(excess / width) + "a".repeat(excess % width)
                assertRejected(Rejection.TOO_LARGE) { parse(action, text = oversized) }
            }
        }
    }

    @Test fun overlargeSequencesAreRejectedBeforeCopyingAndSnapshotsAreRechecked() {
        val overlarge = object : CharSequence by "small" {
            override val length: Int get() = Limits.capturedTextCapBytes + 1
            override fun toString(): String = error("Must not copy an overlarge sequence.")
        }
        assertRejected(Rejection.TOO_LARGE) { parse(ACTION_SEND, text = overlarge) }
        val misleadingLength = object : CharSequence by "small" {
            override fun toString(): String = "a".repeat(Limits.capturedTextCapBytes + 1)
        }
        assertRejected(Rejection.TOO_LARGE) { parse(ACTION_SEND, text = misleadingLength) }
    }

    @Test fun malformedSurrogatesAreRejectedInsteadOfRepairedOrTruncated() {
        for (action in listOf(ACTION_SEND, ACTION_PROCESS_TEXT)) {
            for (text in listOf("\ud800", "\udc00", "\ud800x", "x\udc00", "\ud800\ud800", "🐒\ud800")) {
                assertRejected(Rejection.INVALID_UNICODE) { parse(action, text = text) }
            }
        }
    }

    private fun parse(action: String?, mime: String? = "text/plain", text: Any? = "capture", readOnly: Any? = null) =
        CapturedTextRequest.parse(action, mime, text, readOnly)

    private fun assertRejected(expected: Rejection, block: () -> Unit) {
        val error = assertFailsWith<CapturedTextRequest.Rejected> { block() }
        assertEquals(expected, error.reason)
        assertNull(error.cause)
    }
}
