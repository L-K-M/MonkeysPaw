package ch.lkmc.monkeyspaw.ui.conflicts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.SyncResolutionService
import ch.lkmc.monkeyspaw.data.AndroidSyncRepository
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import javax.inject.Inject

@HiltViewModel
internal class ResolveViewModel @Inject constructor(private val sync: AndroidSyncRepository) : ViewModel() {
    private val mutableState = MutableStateFlow(ResolveUiState())
    val state = mutableState.asStateFlow()
    private var generation = 0L
    private var active = true
    private var selection: LibrarySelection? = null
    private var session: SyncResolutionSession? = null
    private var service: SyncResolutionService? = null
    private var preview: SyncResolutionPreview? = null
    private var work: Job? = null
    private var pendingClose: (() -> Unit)? = null

    fun open(selection: LibrarySelection) {
        if (!active) return
        retireWork()
        pendingClose = null
        this.selection = selection
        load()
    }

    fun refresh() {
        if (!active || !state.value.canRefresh) return
        retireWork()
        load()
    }

    private fun load() {
        val selected = selection ?: return
        val expected = generation
        val owned = SyncResolutionSession().also { session = it }
        mutableState.value = ResolveUiState(status = ResolveStatus.LOADING, copyPath = selected.relativePath)
        work = viewModelScope.launch {
            try {
                val resolution = SyncResolutionService(sync.graph().engine)
                val loaded = resolution.preview(selected.identity, owned)
                if (generation != expected) return@launch
                service = resolution
                present(loaded)
            } catch (error: Exception) {
                if (generation == expected) fail(error)
                if (error is CancellationException) throw error
            }
        }
    }

    /** A tap belongs to the comparison rendered when the callback was created. */
    fun choose(action: SyncResolutionAction, previewID: UUID) {
        val checked = preview ?: return
        val resolution = service ?: return
        if (!active || !state.value.canChoose || checked.id != previewID) return
        val allowed = when (action) {
            SyncResolutionAction.KEEP_SERVER -> checked.canKeepServer
            SyncResolutionAction.KEEP_MINE -> checked.canKeepMine
            SyncResolutionAction.KEEP_BOTH -> checked.canKeepBoth
        }
        if (!allowed) return
        val expected = generation
        mutableState.value = state.value.copy(status = ResolveStatus.RESOLVING, notice = null, failure = null)
        work = viewModelScope.launch {
            try {
                val result = resolution.resolve(action, checked)
                if (generation != expected) return@launch
                when (result) {
                    is SyncResolutionResult.Refreshed -> present(result.preview, ResolveNotice.REFRESHED)
                    is SyncResolutionResult.Resolved -> {
                        session?.cancel()
                        preview = null
                        service = null
                        mutableState.value = ResolveUiState(status = ResolveStatus.RESOLVED,
                            copyPath = state.value.copyPath, resolvedAction = result.action, closePending = state.value.closePending)
                    }
                }
            } catch (error: Exception) {
                if (generation == expected) fail(error)
                if (error is CancellationException) throw error
            }
        }
    }

    private fun present(loaded: SyncResolutionPreview, notice: ResolveNotice? = null) {
        preview = loaded
        mutableState.value = ResolveUiState(status = ResolveStatus.READY, copyPath = loaded.copyPath,
            previewID = loaded.id, diff = loaded.diff, canKeepServer = loaded.canKeepServer,
            canKeepMine = loaded.canKeepMine, canKeepBoth = loaded.canKeepBoth,
            mineRefusal = loaded.mineRefusal?.let(::resolutionFailure), notice = notice, closePending = state.value.closePending)
    }

    private fun fail(error: Exception) {
        session?.cancel()
        preview = null
        service = null
        mutableState.value = ResolveUiState(status = ResolveStatus.FAILED, copyPath = state.value.copyPath,
            failure = resolutionFailure(SyncResolutionService.failure(error)), closePending = state.value.closePending)
    }

    fun cancel() {
        if (!state.value.busy) return
        retireWork()
        mutableState.value = ResolveUiState(status = ResolveStatus.FAILED, copyPath = state.value.copyPath,
            notice = ResolveNotice.CANCELLED, closePending = state.value.closePending)
    }

    fun requestClose(onClosed: () -> Unit) {
        if (state.value.busy) {
            if (pendingClose == null) pendingClose = onClosed
            mutableState.value = state.value.copy(closePending = true)
            return
        }
        close()
        onClosed()
    }

    fun dismissClose() {
        pendingClose = null
        mutableState.value = state.value.copy(closePending = false)
    }

    fun confirmClose() {
        val next = pendingClose ?: return
        close()
        next()
    }

    fun close() {
        retireWork()
        selection = null
        pendingClose = null
        mutableState.value = ResolveUiState()
    }

    private fun retireWork() {
        generation++
        // Revoke synchronous admission before a noncooperative HTTP reply can arrive.
        session?.cancel()
        work?.cancel()
        session = null
        work = null
        preview = null
        service = null
    }

    override fun onCleared() {
        active = false
        close()
    }
}
