package ch.lkmc.monkeyspaw.core.domain.sync

import java.time.Instant

enum class SyncStatus { IDLE, SYNCING, OFFLINE, NEEDS_SIGN_IN, HAS_CONFLICTS, SYNC_ERROR }
enum class SyncPhase { IDLE, RECOVERING, COLLECTING, RESYNCING, RECONCILING, SCANNING, GROUP_FOLDERS, PUSHING }
enum class SyncBlockingIssue { ROOT_UNAVAILABLE, INVALID_STATE, INVALID_PROTOCOL, RECOVERY_REQUIRED }
enum class SyncExecutionMode { FOREGROUND, BACKGROUND }
enum class SyncRootHealth { AVAILABLE, UNAVAILABLE }
enum class SyncStopResult { STOPPED, BUSY, RECOVERY_REQUIRED }

/** Committed sync changes refresh local consumers without creating a new sync trigger. */
enum class SyncChangeOrigin { USER, SYNC }

data class SyncFileDetail internal constructor(val path: String, val code: String) {
    override fun toString(): String = "<sync file detail>"
}

data class SyncCounts internal constructor(
    val pulled: Int = 0, val pushed: Int = 0, val fileErrors: Int = 0,
    val conflicts: Int = 0, val held: Int = 0, val pending: Int = 0,
)

/** §26 S9: the last completed provider-settings step outcome on this pass. */
enum class ProviderSyncOutcome(val rawValue: String) {
    SYNCED("synced"), UNCHANGED("unchanged"), KEY_REQUIRED("keyRequired"),
    DECRYPT_FAILED("decryptFailed"), APPLY_FAILED("applyFailed")
}

/** A partial pass never advances lastSuccess. Enabled is independent of status. */
class SyncReport internal constructor(
    val enabled: Boolean = false,
    val phase: SyncPhase = SyncPhase.IDLE,
    val lastSuccess: Instant? = null,
    val counts: SyncCounts = SyncCounts(),
    details: List<SyncFileDetail> = emptyList(),
    val blockingIssue: SyncBlockingIssue? = null,
    val needsSignIn: Boolean = false,
    val offline: Boolean = false,
    val retrying: Boolean = false,
    val providerSync: ProviderSyncOutcome? = null,
) {
    val details = details.syncListCopy()
    val status: SyncStatus get() = when {
        needsSignIn -> SyncStatus.NEEDS_SIGN_IN
        blockingIssue != null -> SyncStatus.SYNC_ERROR
        phase != SyncPhase.IDLE -> SyncStatus.SYNCING
        offline -> SyncStatus.OFFLINE
        counts.fileErrors > 0 || counts.pending > 0 || retrying -> SyncStatus.SYNC_ERROR
        counts.conflicts > 0 -> SyncStatus.HAS_CONFLICTS
        else -> SyncStatus.IDLE
    }

    internal fun copy(
        enabled: Boolean = this.enabled, phase: SyncPhase = this.phase, lastSuccess: Instant? = this.lastSuccess,
        counts: SyncCounts = this.counts, details: List<SyncFileDetail> = this.details,
        blockingIssue: SyncBlockingIssue? = this.blockingIssue, needsSignIn: Boolean = this.needsSignIn,
        offline: Boolean = this.offline, retrying: Boolean = this.retrying,
        providerSync: ProviderSyncOutcome? = this.providerSync,
    ) = SyncReport(enabled, phase, lastSuccess, counts, details, blockingIssue, needsSignIn, offline, retrying,
        providerSync)

    override fun equals(other: Any?): Boolean = other is SyncReport && enabled == other.enabled && phase == other.phase &&
        lastSuccess == other.lastSuccess && counts == other.counts && details == other.details &&
        blockingIssue == other.blockingIssue && needsSignIn == other.needsSignIn && offline == other.offline &&
        retrying == other.retrying && providerSync == other.providerSync
    override fun hashCode(): Int = listOf(enabled, phase, lastSuccess, counts, details, blockingIssue, needsSignIn,
        offline, retrying, providerSync).hashCode()
    override fun toString(): String = "<sync report>"
}

/** Non-secret scheduler facts. Native scheduling persists its own wall-time due state. */
data class SyncSchedulingState internal constructor(
    val epoch: Long = 0,
    val triggerVersion: Long = 0,
    val consumedVersion: Long = 0,
    val retryCount: Int = 0,
    val nextEligibleAt: Instant? = null,
    val needsSignIn: Boolean = false,
)
