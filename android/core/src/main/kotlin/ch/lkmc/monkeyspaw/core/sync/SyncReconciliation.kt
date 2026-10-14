package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.SyncBytes
import ch.lkmc.monkeyspaw.core.ports.SyncFileMode
import ch.lkmc.monkeyspaw.core.services.*
import java.util.Collections

internal sealed class SyncReconciliationError private constructor() : Exception("Sync reconciliation failed.", null, false, true) {
    data object InvalidPull : SyncReconciliationError()
    data object InvalidLocalSnapshot : SyncReconciliationError()
    data object UnavailableLibrary : SyncReconciliationError()
    data object BindingMismatch : SyncReconciliationError()
    class GroupFolderRequired(val id: ULID) : SyncReconciliationError()
    class SnapshotRequired(val scope: SyncScopeKey) : SyncReconciliationError()
    data object RequiresPolicy : SyncReconciliationError()
    final override fun toString(): String = "<sync reconciliation error>"
}

/** Full rooted inventory, with durable raw/account holds supplied before identity matching. */
internal class SyncReconciliationSnapshot(
    val binding: SyncLibraryIdentity,
    files: List<SyncLibraryFile>,
    val availability: Availability = Availability.AVAILABLE,
    heldPaths: Set<String> = emptySet(),
) {
    enum class Availability { AVAILABLE, UNAVAILABLE }
    val files = files.syncListCopy()
    val heldPaths = heldPaths.frozenSet()
    override fun toString(): String = "<reconciliation snapshot>"
}

internal class SyncReconciliationRemote(
    val id: ULID,
    val scope: SyncScopeKey,
    val path: String,
    val libraryPath: String,
    val rev: Long,
    bytes: ByteArray,
    val hash: SyncHash,
    val mode: SyncFileMode,
) {
    private val saved = SyncBytes(bytes)
    val bytes: ByteArray get() = saved.copyBytes()
    override fun toString(): String = "<reconciliation remote>"
}

/** Baselines carry actual identity, bytes and incarnation; distinct occupants require replanning. */
internal class SyncReconciliationInstall(
    val remote: SyncReconciliationRemote,
    val source: SyncLibraryFile?,
    val target: SyncLibraryFile?,
) {
    override fun toString(): String = "<reconciliation install>"
}

internal class SyncReconciliationPreservation(
    val id: ULID,
    val reason: Reason,
    val local: SyncLibraryFile,
    val installation: SyncReconciliationInstall?,
) {
    enum class Reason { DIRTY_UPSERT, DIRTY_REMOVAL, RESTORE_MISSING, RESTORE_VIEWER }
    override fun toString(): String = "<reconciliation preservation>"
}

/** Push re-reads this version on the adopted revision only after the entire apply commits. */
internal class SyncReconciliationRestoreUpdate(val remote: SyncReconciliationRemote, val local: SyncLibraryFile) {
    override fun toString(): String = "<reconciliation restore update>"
}

internal sealed class SyncReconciliationOperation {
    class Install(val installation: SyncReconciliationInstall) : SyncReconciliationOperation()
    class Remove(val file: SyncLibraryFile) : SyncReconciliationOperation()
    class Preserve(val preservation: SyncReconciliationPreservation) : SyncReconciliationOperation()
    /** Z10 resolves ID-first / identity-neutral adoption, then replans. */
    class Adoption(val remote: SyncReconciliationRemote, val local: SyncLibraryFile) : SyncReconciliationOperation()
    /** Z9 relocates the occupant with its identity and keyed history intact. */
    class PathClash(val remote: SyncReconciliationRemote, val occupant: SyncLibraryFile) : SyncReconciliationOperation()
    class LocalVisibility(val remote: SyncReconciliationRemote) : SyncReconciliationOperation()
    /** Z12 resolves folder lifecycle before cursor commit. */
    class RemovedScope(val scope: SyncScopeKey) : SyncReconciliationOperation()
    class RestoreUpdate(val update: SyncReconciliationRestoreUpdate) : SyncReconciliationOperation()
    final override fun toString(): String = "<reconciliation operation>"
}

internal class SyncReconciliationPlan(
    val mode: Mode,
    val expectedState: SyncState?,
    /** Prospective only; publish through the apply journal. */
    val nextState: SyncState,
    operations: List<SyncReconciliationOperation>,
    occupiedPaths: Set<String>,
    localIdentities: Set<PromptIdentity>,
) {
    enum class Mode { NORMAL, FIRST_SYNC, RESTORE }
    val operations = operations.syncListCopy()
    val occupiedPaths = occupiedPaths.frozenSet()
    val localIdentities = localIdentities.frozenSet()
    val restoreUpdates: List<SyncReconciliationRestoreUpdate> get() =
        operations.filterIsInstance<SyncReconciliationOperation.RestoreUpdate>().map { it.update }.syncListCopy()
    override fun toString(): String = "<reconciliation plan>"
}

/** Z9 selects stable copy names/IDs. Reuse carries a checked unchanged publication. */
internal class SyncReconciliationCopy(val edit: SyncLibraryEdit, val origin: SyncPromptOrigin) {
    override fun toString(): String = "<reconciliation copy>"
}

private fun <T> Set<T>.frozenSet(): Set<T> = Collections.unmodifiableSet(LinkedHashSet(this))
