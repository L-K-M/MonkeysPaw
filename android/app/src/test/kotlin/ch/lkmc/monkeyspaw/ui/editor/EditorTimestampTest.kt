package ch.lkmc.monkeyspaw.ui.editor

import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.test.*

internal class EditorTimestampTest {
    private val instant = Instant.parse("2026-10-14T22:30:15Z")

    @Test fun `revision timestamps localize the date for each supported locale`() {
        val utc = ZoneId.of("UTC")
        val us = editorTimestamp(instant, Locale.US, utc)
        assertTrue(us.contains("Oct"), us)
        assertTrue(us.contains("14"), us)
        val germany = editorTimestamp(instant, Locale.GERMANY, utc)
        assertTrue(germany.contains("14.10.2026"), germany)
        val france = editorTimestamp(instant, Locale.FRANCE, utc)
        assertTrue(france.lowercase(Locale.FRANCE).contains("oct"), france)
        assertNotEquals(us, germany)
        assertNotEquals(us, france)
    }

    @Test fun `the viewer zone decides the rendered day and hour`() {
        val utc = editorTimestamp(instant, Locale.US, ZoneId.of("UTC"))
        val tokyo = editorTimestamp(instant, Locale.US, ZoneId.of("Asia/Tokyo"))
        assertNotEquals(utc, tokyo)
        assertTrue(utc.contains("14"), utc)
        assertTrue(tokyo.contains("15"), tokyo)
    }

    @Test fun `output is localized text rather than the raw instant`() {
        val rendered = editorTimestamp(instant, Locale.US, ZoneId.of("UTC"))
        assertNotEquals(instant.toString(), rendered)
        assertFalse(rendered.contains('T'), rendered)
        assertFalse(rendered.endsWith('Z'), rendered)
    }

    @Test fun `system defaults render without explicit locale or zone`() {
        assertTrue(editorTimestamp(instant).isNotBlank())
    }
}
