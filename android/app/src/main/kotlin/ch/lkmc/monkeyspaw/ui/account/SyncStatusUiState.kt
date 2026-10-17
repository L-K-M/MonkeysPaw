package ch.lkmc.monkeyspaw.ui.account

import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.sync.*
import java.time.ZoneId
import java.time.format.DateTimeFormatter

internal data class SyncStatusUiState(
    val title: Int = R.string.sync_disabled,
    val enabled: Boolean = false,
    val status: SyncStatus = SyncStatus.IDLE,
    val counts: SyncCounts? = null,
    val details: List<SyncFileDetail> = emptyList(),
    val lastSuccess: String? = null,
    val blockingText: Int? = null,
    val canSync: Boolean = false,
)

/** Use Core's precedence, including disabled reports that still require sign-in or recovery. */
internal fun syncStatus(report: SyncReport?, zone: ZoneId = ZoneId.systemDefault()): SyncStatusUiState {
    if (report == null) return SyncStatusUiState()
    val title = when (report.status) {
        SyncStatus.NEEDS_SIGN_IN -> R.string.sync_needs_sign_in
        SyncStatus.SYNC_ERROR -> R.string.sync_errors
        SyncStatus.SYNCING -> if (report.phase == SyncPhase.RESYNCING) R.string.sync_resyncing else R.string.sync_syncing
        SyncStatus.OFFLINE -> R.string.sync_offline
        SyncStatus.HAS_CONFLICTS -> R.string.sync_conflicts
        SyncStatus.IDLE -> if (report.enabled) R.string.sync_idle else R.string.sync_disabled
    }
    val blocking = when (report.blockingIssue) {
        SyncBlockingIssue.ROOT_UNAVAILABLE -> R.string.sync_root_unavailable
        SyncBlockingIssue.INVALID_STATE -> R.string.sync_invalid_state
        SyncBlockingIssue.INVALID_PROTOCOL -> R.string.sync_invalid_protocol
        SyncBlockingIssue.RECOVERY_REQUIRED -> R.string.sync_recovery_required
        null -> null
    }
    return SyncStatusUiState(title, report.enabled, report.status, report.counts, report.details,
        report.lastSuccess?.let { DateTimeFormatter.ofPattern("uuuu-MM-dd HH:mm:ss z").withZone(zone).format(it) },
        blocking, report.enabled && !report.needsSignIn && report.blockingIssue == null && report.phase == SyncPhase.IDLE)
}
