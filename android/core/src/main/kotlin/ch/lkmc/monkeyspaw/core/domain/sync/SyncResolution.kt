package ch.lkmc.monkeyspaw.core.domain.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactDiff
import ch.lkmc.monkeyspaw.core.ports.SyncBytes
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.services.SyncLibraryFile
import ch.lkmc.monkeyspaw.core.sync.SyncConflictHead
import ch.lkmc.monkeyspaw.core.sync.SyncWorkPermit
import ch.lkmc.monkeyspaw.core.syncapi.Role
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

enum class SyncResolutionAction { KEEP_SERVER, KEEP_MINE, KEEP_BOTH }

sealed class SyncResolutionFailure private constructor() : Exception("Conflict resolution failed.", null, false, true) {
    data object Inactive : SyncResolutionFailure()
    data object Busy : SyncResolutionFailure()
    data object InvalidCopy : SyncResolutionFailure()
    data object StaleCopy : SyncResolutionFailure()
    data object StaleSession : SyncResolutionFailure()
    data object StaleAccess : SyncResolutionFailure()
    data object OriginalUnavailable : SyncResolutionFailure()
    data object AccessDenied : SyncResolutionFailure()
    data object InvalidCandidate : SyncResolutionFailure()
    data object NeedsSignIn : SyncResolutionFailure()
    data object Offline : SyncResolutionFailure()
    data object RecoveryRequired : SyncResolutionFailure()
    data object OperationFailed : SyncResolutionFailure()
    final override fun toString(): String = "<sync resolution failure>"
}

/** Own one per resolve view. Cancel also revokes a load whose reply has not arrived yet. */
class SyncResolutionSession {
    private val cancelled = AtomicBoolean()
    private val lock = Any()
    private var work: SyncWorkPermit? = null
    fun cancel() = synchronized(lock) { cancelled.set(true); work?.revoke(); Unit }
    internal fun check() { if (cancelled.get()) throw SyncResolutionFailure.StaleSession }
    internal fun bind(permit: SyncWorkPermit) = synchronized(lock) {
        check()
        if (work != null) throw SyncResolutionFailure.Busy
        work = permit
    }
    internal fun release(permit: SyncWorkPermit) = synchronized(lock) { if (work === permit) work = null }
    override fun toString(): String = "<sync resolution session>"
}

/** Only the service can mint this capability; returned arrays never expose its baselines. */
class SyncResolutionPreview internal constructor(
    val copyIdentity: PromptIdentity,
    val copyPath: String,
    val originalID: ULID?,
    candidateBytes: ByteArray?,
    val diff: ArtifactDiff?,
    val mineRefusal: SyncResolutionFailure?,
    internal val baseline: SyncLibraryFile,
    internal val original: SyncLibraryFile?,
    internal val head: SyncConflictHead?,
    internal val binding: SyncLibraryIdentity,
    internal val graph: Any,
    internal val epoch: Long,
    internal val accessGeneration: Long,
    internal val accessVersions: List<Long>,
    internal val role: Role?,
    internal val session: SyncResolutionSession,
) {
    val id: UUID = UUID.randomUUID()
    private val candidate = candidateBytes?.let(::SyncBytes)
    private val consumed = AtomicBoolean()
    val serverBytes: ByteArray? get() = head?.bytes
    val candidateBytes: ByteArray? get() = candidate?.copyBytes()
    val canKeepMine: Boolean get() = mineRefusal == null && diff != null
    val canKeepServer: Boolean get() = head != null
    val canKeepBoth: Boolean get() = true

    internal fun check() {
        session.check()
        if (consumed.get()) throw SyncResolutionFailure.StaleSession
    }
    internal fun consume() { consumed.set(true) }
    override fun toString(): String = "<sync resolution preview>"
}

sealed interface SyncResolutionResult {
    data class Resolved(val action: SyncResolutionAction) : SyncResolutionResult
    /** Show this replacement diff and require another explicit decision. */
    class Refreshed(val preview: SyncResolutionPreview) : SyncResolutionResult {
        override fun toString(): String = "<refreshed sync resolution>"
    }
}
