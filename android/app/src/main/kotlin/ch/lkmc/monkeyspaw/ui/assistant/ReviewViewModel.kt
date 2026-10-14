package ch.lkmc.monkeyspaw.ui.assistant

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.di.IoDispatcher
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import dagger.Lazy
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import javax.inject.Inject

/** One retained session; opening, rotation and showing a quote never send requests. */
@HiltViewModel
internal class ReviewViewModel @Inject constructor(
    private val graph: Lazy<AssistantGraph>,
    @IoDispatcher private val worker: CoroutineDispatcher,
    private val providers: AssistantProviderChanges,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ReviewUiState())
    val state = mutableState.asStateFlow()
    private var editor: EditorViewModel? = null
    private var resolvedGraph: AssistantGraph? = null
    private var binding: AssistantSessionBinding? = null
    private var improving: ImproveViewModel? = null
    private var reviewed: AssistantEditorSnapshot? = null
    private var editorSession: Long? = null
    private var loading: Job? = null
    private var observing: Job? = null
    private var navigation = 0L
    private var alive = true

    fun bind(editor: EditorViewModel) {
        if (this.editor === editor) return
        close()
        this.editor = editor
    }

    fun open() {
        if (!alive) return
        if (state.value.isOpen) {
            if (improving != null) return
            mutableState.value = state.value.copy(destination = ReviewDestination.FINDINGS)
            publish()
            return
        }
        editorSession = editor?.assistantSnapshot?.session
        mutableState.value = ReviewUiState(isOpen = true)
        load()
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
            val connected = AssistantSessionBinding(loaded, editor, providers, viewModelScope, ::publish)
            binding = connected
            mutableState.value = state.value.copy(loading = false)
            publish()
            observing = viewModelScope.launch {
                // Validation changes presentation without changing the raw editor snapshot.
                combine(connected.session.state, editor.state) { _, _ -> Unit }.collect {
                    if (binding === connected) publish()
                }
            }
        }
    }

    fun setEffort(effort: AssistantEffort?) {
        if (state.value.isOpen && !state.value.isWorking) mutableState.value = state.value.copy(effort = effort)
    }

    fun editFeedback(feedback: String) {
        if (state.value.isOpen && !state.value.isWorking) mutableState.value = state.value.copy(feedback = feedback)
    }

    fun review() {
        publish()
        if (!state.value.canReview) return
        val connected = binding ?: return
        connected.editor.clearReviewQuote()
        reviewed = connected.context().editor
        connected.session.review(state.value.effort)
        publish()
    }

    fun retryWithFeedback() {
        publish()
        if (!state.value.canRetry) return
        val connected = binding ?: return
        connected.editor.clearReviewQuote()
        reviewed = connected.context().editor
        connected.session.retryWithFeedback(state.value.feedback)
        publish()
    }

    fun toggleFinding(index: Int) {
        publish()
        if (state.value.canSelectFindings) binding?.session?.toggleFinding(index)
        publish()
    }

    /** Continue this review's session, including its exact-source selection and transcript. */
    fun openImprove(model: ImproveViewModel) {
        publish()
        if (!state.value.isOpen || state.value.unavailable != null || state.value.isWorking) return
        val connected = binding ?: return
        connected.editor.clearReviewQuote()
        improving = model
        mutableState.value = state.value.copy(destination = ReviewDestination.IMPROVE)
        model.openReview(connected, state.value.effort, onClose = ::close,
            onCommitted = { editorSession = connected.editor.assistantSnapshot?.session })
    }

    /** This is a subroute of the same review, so returning keeps its bounded selected findings. */
    fun showQuote(index: Int) {
        publish()
        if (!state.value.canSelectFindings) return
        val connected = binding ?: return
        val finding = connected.session.state.value.review?.findings?.getOrNull(index) ?: return
        val match = connected.session.highlightFinding(index) ?: return
        val snapshot = reviewed ?: return
        if (connected.editor.highlightReviewQuote(snapshot, finding.quote, match)) {
            mutableState.value = state.value.copy(destination = ReviewDestination.EDITOR)
        }
    }

    fun cancel() {
        reviewed = null
        editor?.clearReviewQuote()
        binding?.session?.cancel()
        publish()
    }

    /** Back, navigation departure and teardown retire generations and all review content. */
    fun close() {
        navigation++
        loading?.cancel()
        loading = null
        observing?.cancel()
        observing = null
        val previous = binding
        binding = null
        val improvement = improving
        improving = null
        improvement?.ownerClosed()
        previous?.deactivate()
        reviewed = null
        editorSession = null
        editor?.clearReviewQuote()
        mutableState.value = ReviewUiState()
    }

    private fun publish() {
        if (!state.value.isOpen) return
        val connected = binding ?: return
        val context = connected.context()
        val source = context.editor
        if (source?.session != editorSession) { close(); return }
        val editorState = connected.editor.state.value
        val result = connected.session.state.value
        if (result.phase == AssistantPhase.IDLE) reviewed = null
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
        val working = result.phase == AssistantPhase.WORKING
        val canSelect = unavailable == null && !working && !result.isStale && result.review != null && reviewed == source
        if (!canSelect) connected.editor.clearReviewQuote()
        val issues = if (result.review != null) result.issues else editorState.issues
        mutableState.value = state.value.copy(assistant = result, localIssues = issues,
            unavailable = unavailable, canReview = unavailable == null && !working,
            canRetry = unavailable == null && connected.session.canRetry, canSelectFindings = canSelect,
            canImproveWithThese = canSelect && result.selectedFindings.isNotEmpty())
        improving?.contextChanged()
    }

    override fun onCleared() {
        alive = false
        close()
        editor = null
        resolvedGraph = null
        super.onCleared()
    }

    override fun toString(): String = "<assistant review model redacted>"
}
