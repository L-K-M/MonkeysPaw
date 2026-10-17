package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.services.LibraryError
import ch.lkmc.monkeyspaw.core.services.LibraryService
import ch.lkmc.monkeyspaw.core.services.SyncLocalGraph
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Application/IME/delivery can recover local files without reaching the authenticated graph. */
internal class AndroidSyncStartup(
    private val library: LibraryService,
    private val prompts: AndroidPromptStore,
    private val files: AndroidStateStore,
    val libraryRoot: String,
    private val io: CoroutineDispatcher,
) {
    private val mutex = Mutex()
    private var local: SyncLocalGraph? = null
    private var recovered = false
    private var rootChecked = false
    private val mutableRootAvailable = MutableStateFlow(true)
    val rootAvailable = mutableRootAvailable.asStateFlow()

    /** Explicit credential cleanup may need metadata even when the library root is unavailable. */
    suspend fun metadata(): SyncLocalGraph = withContext(io) { mutex.withLock { localGraph() } }

    private fun localGraph(): SyncLocalGraph = local ?: SyncLocalGraph(library, prompts.syncOperations, files,
        files.syncOperations, libraryRoot).also { local = it }

    suspend fun ready(): SyncLocalGraph = withContext(io) {
        mutex.withLock {
            try {
                val graph = localGraph()
                if (!recovered) {
                    if (!rootChecked) {
                        if (graph.requiresExistingRoot) checkRoot() else prompts.prepareRoot()
                        rootChecked = true
                    } else checkRoot()
                    graph.recover()
                    recovered = true
                }
                checkRoot()
                graph
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                throw LibraryError.RecoveryRequired
            }
        }
    }

    private fun checkRoot() {
        try { prompts.requireRoot(); mutableRootAvailable.value = true }
        catch (error: Exception) { mutableRootAvailable.value = false; throw error }
    }
}
