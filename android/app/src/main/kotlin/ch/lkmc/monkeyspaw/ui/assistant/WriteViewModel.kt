package ch.lkmc.monkeyspaw.ui.assistant

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.di.IoDispatcher
import ch.lkmc.monkeyspaw.ui.editor.EditorStatus
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import dagger.Lazy
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject

/** Only explicit intents send or save. Configuration recreation retains this in-memory model. */
@HiltViewModel
internal class WriteViewModel @Inject constructor(
    private val graph: Lazy<AssistantGraph>,
    @IoDispatcher private val worker: CoroutineDispatcher,
    private val providers: AssistantProviderChanges,
) : ViewModel() {
    private val mutableState = MutableStateFlow(WriteUiState())
    val state = mutableState.asStateFlow()
    private var editor: EditorViewModel? = null
    private var resolvedGraph: AssistantGraph? = null
    private var binding: AssistantSessionBinding? = null
    private var loading: Job? = null
    private var observing: Job? = null
    private var navigation = 0L
    private var action = 0L
    private var outcome: AssistantAcceptanceOutcome? = null
    private var alive = true

    /** Activity composition binds once; binding again after rotation does not reset or resend. */
    fun bind(editor: EditorViewModel) {
        if (this.editor === editor) return
        close()
        this.editor = editor
    }

    fun open() {
        if (!alive || state.value.isOpen) return
        mutableState.value = WriteUiState(isOpen = true)
        load()
    }

    fun reload() {
        if (!state.value.isOpen || loading?.isActive == true || binding != null) return
        load()
    }

    private fun load() {
        val editor = editor ?: run {
            mutableState.value = state.value.copy(loadFailed = true, unavailable = AssistantUnavailable.LIBRARY)
            return
        }
        val epoch = navigation
        mutableState.value = state.value.copy(loading = true, loadFailed = false)
        loading = viewModelScope.launch {
            val loaded = try { resolvedGraph ?: withContext(worker) { graph.get() } }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                if (epoch == navigation && state.value.isOpen) {
                    mutableState.value = state.value.copy(loading = false, loadFailed = true,
                        unavailable = AssistantUnavailable.LIBRARY)
                }
                return@launch
            }
            if (epoch != navigation || !state.value.isOpen) return@launch
            resolvedGraph = loaded
            val connected = AssistantSessionBinding(loaded, editor, providers, viewModelScope, ::publish)
            binding = connected
            mutableState.value = state.value.copy(loading = false)
            publish()
            observing = viewModelScope.launch {
                connected.session.state.collect { if (binding === connected) publish() }
            }
        }
    }

    fun editBrief(brief: String) {
        if (state.value.canEdit) { mutableState.value = state.value.copy(brief = brief); publish() }
    }

    fun editFeedback(feedback: String) {
        if (state.value.canEdit) mutableState.value = state.value.copy(feedback = feedback)
    }

    fun setEffort(effort: AssistantEffort?) {
        if (state.value.canEdit) mutableState.value = state.value.copy(effort = effort)
    }

    fun write() {
        publish()
        if (!state.value.canWrite) return
        action++
        outcome = null
        binding?.session?.write(state.value.brief, state.value.effort)
        publish()
    }

    fun retryWithFeedback() {
        publish()
        if (!state.value.canRetry) return
        action++
        outcome = null
        binding?.session?.retryWithFeedback(state.value.feedback)
        publish()
    }

    fun showDiff() {
        publish()
        if (!state.value.canShowDiff) return
        action++
        outcome = null
        binding?.session?.showDiff()
        publish()
    }

    fun accept() {
        publish()
        if (!state.value.canAccept) return
        val connected = binding ?: return
        val epoch = action
        connected.session.accept(connected.editor) { actual ->
            // The editor always retains the actual commit, including after this route retires.
            if (binding === connected && action == epoch) {
                outcome = actual
                publish()
            }
        }
        publish()
    }

    fun cancel() {
        outcome = null
        binding?.session?.cancel()
        publish()
    }

    fun reject() {
        outcome = null
        binding?.session?.reject()
        publish()
    }

    /** Back and navigation departure retire generations, guards, timers and all session content. */
    fun close() {
        navigation++
        loading?.cancel()
        loading = null
        observing?.cancel()
        observing = null
        val previous = binding
        binding = null
        previous?.deactivate()
        outcome = null
        mutableState.value = WriteUiState()
    }

    private fun publish() {
        if (!state.value.isOpen) return
        val connected = binding ?: return
        val session = connected.session
        val context = connected.context()
        val editorState = connected.editor.state.value
        val result = session.state.value
        val unavailable = when {
            context.profile == null -> AssistantUnavailable.PROVIDER
            context.access == AssistantAccessState.UNAVAILABLE -> AssistantUnavailable.ACCESS
            context.editor?.availability == AssistantEditorAvailability.CONFLICTED -> AssistantUnavailable.CONFLICT
            context.editor?.availability == AssistantEditorAvailability.BUSY -> AssistantUnavailable.BUSY
            else -> null
        }
        // A fresh diff replaces an old failed save message once it is ready again.
        val finalOutcome = outcome ?: result.acceptanceOutcome?.takeIf {
            result.phase == AssistantPhase.SAVED || result.phase == AssistantPhase.FAILED || result.isStale
        }
        val committed = finalOutcome?.committed != null
        val accepting = result.isAccepting
        val working = result.phase == AssistantPhase.WORKING
        mutableState.value = state.value.copy(assistant = result, acceptanceOutcome = finalOutcome, unavailable = unavailable,
            canWrite = unavailable == null && !working && !accepting && state.value.brief.isNotBlank(),
            canRetry = unavailable == null && !committed && session.canRetry,
            canShowDiff = unavailable == null && !committed && session.canShowDiff,
            canAccept = !committed && !editorState.writing && editorState.status != EditorStatus.LOADING &&
                editorState.conflict == null && session.canAccept)
    }

    override fun onCleared() {
        alive = false
        close()
        editor = null
        resolvedGraph = null
        super.onCleared()
    }

    override fun toString(): String = "<assistant write model redacted>"
}
