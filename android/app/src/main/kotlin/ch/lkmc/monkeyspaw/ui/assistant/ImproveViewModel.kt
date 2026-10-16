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
import kotlinx.coroutines.flow.combine
import javax.inject.Inject

/** Direct Improve owns a binding; Review lends its existing session and remains its owner. */
@HiltViewModel
internal class ImproveViewModel @Inject constructor(
    private val graph: Lazy<AssistantGraph>,
    @IoDispatcher private val worker: CoroutineDispatcher,
    private val providers: AssistantProviderChanges,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ImproveUiState())
    val state = mutableState.asStateFlow()
    private var editor: EditorViewModel? = null
    private var editorSession: Long? = null
    private var resolvedGraph: AssistantGraph? = null
    private var binding: AssistantSessionBinding? = null
    private var closeOwner: (() -> Unit)? = null
    private var adoptOwnerSession: (() -> Unit)? = null
    private var loading: Job? = null
    private var observing: Job? = null
    private var navigation = 0L
    private var action = 0L
    private var hasImproved = false
    private var outcome: AssistantAcceptanceOutcome? = null
    private var alive = true

    fun bind(editor: EditorViewModel) {
        if (this.editor === editor) return
        close()
        this.editor = editor
    }

    fun open() {
        if (!alive || state.value.isOpen) return
        editorSession = editor?.assistantSnapshot?.session
        mutableState.value = ImproveUiState(isOpen = true)
        load()
    }

    /** No finding payload or second selection store: the reviewed session supplies both. */
    fun openReview(connected: AssistantSessionBinding, effort: AssistantEffort?,
                   onClose: () -> Unit, onCommitted: () -> Unit) {
        if (!alive || (state.value.isOpen && binding === connected)) return
        close()
        editor = connected.editor
        editorSession = editor?.assistantSnapshot?.session
        closeOwner = onClose
        adoptOwnerSession = onCommitted
        mutableState.value = ImproveUiState(isOpen = true, effort = effort)
        connect(connected)
    }

    fun reload() {
        if (!state.value.isOpen || loading?.isActive == true || binding != null) return
        load()
    }

    private fun load() {
        val editor = editor ?: run {
            mutableState.value = state.value.copy(loadFailed = true, unavailable = ReviewUnavailable.LIBRARY)
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
                        unavailable = ReviewUnavailable.LIBRARY)
                }
                return@launch
            }
            if (epoch != navigation || !state.value.isOpen) return@launch
            if (editor.assistantSnapshot?.session != editorSession) { close(); return@launch }
            resolvedGraph = loaded
            connect(AssistantSessionBinding(loaded, editor, providers, viewModelScope, ::contextChanged))
        }
    }

    private fun connect(connected: AssistantSessionBinding) {
        binding = connected
        mutableState.value = state.value.copy(loading = false)
        publish()
        observing = viewModelScope.launch {
            combine(connected.session.state, connected.editor.state) { _, _ -> Unit }.collect {
                if (binding === connected) publish()
            }
        }
    }

    /** Review forwards synchronous context transitions while it owns the lent binding. */
    fun contextChanged() {
        binding?.session?.contextChanged()
        publish()
    }

    fun editInstruction(instruction: String) {
        if (state.value.canEdit) binding?.session?.editInstruction(instruction)
        publish()
    }

    fun editFeedback(feedback: String) {
        if (state.value.canEdit) mutableState.value = state.value.copy(feedback = feedback)
    }

    fun setEffort(effort: AssistantEffort?) {
        if (state.value.canEdit) mutableState.value = state.value.copy(effort = effort)
    }

    fun improve() {
        publish()
        if (!state.value.canImprove) return
        action++
        hasImproved = true
        outcome = null
        editor?.clearReviewQuote()
        binding?.session?.improve(state.value.effort)
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
            if (binding === connected && action == epoch) {
                outcome = actual
                if (actual.committed != null) {
                    // A viewer copy legitimately adopts a new editor session before notifications.
                    editorSession = connected.editor.assistantSnapshot?.session
                    adoptOwnerSession?.invoke()
                }
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

    /** The Review owner already retires the binding; detach without retiring it twice. */
    fun ownerClosed() {
        binding = null
        closeOwner = null
        close()
    }

    fun close() {
        navigation++
        loading?.cancel()
        loading = null
        observing?.cancel()
        observing = null
        val previous = binding
        val owner = closeOwner
        binding = null
        closeOwner = null
        adoptOwnerSession = null
        editorSession = null
        outcome = null
        hasImproved = false
        mutableState.value = ImproveUiState()
        if (owner != null) owner() else previous?.deactivate()
    }

    private fun publish() {
        if (!state.value.isOpen) return
        val connected = binding ?: return
        val context = connected.context()
        val source = context.editor
        if (source?.session != editorSession) { close(); return }
        val editorState = connected.editor.state.value
        val session = connected.session
        val result = session.state.value
        val unavailable = when {
            context.profile == null -> ReviewUnavailable.PROVIDER
            context.access == AssistantAccessState.UNAVAILABLE -> ReviewUnavailable.ACCESS
            source == null -> ReviewUnavailable.SOURCE
            source.availability == AssistantEditorAvailability.CONFLICTED -> ReviewUnavailable.CONFLICT
            source.availability == AssistantEditorAvailability.BUSY -> ReviewUnavailable.BUSY
            source.readOnlyReason != null -> ReviewUnavailable.READ_ONLY
            source.source == null -> ReviewUnavailable.SOURCE
            editorState.validating -> ReviewUnavailable.VALIDATING
            !editorState.previewAvailable -> ReviewUnavailable.INVALID
            editorState.isPrivate -> ReviewUnavailable.PRIVATE
            else -> null
        }
        val finalOutcome = outcome ?: result.acceptanceOutcome?.takeIf {
            result.phase == AssistantPhase.SAVED || result.phase == AssistantPhase.FAILED || result.isStale
        }
        val committed = finalOutcome?.committed != null
        val working = result.phase == AssistantPhase.WORKING
        val hasInput = result.instruction.isNotBlank() || result.selectedFindings.isNotEmpty()
        mutableState.value = state.value.copy(assistant = result, acceptanceOutcome = finalOutcome, unavailable = unavailable,
            canImprove = unavailable == null && !working && !result.isAccepting && hasInput,
            canRetry = unavailable == null && !committed && hasImproved && session.canRetry,
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

    override fun toString(): String = "<assistant improve model redacted>"
}
