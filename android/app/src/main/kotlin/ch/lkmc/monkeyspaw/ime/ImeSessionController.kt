package ch.lkmc.monkeyspaw.ime

import ch.lkmc.monkeyspaw.core.ports.LearningPolicy
import ch.lkmc.monkeyspaw.ui.fill.FillInput
import ch.lkmc.monkeyspaw.ui.fill.FillSession
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.library.LibraryFilter
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Identity is compared only; no target text or editor/package history is retained. */
internal class ImeEditor(val inputType: Int?, val imeOptions: Int, private val connection: Any?) {
    val connectionReady: Boolean get() = connection != null
    fun matchesConnection(other: Any?): Boolean = connection === other

    fun matches(other: ImeEditor): Boolean = inputType == other.inputType &&
        imeOptions == other.imeOptions && connection === other.connection
}

internal interface ImeSessionRoot {
    fun show()
    fun hide()
    fun clearModels()
    fun destroy()
}

internal class ImeModels(val library: LibraryViewModel, val fill: FillViewModel)

internal data class ImeUiState(
    val generation: Long = 0,
    val password: Boolean = false,
    val models: ImeModels? = null,
    val switchUnavailable: Boolean = false,
)

/** All framework callbacks and intents run on the service's UI thread. N4 adds Insert here. */
internal class ImeSessionController(
    private val createModels: (ImeSessionRoot, FillSession) -> ImeModels,
    private val currentEditor: () -> ImeEditor,
    private val switchKeyboard: () -> Boolean,
) {
    private val mutableState = MutableStateFlow(ImeUiState())
    val state = mutableState.asStateFlow()
    private var root: ImeSessionRoot? = null
    private var editor: ImeEditor? = null
    private var inputStarted = false
    private var shown = false
    private var destroyed = false
    private var generation = 0L

    fun replaceRoot(next: ImeSessionRoot) {
        if (destroyed) { next.destroy(); return }
        retire()
        root?.destroy()
        root = next
        if (shown) next.show()
        activate()
    }

    /** Restart is a new generation even when metadata and the connection are unchanged. */
    fun startInput(next: ImeEditor) {
        if (destroyed) return
        retire()
        editor = next
        inputStarted = true
        activate()
    }

    fun show(next: ImeEditor) {
        if (destroyed || !inputStarted) return
        if (editor?.matches(next) != true) retire()
        editor = next
        shown = true
        root?.show()
        activate()
    }

    fun hide() {
        if (destroyed) return
        shown = false
        retire()
        editor = null
        root?.hide()
    }

    fun finishInput() {
        if (destroyed) return
        inputStarted = false
        hide()
    }

    fun unbind() = finishInput()

    fun destroy() {
        if (destroyed) return
        destroyed = true
        inputStarted = false
        shown = false
        retire()
        editor = null
        root?.destroy()
        root = null
    }

    fun open(epoch: Long, selection: LibrarySelection) = withModels(epoch) { it.fill.open(selection.relativePath) }
    fun query(epoch: Long, query: String) = withModels(epoch) { it.library.setQuery(query) }
    fun filter(epoch: Long, filter: LibraryFilter) = withModels(epoch) { it.library.setFilter(filter) }
    fun select(epoch: Long, selection: LibrarySelection?) = withModels(epoch) { it.library.select(selection) }
    fun clearFilters(epoch: Long) = withModels(epoch) { it.library.clearFilters() }
    fun refresh(epoch: Long) = withModels(epoch) { it.library.refresh() }
    fun value(epoch: Long, name: String, value: String) = withModels(epoch) { it.fill.setValue(name, value) }
    fun retry(epoch: Long) = withModels(epoch) { it.fill.retry() }
    fun copy(epoch: Long) = withModels(epoch) { it.fill.copy() }

    fun backToPicker(epoch: Long) = withModels(epoch) {
        if (!it.fill.state.value.cancelEnabled) return@withModels
        retire()
        activate()
    }

    fun switch(epoch: Long) {
        if (!isCurrent(epoch)) return
        // An explicit switch works in password fields too, without constructing any prompt models.
        val switched = try { switchKeyboard() } catch (_: Exception) { false }
        if (epoch == generation && !destroyed && shown) {
            mutableState.value = state.value.copy(switchUnavailable = !switched)
        }
    }

    private fun withModels(epoch: Long, intent: (ImeModels) -> Unit) {
        if (!isActive(epoch)) return
        state.value.models?.let(intent)
    }

    private fun isActive(epoch: Long): Boolean = isCurrent(epoch) && !state.value.password

    private fun isCurrent(epoch: Long): Boolean {
        if (epoch != generation || destroyed || !inputStarted || !shown || root == null) return false
        val latest = currentEditor()
        if (editor?.matches(latest) == true) return true
        retire()
        editor = latest
        activate()
        return false
    }

    private fun activate() {
        if (destroyed || !inputStarted || !shown || state.value.models != null) return
        val owner = root ?: return
        val metadata = editor ?: return
        val policy = ImeInputPolicy.classify(metadata.inputType, metadata.imeOptions)
        mutableState.value = ImeUiState(generation, password = !policy.promptsAllowed)
        if (!policy.promptsAllowed) return
        val epoch = generation
        val session = FillSession(input = FillInput.INLINE,
            learning = if (policy.learning == ImeInputPolicy.Learning.EPHEMERAL) LearningPolicy.EPHEMERAL else LearningPolicy.NORMAL,
            isActive = { isActive(epoch) })
        val models = createModels(owner, session)
        mutableState.value = state.value.copy(models = models)
        models.fill.setForeground(true)
    }

    private fun retire() {
        generation++
        val models = state.value.models
        mutableState.value = ImeUiState(generation)
        models?.fill?.endSession()
        if (models != null) root?.clearModels()
    }
}
