package ch.lkmc.monkeyspaw.ui.account

import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.sync.*
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.*

internal class SyncStatusUiStateTest {
    @Test fun `footer uses the six Core statuses and their complete precedence`() {
        var report = SyncReport(enabled = true)
        fun expect(status: SyncStatus, text: Int) {
            val ui = syncStatus(report)
            assertEquals(status, report.status)
            assertEquals(status, ui.status)
            assertEquals(text, ui.title)
        }
        expect(SyncStatus.IDLE, R.string.sync_idle)
        report = report.copy(counts = SyncCounts(conflicts = 1))
        expect(SyncStatus.HAS_CONFLICTS, R.string.sync_conflicts)
        report = report.copy(counts = report.counts.copy(fileErrors = 1))
        expect(SyncStatus.SYNC_ERROR, R.string.sync_errors)
        report = report.copy(offline = true)
        expect(SyncStatus.OFFLINE, R.string.sync_offline)
        report = report.copy(phase = SyncPhase.RESYNCING)
        expect(SyncStatus.SYNCING, R.string.sync_resyncing)
        report = report.copy(blockingIssue = SyncBlockingIssue.RECOVERY_REQUIRED)
        expect(SyncStatus.SYNC_ERROR, R.string.sync_errors)
        report = report.copy(needsSignIn = true)
        expect(SyncStatus.NEEDS_SIGN_IN, R.string.sync_needs_sign_in)
        assertFalse(syncStatus(report).canSync)
    }

    @Test fun `pending retry and errors precede conflicts while held alone is not an error`() {
        for (counts in listOf(SyncCounts(pending = 1, conflicts = 2), SyncCounts(fileErrors = 1, conflicts = 2))) {
            assertEquals(R.string.sync_errors, syncStatus(SyncReport(enabled = true, counts = counts)).title)
        }
        assertEquals(R.string.sync_errors, syncStatus(SyncReport(enabled = true, retrying = true)).title)
        val held = syncStatus(SyncReport(enabled = true, counts = SyncCounts(held = 2)))
        assertEquals(R.string.sync_idle, held.title)
        assertTrue(held.canSync)
    }

    @Test fun `all phases disable duplicate sync and only resync uses snapshot copy`() {
        for (phase in SyncPhase.entries.filter { it != SyncPhase.IDLE }) {
            val ui = syncStatus(SyncReport(enabled = true, phase = phase))
            assertEquals(if (phase == SyncPhase.RESYNCING) R.string.sync_resyncing else R.string.sync_syncing, ui.title)
            assertFalse(ui.canSync)
        }
    }

    @Test fun `disabled remains separate from warnings and preserves all counts errors and last success`() {
        val success = Instant.parse("2026-10-14T12:34:56Z")
        val counts = SyncCounts(pulled = 2, pushed = 3, fileErrors = 4, conflicts = 5, held = 6, pending = 7)
        val details = listOf(SyncFileDetail("bad.md", "metadata.invalid_type"), SyncFileDetail("nested/a.md", "forbidden"))
        val report = SyncReport(counts = counts, details = details, lastSuccess = success)
        val ui = syncStatus(report, ZoneOffset.UTC)
        assertFalse(ui.enabled)
        assertFalse(ui.canSync)
        assertEquals(R.string.sync_errors, ui.title)
        assertEquals(counts, ui.counts)
        assertEquals(details, ui.details)
        assertEquals("2026-10-14 12:34:56 Z", ui.lastSuccess)
        assertNull(syncStatus(SyncReport(offline = true)).lastSuccess)
        assertEquals(R.string.sync_disabled, syncStatus(SyncReport()).title)
        assertEquals(R.string.sync_disabled, syncStatus(null).title)
        assertEquals(R.string.sync_needs_sign_in, syncStatus(SyncReport(needsSignIn = true)).title)
    }

    @Test fun `each blocking reason is visible without driver text and cannot run Sync now`() {
        for (reason in SyncBlockingIssue.entries) {
            val ui = syncStatus(SyncReport(enabled = true, blockingIssue = reason))
            assertEquals(R.string.sync_errors, ui.title)
            assertNotNull(ui.blockingText)
            assertFalse(ui.canSync)
        }
    }
}
