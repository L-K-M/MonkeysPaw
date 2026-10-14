package ch.lkmc.monkeyspaw.ui.fill

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.format.PromptBuiltinValues
import ch.lkmc.monkeyspaw.core.domain.format.PromptRenderError
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.core.services.LibraryEntry
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.entry.FillFormSnapshot
import ch.lkmc.monkeyspaw.entry.FillHandoff
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Intents and delivery run on Main; preparation and learning use the shared worker. */
internal class FillViewModel(
    private val repository: LibraryRepository,
    private val fill: FillService,
    endpoint: TextDelivery,
    session: FillSession = FillSession(),
) : ViewModel() {
    private var endpoint: TextDelivery? = endpoint
    private var session: FillSession? = session
    private val mutableState = MutableStateFlow(FillUiState(deliveryMode = session.mode,
        learningPolicy = session.learning, input = session.input))
    val state = mutableState.asStateFlow()
    private var generation = 0L
    private var requestedPath: String? = null
    private var entry: LibraryEntry? = null
    private var builtins = PromptBuiltinValues()
    private var snapshotStarted = false
    private var loadJob: Job? = null
    var handoffInitialized = false
        private set

    fun setForeground(foreground: Boolean) {
        if (!sessionActive()) return
        mutableState.value = state.value.copy(foreground = foreground)
        if (foreground) startSnapshot()
    }

    fun open(path: String) {
        if (!sessionActive() || state.value.phase != FillPhase.PICKING) return
        requestedPath = path
        load(path)
    }

    fun retry() {
        if (!sessionActive() || state.value.phase != FillPhase.FAILED) return
        requestedPath?.let(::load)
    }

    private fun load(path: String) {
        val epoch = ++generation
        mutableState.value = state.value.copy(phase = FillPhase.LOADING, failure = null)
        loadJob = viewModelScope.launch {
            try {
                val (loaded, form) = repository.withLibrary { library, _ ->
                    val current = library.load(path)
                    current to fill.form(current)
                }
                if (epoch != generation || state.value.phase != FillPhase.LOADING || !sessionActive()) return@launch
                entry = loaded
                builtins = PromptBuiltinValues()
                snapshotStarted = false
                val capture = session?.capture?.let { CapturedTextFieldChoice.start(loaded.document, it,
                    form.fields.associate { field -> field.field.name to field.prefill }) }
                mutableState.value = state.value.copy(
                    phase = FillPhase.EDITING, title = loaded.document.frontMatter.title,
                    description = loaded.document.frontMatter.description,
                    fields = form.fields.map { FillFieldState(it.field, capture?.values?.get(it.field.name) ?: it.prefill) },
                    capturedText = capture, issues = form.issues,
                    canRender = form.canRender, isReadOnly = form.isReadOnly,
                    warnings = if (form.warning == null) emptyList() else listOf(FillWarning.REMEMBERED_VALUES_UNAVAILABLE),
                )
                updatePreview()
                startSnapshot()
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (epoch == generation && state.value.phase == FillPhase.LOADING && sessionActive()) {
                    mutableState.value = state.value.copy(phase = FillPhase.FAILED, failure = FillFailure.LOAD)
                }
            }
        }
    }

    private fun startSnapshot() {
        val current = entry ?: return
        if (!sessionActive() || !state.value.foreground || state.value.phase != FillPhase.EDITING || snapshotStarted) return
        snapshotStarted = true
        val epoch = generation
        try {
            fill.builtinSnapshot(current.document) { snapshot ->
                viewModelScope.launch {
                    if (epoch != generation || state.value.phase != FillPhase.EDITING || !sessionActive()) return@launch
                    builtins = snapshot
                    mutableState.value = state.value.copy(builtinsResolved = true)
                    updatePreview()
                }
            }
        } catch (_: Exception) {
            if (epoch == generation && state.value.phase == FillPhase.EDITING && sessionActive()) {
                mutableState.value = state.value.copy(failure = FillFailure.SNAPSHOT)
            }
        }
    }

    fun setValue(name: String, value: String) {
        if (!sessionActive() || state.value.phase != FillPhase.EDITING || state.value.fields.none { it.field.name == name }) return
        mutableState.value = state.value.copy(fields = state.value.fields.map {
            if (it.field.name == name) it.copy(value = value) else it
        }, capturedText = state.value.capturedText?.edit(name, value),
            failure = state.value.failure.takeIf { it == FillFailure.SNAPSHOT })
        updatePreview()
    }

    fun selectCapturedField(name: String?) {
        if (!sessionActive() || state.value.phase != FillPhase.EDITING) return
        val capture = state.value.capturedText ?: return
        if (name != null && capture.candidates.none { it.name == name }) return
        val selected = capture.select(name)
        mutableState.value = state.value.copy(capturedText = selected,
            fields = state.value.fields.map { it.copy(value = selected.values.getValue(it.field.name)) })
        updatePreview()
    }

    /** A pending builtin read stays in its original session; hand off only a completed snapshot. */
    fun handoff(): FillHandoff? {
        if (!sessionActive()) return null
        val current = session ?: return null
        val form = when (state.value.phase) {
            FillPhase.PICKING -> null
            FillPhase.EDITING -> {
                if (!state.value.builtinsResolved) return null
                FillFormSnapshot(entry ?: return null, state.value.fields.toList(), builtins,
                    state.value.capturedText, state.value.warnings.toList())
            }
            else -> return null
        }
        return FillHandoff(current.learning, current.capture, form)
    }

    /** Copy-only activity adoption. A lost token starts an empty, non-learning picker. */
    fun restoreHandoff(handoff: FillHandoff?, copy: TextDelivery) {
        if (state.value.phase == FillPhase.CLOSED) return
        val foreground = state.value.foreground
        generation++
        loadJob?.cancel()
        requestedPath = null
        entry = handoff?.form?.entry
        builtins = handoff?.form?.builtins ?: PromptBuiltinValues()
        snapshotStarted = handoff?.form != null
        session = FillSession(learning = handoff?.learning ?: LearningPolicy.EPHEMERAL, capture = handoff?.capture)
        endpoint = copy
        handoffInitialized = true
        mutableState.value = FillUiState(foreground = foreground, learningPolicy = session!!.learning)
        handoff?.form?.let { form ->
            val document = form.entry.document
            mutableState.value = state.value.copy(phase = FillPhase.EDITING,
                title = document.frontMatter.title, description = document.frontMatter.description,
                fields = form.fields.toList(), capturedText = form.capturedText,
                issues = document.issues, canRender = document.canRender, isReadOnly = document.isReadOnly,
                builtinsResolved = true, warnings = form.warnings.toList())
            updatePreview()
        }
    }

    fun copy() = deliver(DeliveryMode.COPY)
    fun insert() {
        val mode = session?.mode ?: return
        if (mode != DeliveryMode.COPY) deliver(mode)
    }

    private fun deliver(mode: DeliveryMode) {
        if (!sessionActive() || !state.value.copyEnabled) return
        val current = entry ?: return
        val delivery = endpoint ?: return
        val policy = session?.learning ?: return
        val delivered = state.value.values.toMap()
        val snapshot = builtins
        val epoch = generation
        mutableState.value = state.value.copy(phase = FillPhase.DELIVERING, failure = null)
        val result = try { fill.deliver(current.document, delivered, snapshot, mode, delivery) }
        catch (error: Exception) {
            if (epoch == generation && state.value.phase == FillPhase.DELIVERING && sessionActive()) {
                mutableState.value = state.value.copy(phase = FillPhase.EDITING,
                    failure = if (error is PromptRenderError) null else failureFor(mode))
                updatePreview()
            }
            return
        }
        if (result != TextDeliveryResult.ACCEPTED) {
            if (epoch != generation || !sessionActive()) return
            if (result == TextDeliveryResult.STALE) retire()
            else mutableState.value = state.value.copy(phase = FillPhase.EDITING, failure = failureFor(mode))
            return
        }

        // An accepted effect cannot be undone by its host closing. Capture policy/values before it,
        // finish bookkeeping once, and separately reject any reply to a retired form.
        viewModelScope.launch(start = CoroutineStart.UNDISPATCHED) {
            val warnings = if (policy == LearningPolicy.EPHEMERAL) emptyList() else withContext(NonCancellable) {
                try {
                    repository.withLibrary { _, _ ->
                        fill.recordDelivery(current, delivered, policy).map { FillWarning.valueOf(it.name) }
                    }
                } catch (_: Exception) {
                    listOf(FillWarning.REMEMBERED_VALUES_NOT_SAVED, FillWarning.USAGE_NOT_SAVED)
                }
            }
            if (epoch != generation || state.value.phase != FillPhase.DELIVERING || !sessionActive()) return@launch
            mutableState.value = state.value.copy(phase = FillPhase.DELIVERED, warnings = state.value.warnings + warnings)
        }
    }

    private fun failureFor(mode: DeliveryMode) = if (mode == DeliveryMode.COPY) FillFailure.CLIPBOARD else FillFailure.DELIVERY

    fun cancel() {
        if (!state.value.cancelEnabled) return
        retire()
    }

    /** Session end differs from user Back: it also retires UI during accepted bookkeeping. */
    fun endSession() = retire()

    private fun sessionActive(): Boolean {
        val current = session ?: return false
        if (current.isActive()) return true
        retire()
        return false
    }

    private fun updatePreview() {
        val current = entry ?: return
        mutableState.value = state.value.copy(preview = fill.preview(current.document, state.value.values, builtins))
    }

    private fun retire() {
        generation++
        loadJob?.cancel()
        entry = null
        builtins = PromptBuiltinValues()
        requestedPath = null
        session = null
        endpoint = null
        mutableState.value = FillUiState(phase = FillPhase.CLOSED)
    }

    override fun onCleared() { retire() }
}
