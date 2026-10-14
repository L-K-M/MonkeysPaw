package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.sync.SyncHash
import ch.lkmc.monkeyspaw.core.services.LibraryPath
import java.time.Instant
import java.util.Locale
import java.util.TimeZone
import kotlin.test.*

class SyncNamingTest {
    private val date = Instant.parse("2026-10-13T21:07:05Z")
    private val user = SyncPathValidator.Scope.USER

    @Test fun fullFoldClashesContinueExistingSequenceAndStopAtTwenty() {
        val occupied = listOf("STRASSE (2).md", "Straße (3).md")
        assertEquals("Straße (4).md", SyncNaming.clash("Straße.md", user, occupied))
        assertEquals("Straße (4).md", SyncNaming.clash("Straße (3).md", user, occupied))
        assertEquals(SyncNaming.pathKey("CAFÉ.md"), SyncNaming.pathKey("Cafe\u0301.md"))
        assertEquals("Name (20).md", SyncNaming.clash("Name.md", user, (2..19).map { "Name ($it).md" }))
        assertFailsWith<SyncNamingError.Exhausted> { SyncNaming.clash("Name.md", user, (2..20).map { "Name ($it).md" }) }
        assertFailsWith<SyncNamingError.Exhausted> { SyncNaming.clash("Name (20).md", user, emptyList()) }
    }

    @Test fun conflictUsesUTCAndSanitizedDeviceDespiteHostLocaleAndTimezone() {
        val locale = Locale.getDefault()
        val zone = TimeZone.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("th-TH"))
            TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Auckland"))
            val first = SyncNaming.conflict("Groups/Team/Hello!.md", "Team (2)", "../Mac/Phone\n", date, emptyList())
            assertEquals("Conflicts/Team (2)/Hello! (conflict Mac-Phone 2026-10-13 2107).md", first)
            assertEquals(first.removeSuffix(".md") + " (2).md",
                SyncNaming.conflict("Hello!.md", "Team (2)", "../Mac/Phone\n", date.plusSeconds(10), listOf(first.uppercase(Locale.ROOT))))
            assertEquals("Conflicts/Personal/a (conflict Device 2026-10-13 2107).md",
                SyncNaming.conflict("a.md", null, "///", date, emptyList()))
        } finally {
            Locale.setDefault(locale)
            TimeZone.setDefault(zone)
        }
    }

    @Test fun graphemeTruncationRetainsModifiersFlagsAndCompleteTimestamp() {
        for (unit in listOf("👩🏽é", "🇨🇭", "q\u0301\u0301")) {
            val stem = unit.repeat(80)
            val path = SyncNaming.conflict("$stem.md", "界".repeat(85), "界".repeat(50), date, emptyList())
            val name = LibraryPath.filename(path)
            val prefix = name.substringBefore(" (conflict ")
            assertTrue(stem.startsWith(prefix))
            assertEquals(0, prefix.length % unit.length)
            assertTrue(name.endsWith(" 2026-10-13 2107).md"))
            bounded(path)
        }
    }

    @Test fun aSingleOversizedGraphemeGetsWholeFallback() {
        val stem = "q" + "\u0301".repeat(100)
        SyncPathValidator.validate("$stem.md", user)
        val result = SyncNaming.conflict("$stem.md", null, "D".repeat(64), date, emptyList())
        assertTrue(LibraryPath.filename(result).startsWith("Prompt (conflict "))
        bounded(result)
    }

    @Test fun filenameAndTotalPathBudgetsReserveClashSuffix() {
        val parent = "a".repeat(255) + "/" + "b".repeat(255) + "/" + "c".repeat(255) + "/"
        val source = parent + "é".repeat(126) + ".md"
        val result = SyncNaming.clash(source, SyncPathValidator.Scope.GROUP, emptyList())
        assertTrue(result.endsWith(" (2).md"))
        assertTrue(result.substringAfterLast('/').substringBefore(" (2)").all { it == 'é' })
        bounded(result)
    }

    @Test fun longCollisionsRetainCompleteTimestampAndSourceHash() {
        val source = "é".repeat(126) + ".md"
        val first = SyncNaming.conflict(source, null, "Device", date, emptyList())
        val suffix = first.substringAfter(" (conflict ").removeSuffix(".md")
        val second = SyncNaming.conflict(source, null, "Device", date, listOf(first))
        assertTrue(second.endsWith(" (conflict $suffix (2).md"))
        bounded(second)
        val hidden = ".hidden/$source"
        val rescue = SyncNaming.rescue(hidden, date, emptyList())
        val collision = SyncNaming.rescue(hidden, date, listOf(rescue))
        val hash = SyncHash.of(hidden.encodeToByteArray()).rawValue.take(12)
        assertTrue(collision.endsWith(" ($hash) (2).md"))
        bounded(collision)
    }

    @Test fun maximumRootedGroupRescueFlattensAndDistinguishesSourceSpelling() {
        val segment = "a".repeat(255)
        val wire = "$segment/$segment/" + "c".repeat(254) + "/d/" + "b".repeat(252) + ".md"
        assertEquals(1024, wire.encodeToByteArray().size)
        val source = "Groups/$segment/$wire"
        assertEquals(1287, source.encodeToByteArray().size)
        val rescue = SyncNaming.rescue(source, date, emptyList())
        assertEquals(3, rescue.split('/').size)
        assertEquals(rescue, SyncNaming.rescue(source, date, emptyList()))
        assertNotEquals(rescue, SyncNaming.rescue(source.replaceFirst("Groups/", "groups/"), date, emptyList()))
        bounded(rescue)
    }

    @Test fun safeRescueKeepsHierarchyWhileForensicsGainVisibleMarkdownName() {
        assertEquals("Conflicts/rescued-2026-10-13/Groups/Team/Nested/a.md",
            SyncNaming.rescue("Groups/Team/Nested/a.md", date, emptyList()))
        assertEquals("Conflicts/rescued-2026-10-13/README.md", SyncNaming.rescue("README.md", date, emptyList()))
        for (source in listOf(".hidden/Unknown.bin", "_hidden/a.md", "a.MD", "Cafe\u0301.md")) {
            val result = SyncNaming.rescue(source, date, emptyList())
            assertEquals(3, result.split('/').size)
            assertTrue(result.endsWith(").md"))
            assertTrue(LibraryPath.isPrompt(result))
            bounded(result)
        }
    }

    @Test fun conflictAllocationHasTwentyUniqueSlotsAndThenFails() {
        val occupied = mutableListOf<String>()
        repeat(20) { occupied.add(SyncNaming.conflict("a.md", null, "Device", date, occupied)) }
        assertEquals(20, occupied.map(SyncNaming::pathKey).toSet().size)
        assertFailsWith<SyncNamingError.Exhausted> { SyncNaming.conflict("a.md", null, "Device", date, occupied) }
    }

    @Test fun invalidDatesAndMalformedPathsFailWithFixedDiagnostics() {
        for (invalid in listOf(Instant.EPOCH.minusNanos(1), Instant.ofEpochSecond(Limits.historyMaxUnixSeconds))) {
            assertFailsWith<SyncNamingError.InvalidDate> { SyncNaming.conflict("a.md", null, "Device", invalid, emptyList()) }
            assertFailsWith<SyncNamingError.InvalidDate> { SyncNaming.rescue("a.md", invalid, emptyList()) }
        }
        bounded(SyncNaming.rescue("a.md", Instant.EPOCH, emptyList()))
        bounded(SyncNaming.rescue("a.md", Instant.ofEpochSecond(Limits.historyMaxUnixSeconds - 1), emptyList()))
        for (invalid in listOf("../a.md", "a\\b.md", "\uD800.md", "a/\u0000.md")) {
            assertFailsWith<SyncNamingError.InvalidPath> { SyncNaming.pathKey(invalid) }
        }
        assertFailsWith<SyncNamingError.InvalidPath> { SyncNaming.conflict("a.md", null, "\uD800", date, emptyList()) }
    }

    private fun bounded(path: String) {
        assertEquals(path, SyncPathValidator.validate(path, user).path)
        assertTrue(path.encodeToByteArray().size <= 1024)
        assertTrue(LibraryPath.filename(path).encodeToByteArray().size <= 255)
    }
}
