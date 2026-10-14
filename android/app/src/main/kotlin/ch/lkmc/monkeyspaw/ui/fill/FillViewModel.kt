package ch.lkmc.monkeyspaw.ui.fill

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.format.PromptBuiltinValues
import ch.lkmc.monkeyspaw.core.domain.format.PromptRenderError
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.core.services.LibraryEntry
import ch.lkmc.monkeyspaw.data.LibraryRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/** Intents and clipboard operations run on Main; preparation and learning use the shared worker. */
@HiltViewModel
internal class FillViewModel @Inject constructor(
    private val repository: LibraryRepository,
    private val fill: FillService,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FillUiState())
    val state = mutableState.asStateFlow()
    private var generation = 0L
    private var requestedPath: String? = null
    private var entry: LibraryEntry? = null
    private var builtins = PromptBuiltinValues()
    private var snapshotStarted = false
    private var loadJob: Job? = null

    fun setForeground(foreground: Boolean) {
        if (state.value.phase == FillPhase.CLOSED) return
        mutableState.value = state.value.copy(foreground = foreground)
        if (foreground) startSnapshot()
    }

    fun open(path: String) {
        if (state.value.phase != FillPhase.PICKING) return
        requestedPath = path
        load(path)
    }

    fun retry() {
        if (state.value.phase != FillPhase.FAILED) return
        requestedPath?.let(::load)
    }

    private fun load(path: String) {
        val epoch = ++generation
        mutableState.value = FillUiState(phase = FillPhase.LOADING, foreground = state.value.foreground)
        loadJob = viewModelScope.launch {
            try {
                val (loaded, form) = repository.withLibrary { library, _ ->
                    val current = library.load(path)
                    current to fill.form(current)
                }
                if (epoch != generation || state.value.phase != FillPhase.LOADING) return@launch
                entry = loaded
                builtins = PromptBuiltinValues()
                snapshotStarted = false
                mutableState.value = state.value.copy(
                    phase = FillPhase.EDITING, title = loaded.document.frontMatter.title,
                    description = loaded.document.frontMatter.description,
                    fields = form.fields.map { FillFieldState(it.field, it.prefill) }, issues = form.issues,
                    canRender = form.canRender, isReadOnly = form.isReadOnly,
                    warnings = if (form.warning == null) emptyList() else listOf(FillWarning.REMEMBERED_VALUES_UNAVAILABLE),
                )
                updatePreview()
                startSnapshot()
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (epoch == generation && state.value.phase == FillPhase.LOADING) {
                    mutableState.value = state.value.copy(phase = FillPhase.FAILED, failure = FillFailure.LOAD)
                }
            }
        }
    }

    private fun startSnapshot() {
        val current = entry ?: return
        if (!state.value.foreground || state.value.phase != FillPhase.EDITING || snapshotStarted) return
        snapshotStarted = true
        val epoch = generation
        try {
            fill.builtinSnapshot(current.document) { snapshot ->
                viewModelScope.launch {
                    if (epoch != generation || state.value.phase != FillPhase.EDITING) return@launch
                    builtins = snapshot
                    mutableState.value = state.value.copy(builtinsResolved = true)
                    updatePreview()
                }
            }
        } catch (_: Exception) {
            if (epoch == generation && state.value.phase == FillPhase.EDITING) {
                mutableState.value = state.value.copy(failure = FillFailure.SNAPSHOT)
            }
        }
    }

    fun setValue(name: String, value: String) {
        if (state.value.phase != FillPhase.EDITING || state.value.fields.none { it.field.name == name }) return
        mutableState.value = state.value.copy(fields = state.value.fields.map {
            if (it.field.name == name) it.copy(value = value) else it
        }, failure = state.value.failure.takeIf { it == FillFailure.SNAPSHOT })
        updatePreview()
    }

    fun copy() {
        if (!state.value.copyEnabled) return
        val current = entry ?: return
        val delivered = state.value.values
        val epoch = generation
        mutableState.value = state.value.copy(phase = FillPhase.COPYING, failure = null)
        try { fill.copy(current.document, delivered, builtins) }
        catch (error: Exception) {
            if (epoch == generation && state.value.phase == FillPhase.COPYING) {
                mutableState.value = state.value.copy(phase = FillPhase.EDITING,
                    failure = if (error is PromptRenderError) null else FillFailure.CLIPBOARD)
                updatePreview()
            }
            return
        }

        // Clipboard publication cannot be undone by Activity destruction. Start learning now,
        // let it finish once, and separately reject any reply to a retired form.
        viewModelScope.launch(start = CoroutineStart.UNDISPATCHED) {
            val warnings = withContext(NonCancellable) {
                val failed = mutableListOf<FillWarning>()
                try {
                    repository.withLibrary { library, _ ->
                        try { fill.rememberedOnDelivery(current.identity, current.document.effectiveFields, delivered) }
                        catch (_: Exception) { failed.add(FillWarning.REMEMBERED_VALUES_NOT_SAVED) }
                        try { library.index.recordUse(current.identity) }
                        catch (_: Exception) { failed.add(FillWarning.USAGE_NOT_SAVED) }
                    }
                } catch (_: Exception) {
                    failed.add(FillWarning.REMEMBERED_VALUES_NOT_SAVED)
                    failed.add(FillWarning.USAGE_NOT_SAVED)
                }
                failed.distinct()
            }
            if (epoch != generation || state.value.phase != FillPhase.COPYING) return@launch
            mutableState.value = state.value.copy(phase = FillPhase.COPIED, warnings = state.value.warnings + warnings)
        }
    }

    fun cancel() {
        if (!state.value.cancelEnabled) return
        retire()
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
        mutableState.value = FillUiState(phase = FillPhase.CLOSED)
    }

    override fun onCleared() { retire() }
}
