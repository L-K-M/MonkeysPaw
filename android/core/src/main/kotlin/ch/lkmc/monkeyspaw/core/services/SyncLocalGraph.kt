package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*

/** Local recovery and access share the authenticated engine's exact stores and journal.
 * Construct on IO before ordinary reads. This graph has no credential or network capability.
 */
class SyncLocalGraph(
    library: LibraryService, libraryOperations: SyncFileOperations,
    dataFiles: StateStore, dataOperations: SyncFileOperations,
    libraryRoot: String,
) {
    private val root = SyncLibraryRoot(libraryRoot)
    val states = SyncStateStore(dataFiles, dataOperations)
    val accounts = SyncAccountStore(dataFiles, dataOperations)
    internal val graph = makeSyncGraph(library, libraryOperations, dataFiles, dataOperations, states, accounts)
    val access = GroupAccessService(library, states, accounts, libraryRoot)

    /** Non-secret UI state when authentication is stopped; never resolve a token or verify /me. */
    fun accountMetadata(): SyncAccountSnapshot {
        val connection = accounts.loadConnection()
        return SyncAccountSnapshot(account = connection.account,
            cleanup = SyncAccountCleanup(secretFailures = connection.cleanupConnections))
    }

    /** Non-secret admission check before a native scheduler may resolve credentials. */
    fun enabledConnectionID(): java.util.UUID? = accounts.loadConnection().let {
        if (it.activation == SyncAccountActivation.ENABLED) it.account?.connectionID else null
    }

    /** Validate metadata before composition may automatically create a fresh library root. */
    val requiresExistingRoot: Boolean get() {
        val connection = accounts.loadConnection()
        val state = states.loadForAccountTransition()
        if (state != null && state.binding.root != root ||
            graph.journal.pending?.nextState?.binding?.root?.let { it != root } == true) throw SyncError.BindingMismatch
        return state != null || connection.account != null || accounts.binding(root) != null || graph.journal.pending != null
    }

    /** Only before startup reads, or after the authenticated engine has stopped and drained. */
    fun recover() {
        if (states.snapshot.value?.binding?.root?.let { it != root } == true ||
            graph.journal.pending?.nextState?.binding?.root?.let { it != root } == true) throw SyncError.BindingMismatch
        if (graph.journal.replayLocal(root) != SyncApplyOutcome.Committed) throw LibraryError.RecoveryRequired
        requiresExistingRoot
    }
}

internal fun makeSyncGraph(library: LibraryService, operations: SyncFileOperations, files: StateStore,
                           dataOperations: SyncFileOperations, states: SyncStateStore, accounts: SyncAccountStore): SyncEngineGraph {
    val mutations = SyncLibraryMutations(library, operations)
    return SyncEngineGraph(files, states, accounts, mutations,
        SyncApplyJournal(files, dataOperations, mutations, states, accounts), SyncPendingOperationStore(files, dataOperations))
}
