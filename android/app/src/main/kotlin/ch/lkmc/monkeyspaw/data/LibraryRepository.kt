package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.*
import kotlinx.coroutines.CancellationException
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
)

/** One process-wide graph. ViewModels use this worker seam; views only consume immutable state. */
internal class LibraryRepository(
    private val library: LibraryService,
    private val editing: EditingService,
    private val prompts: AndroidPromptStore,
    private val io: CoroutineDispatcher,
) {
    private val mutex = Mutex()
    private var rootPrepared = false
    private var indexLoaded = false
    private val mutableState = MutableStateFlow(LibraryState(LibrarySnapshot(0, emptyList())))
    val state: StateFlow<LibraryState> = mutableState.asStateFlow()

    /** Startup/foreground rescan stages a complete index; failure retains the last good snapshot. */
    suspend fun refresh(): LibraryState = withContext(io) {
        mutex.withLock {
            mutableState.value = mutableState.value.copy(refreshing = true, error = null)
            try {
                prepareRoot()
                val snapshot = library.index.rebuild()
                indexLoaded = true
                LibraryState(snapshot).also { mutableState.value = it }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value.copy(refreshing = false, error = sanitized(error))
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
                mutableState.value = LibraryState(library.index.snapshot())
                result
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                val failure = sanitized(error)
                mutableState.value = LibraryState(library.index.snapshot(), error = failure)
                throw failure
            }
        }
    }

    private fun prepareRoot() {
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
