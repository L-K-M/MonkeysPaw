package ch.lkmc.monkeyspaw.ui.conflicts

import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactDiff
import ch.lkmc.monkeyspaw.core.domain.sync.SyncResolutionAction
import ch.lkmc.monkeyspaw.core.domain.sync.SyncResolutionFailure
import java.util.UUID

internal enum class ResolveStatus { CLOSED, LOADING, READY, RESOLVING, RESOLVED, FAILED }
internal enum class ResolveNotice(val message: Int) {
    REFRESHED(R.string.resolve_refreshed),
    CANCELLED(R.string.resolve_cancelled),
}

internal enum class ResolveFailure(val message: Int) {
    INACTIVE(R.string.resolve_inactive),
    BUSY(R.string.resolve_busy),
    INVALID_COPY(R.string.resolve_invalid_copy),
    STALE_COPY(R.string.resolve_stale_copy),
    STALE_SESSION(R.string.resolve_stale_session),
    STALE_ACCESS(R.string.resolve_stale_access),
    ORIGINAL_UNAVAILABLE(R.string.resolve_original_unavailable),
    ACCESS_DENIED(R.string.resolve_access_denied),
    INVALID_CANDIDATE(R.string.resolve_invalid_candidate),
    NEEDS_SIGN_IN(R.string.resolve_needs_sign_in),
    OFFLINE(R.string.resolve_offline),
    RECOVERY_REQUIRED(R.string.resolve_recovery_required),
    OPERATION_FAILED(R.string.resolve_operation_failed),
}

internal fun resolutionFailure(failure: SyncResolutionFailure): ResolveFailure = when (failure) {
    SyncResolutionFailure.Inactive -> ResolveFailure.INACTIVE
    SyncResolutionFailure.Busy -> ResolveFailure.BUSY
    SyncResolutionFailure.InvalidCopy -> ResolveFailure.INVALID_COPY
    SyncResolutionFailure.StaleCopy -> ResolveFailure.STALE_COPY
    SyncResolutionFailure.StaleSession -> ResolveFailure.STALE_SESSION
    SyncResolutionFailure.StaleAccess -> ResolveFailure.STALE_ACCESS
    SyncResolutionFailure.OriginalUnavailable -> ResolveFailure.ORIGINAL_UNAVAILABLE
    SyncResolutionFailure.AccessDenied -> ResolveFailure.ACCESS_DENIED
    SyncResolutionFailure.InvalidCandidate -> ResolveFailure.INVALID_CANDIDATE
    SyncResolutionFailure.NeedsSignIn -> ResolveFailure.NEEDS_SIGN_IN
    SyncResolutionFailure.Offline -> ResolveFailure.OFFLINE
    SyncResolutionFailure.RecoveryRequired -> ResolveFailure.RECOVERY_REQUIRED
    SyncResolutionFailure.OperationFailed -> ResolveFailure.OPERATION_FAILED
}

/** In-memory rendering only. The checked preview capability stays private to the model. */
internal data class ResolveUiState(
    val status: ResolveStatus = ResolveStatus.CLOSED,
    val copyPath: String = "",
    val previewID: UUID? = null,
    val diff: ArtifactDiff? = null,
    val canKeepServer: Boolean = false,
    val canKeepMine: Boolean = false,
    val canKeepBoth: Boolean = false,
    val mineRefusal: ResolveFailure? = null,
    val failure: ResolveFailure? = null,
    val notice: ResolveNotice? = null,
    val resolvedAction: SyncResolutionAction? = null,
    val closePending: Boolean = false,
) {
    val busy: Boolean get() = status == ResolveStatus.LOADING || status == ResolveStatus.RESOLVING
    val canChoose: Boolean get() = status == ResolveStatus.READY && previewID != null && !closePending
    val canRefresh: Boolean get() = !busy && !closePending && status != ResolveStatus.CLOSED && status != ResolveStatus.RESOLVED
    val completionMessage: Int? get() = when (resolvedAction) {
        SyncResolutionAction.KEEP_SERVER -> R.string.resolve_kept_server
        SyncResolutionAction.KEEP_MINE -> R.string.resolve_kept_mine
        SyncResolutionAction.KEEP_BOTH -> R.string.resolve_kept_both
        null -> null
    }

    override fun toString(): String = "<conflict resolution state>"
}
