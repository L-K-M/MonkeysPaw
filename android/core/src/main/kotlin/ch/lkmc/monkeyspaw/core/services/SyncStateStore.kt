package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.SyncFileFlushing

/** One active private state, checked against its account/root on every ordinary operation. */
class SyncStateStore(files: StateStore, operations: SyncFileFlushing) {
    private val persistence = SyncPersistence(files, operations, "sync/state.json", SyncStateJson.codec)

    internal val snapshot: SyncStoreSnapshot<SyncState> get() = persistence.snapshot

    /** Stopped account transitions alone may inspect the previous binding. */
    internal fun loadForAccountTransition(): SyncState? = persistence.load()

    internal fun load(binding: SyncLibraryIdentity): SyncState? = persistence.load().also { checkBinding(it, binding) }

    internal fun update(binding: SyncLibraryIdentity, change: (SyncState) -> SyncState) = persistence.update { current ->
        checkBinding(current, binding)
        change(current ?: SyncState(binding)).also { checkBinding(it, binding) }
    }

    /** Ownership and holds must be committed before account/root replacement. */
    internal fun reset(binding: SyncLibraryIdentity) = persistence.reset(SyncState(binding))
    /** Sign-out preserves the independent ownership document and library. */
    internal fun clear() = persistence.reset(null)

    internal fun blockForRecovery(retaining: SyncState?) = persistence.blockForRecovery(retaining)

    internal fun recover(binding: SyncLibraryIdentity, validate: (SyncState?) -> Unit = {}): SyncState? =
        persistence.recover { state -> checkBinding(state, binding); validate(state) }

    private fun checkBinding(state: SyncState?, binding: SyncLibraryIdentity) {
        if (state != null && state.binding != binding) throw SyncError.BindingMismatch
    }
}
