package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal data class LibraryState(
    val snapshot: LibrarySnapshot,
    val refreshing: Boolean = false,
    val error: Exception? = null,
    val access: GroupAccessSnapshot? = null,
)

internal data class LibrarySearchSnapshot(val state: LibraryState, val matches: List<LocalSearchResult>)

/** One process-wide graph. ViewModels use this worker seam; views only consume immutable state. */
internal class LibraryRepository(
    private val library: LibraryService,
    private val editing: EditingService,
    private val prompts: AndroidPromptStore,
    private val io: CoroutineDispatcher,
    private val beforeRead: suspend () -> Unit = {},
) {
    private val mutex = Mutex()
    private val refreshLock = Any()
    private var refreshFlight: CompletableDeferred<LibraryState>? = null
    private var rootPrepared = false
    private var indexLoaded = false
    private val mutableState = MutableStateFlow(LibraryState(LibrarySnapshot(0, emptyList()), access = library.accessSnapshot))
    val state: StateFlow<LibraryState> = mutableState.asStateFlow()
    // Immutable cached policy is safe to sample before an intent waits for the IO worker.
    val accessSnapshot: GroupAccessSnapshot get() = library.accessSnapshot

    /** Search the warm index even when disk is unavailable, without clearing a rescan failure. */
    suspend fun search(query: String): LibrarySearchSnapshot = withContext(io) {
        mutex.withLock { LibrarySearchSnapshot(mutableState.value, library.index.search(query)) }
    }

    /** Startup/foreground rescan stages a complete index; failure retains the last good snapshot. */
    suspend fun refresh(): LibraryState {
        // Register before dispatch so callers queued on the same IO worker join this scan too.
        val candidate = CompletableDeferred<LibraryState>()
        val flight = synchronized(refreshLock) { refreshFlight ?: candidate.also { refreshFlight = it } }
        if (flight !== candidate) return flight.await()

        try {
            return scan().also { flight.complete(it) }
        } catch (error: Throwable) {
            flight.completeExceptionally(error)
            throw error
        } finally {
            synchronized(refreshLock) { refreshFlight = null }
        }
    }

    /** A commit must not join a scan that captured the library before that commit. */
    suspend fun refreshAfterCommit(): LibraryState = scan()

    private suspend fun scan(): LibraryState = withContext(io) {
        mutex.withLock {
            mutableState.value = mutableState.value.copy(refreshing = true, error = null)
            try {
                prepareRoot()
                val snapshot = library.index.rebuild()
                indexLoaded = true
                LibraryState(snapshot, access = library.accessSnapshot).also { mutableState.value = it }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value.copy(refreshing = false, error = sanitized(error), access = library.accessSnapshot)
                    .also { mutableState.value = it }
            } finally {
                mutableState.value = mutableState.value.copy(refreshing = false)
            }
        }
    }

    /**
     * Runs synchronous Core reads/commands and publishes committed mutation/usage changes on IO.
     * K13-K16 can batch related work here without leaking a synchronous service into a UI callback.
     */
    suspend fun <T> withLibrary(work: (LibraryService, EditingService) -> T): T = withContext(io) {
        mutex.withLock {
            try {
                prepareRoot()
                if (!indexLoaded) {
                    library.index.rebuild()
                    indexLoaded = true
                }
                val result = work(library, editing)
                mutableState.value = LibraryState(library.index.snapshot(), access = library.accessSnapshot)
                result
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                val failure = sanitized(error)
                mutableState.value = LibraryState(library.index.snapshot(), error = failure, access = library.accessSnapshot)
                throw failure
            }
        }
    }

    /** Access-only publications use the committed index and never become a source-save event. */
    suspend fun publishProjection() = withContext(io) {
        mutex.withLock { mutableState.value = mutableState.value.copy(snapshot = library.index.snapshot(), access = library.accessSnapshot) }
    }

    private suspend fun prepareRoot() {
        beforeRead()
        if (!rootPrepared) {
            prompts.prepareRoot()
            rootPrepared = true
        }
        // A vanished root must not erase the warm index or be silently recreated on foreground.
        prompts.requireRoot()
    }

    private fun sanitized(error: Exception): Exception = when (error) {
        is StoreError, is LibraryError -> error
        else -> LibraryError.OperationFailed
    }
}
