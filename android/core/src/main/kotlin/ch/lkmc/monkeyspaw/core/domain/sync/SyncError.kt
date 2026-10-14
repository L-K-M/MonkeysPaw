package ch.lkmc.monkeyspaw.core.domain.sync

import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssueCode
import ch.lkmc.monkeyspaw.core.ports.StoreError

/** Fixed diagnostics only, without input, parser exceptions or driver causes. */
sealed class SyncError private constructor(code: String) : Exception(code, null, false, true) {
    data object CorruptFile : SyncError("corruptFile")
    data class FutureVersion(val version: Long) : SyncError("futureVersion")
    data class UnsupportedVersion(val version: Long) : SyncError("unsupportedVersion")
    data class ReadFailed(val error: StoreError) : SyncError("readFailed")
    data class WriteFailed(val error: StoreError) : SyncError("writeFailed")
    data object DurabilityUncertain : SyncError("durabilityUncertain")
    data object BindingMismatch : SyncError("bindingMismatch")
    data object InvalidAccount : SyncError("invalidAccount")
    data object InvalidRoot : SyncError("invalidRoot")
    data object InvalidScope : SyncError("invalidScope")
    data object InvalidHash : SyncError("invalidHash")
    data object InvalidState : SyncError("invalidState")

    final override fun toString(): String = message.orEmpty()
}

internal sealed interface SyncIssueCode {
    val rawValue: String
    data class Content(val code: PromptIssueCode) : SyncIssueCode {
        override val rawValue: String get() = code.rawValue
    }
    data class Path(val code: SyncPathIssueCode) : SyncIssueCode {
        override val rawValue: String get() = code.wireCode
    }
    data object IDMismatch : SyncIssueCode { override val rawValue = "prompt.id_mismatch" }
    data object NotFound : SyncIssueCode { override val rawValue = "not_found" }
    data object Forbidden : SyncIssueCode { override val rawValue = "forbidden" }
    data object PathClash : SyncIssueCode { override val rawValue = "sync.path_clash" }
    data object LocalVisibility : SyncIssueCode { override val rawValue = "sync.local_visibility" }

    companion object {
        fun parse(raw: String): SyncIssueCode =
            PromptIssueCode.entries.firstOrNull { it.rawValue == raw }?.let(::Content)
                ?: SyncPathIssueCode.entries.firstOrNull { it.wireCode == raw }?.let(::Path)
                ?: listOf(IDMismatch, NotFound, Forbidden, PathClash, LocalVisibility)
                    .firstOrNull { it.rawValue == raw } ?: throw SyncError.InvalidState
    }
}

internal enum class SyncOperation(val rawValue: String) { PUT("put"), DELETE("delete"), MOVE("move") }

internal data class SyncInputFingerprint(
    val contentHash: SyncHash,
    val pathHash: SyncHash,
    val scope: SyncScopeKey,
    val accessGeneration: Long,
    val operation: SyncOperation,
) {
    init { if (accessGeneration < 0) throw SyncError.InvalidState }

    constructor(bytes: ByteArray, path: String, scope: SyncScopeKey, accessGeneration: Long, operation: SyncOperation) :
        this(SyncHash.of(bytes), SyncHash.of(syncValidated { path.encodeToByteArray(throwOnInvalidSequence = true) }),
            scope, accessGeneration, operation)
}

internal data class SyncPromptError(val code: SyncIssueCode, val fingerprint: SyncInputFingerprint)

internal inline fun <T> syncValidated(body: () -> T): T = try { body() }
catch (_: Exception) { throw SyncError.InvalidState }
