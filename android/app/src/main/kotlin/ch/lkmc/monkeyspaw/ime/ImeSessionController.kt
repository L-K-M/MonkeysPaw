package ch.lkmc.monkeyspaw.ime

import ch.lkmc.monkeyspaw.core.ports.DeliveryMode
import ch.lkmc.monkeyspaw.core.ports.LearningPolicy
import ch.lkmc.monkeyspaw.core.services.FillPreview
import ch.lkmc.monkeyspaw.data.ImeSwitchBack
import ch.lkmc.monkeyspaw.entry.FillHandoff
import ch.lkmc.monkeyspaw.ui.fill.FillInput
import ch.lkmc.monkeyspaw.ui.fill.FillFailure
import ch.lkmc.monkeyspaw.ui.fill.FillPhase
import ch.lkmc.monkeyspaw.ui.fill.FillSession
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.library.LibraryFilter
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Identity is compared only; no target text or editor/package history is retained. */
internal class ImeEditor(val inputType: Int?, val imeOptions: Int, private val connection: Any?,
    val inFillActivity: Boolean = false) {
    val connectionReady: Boolean get() = connection != null
    fun matchesConnection(other: Any?): Boolean = connection === other

    fun matches(other: ImeEditor): Boolean = inputType == other.inputType &&
        imeOptions == other.imeOptions && connection === other.connection && inFillActivity == other.inFillActivity

    fun retainOwnConnection(previous: ImeEditor?): ImeEditor {
        // Local focus loss alone cannot release a connection identified as our Fill editor.
        if (inFillActivity || previous?.inFillActivity != true || connection !== previous.connection) return this
        return ImeEditor(inputType, imeOptions, connection, inFillActivity = true)
    }
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
    val inFillActivity: Boolean = false,
    val insertEnabled: Boolean = false,
    val models: ImeModels? = null,
    val switchUnavailable: Boolean = false,
    val handoffFailed: Boolean = false,
)

/** All framework callbacks and intents run on the service's UI thread. */
internal class ImeSessionController(
    private val createModels: (ImeSessionRoot, FillSession) -> ImeModels,
    private val currentEditor: () -> ImeEditor,
    private val switchKeyboard: (() -> Boolean) -> ImeSwitchBack.Result,
    private val launchHandoff: (FillHandoff) -> Boolean,
) {
    private val mutableState = MutableStateFlow(ImeUiState())
    val state = mutableState.asStateFlow()
    private var root: ImeSessionRoot? = null
    private var editor: ImeEditor? = null
    private var inputStarted = false
    private var shown = false
    private var destroyed = false
    private var generation = 0L
    private var targetVersion = 0L
    private var autoInsert = false
    private var deliveryFinished = false
    private var insertRefused = false
    private var handingOff = false

    fun replaceRoot(next: ImeSessionRoot) {
        if (destroyed) { next.destroy(); return }
        targetVersion++
        retire()
        root?.destroy()
        root = next
        if (shown) next.show()
        activate()
    }

    /** Restart is a new generation even when metadata and the connection are unchanged. */
    fun startInput(next: ImeEditor) {
        if (destroyed) return
        targetVersion++
        retire()
        editor = next
        inputStarted = true
        activate()
    }

    fun show(next: ImeEditor) {
        if (destroyed || !inputStarted) return
        if (editor?.matches(next) != true) {
            targetVersion++
            retire()
        }
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
        targetVersion++
        inputStarted = false
        shown = false
        retire()
        editor = null
        root?.destroy()
        root = null
    }

    fun open(epoch: Long, selection: LibrarySelection) = withModels(epoch) {
        if (it.fill.state.value.phase != FillPhase.PICKING) return@withModels
        autoInsert = true
        it.fill.open(selection.relativePath)
    }
    fun query(epoch: Long, query: String) = withModels(epoch) { it.library.setQuery(query) }
    fun filter(epoch: Long, filter: LibraryFilter) = withModels(epoch) { it.library.setFilter(filter) }
    fun select(epoch: Long, selection: LibrarySelection?) = withModels(epoch) { it.library.select(selection) }
    fun clearFilters(epoch: Long) = withModels(epoch) { it.library.clearFilters() }
    fun refresh(epoch: Long) = withModels(epoch) { it.library.refresh() }
    fun value(epoch: Long, name: String, value: String) = withModels(epoch) { it.fill.setValue(name, value) }
    fun retry(epoch: Long) = withModels(epoch) { it.fill.retry() }
    fun copy(epoch: Long) = withModels(epoch) { it.fill.copy() }
    fun insert(epoch: Long) = withModels(epoch) { autoInsert = false; it.fill.insert() }

    /** The input-view lifecycle observes Fill; delayed replies still carry the displayed generation. */
    fun fillChanged(epoch: Long) = withModels(epoch) {
        val form = it.fill.state.value
        if (form.failure == FillFailure.DELIVERY) insertRefused = true
        val metadata = editor ?: return@withModels
        val policy = ImeInputPolicy.classify(metadata.inputType, metadata.imeOptions)
        val decision = policy.decide((form.preview as? FillPreview.Rendered)?.text, metadata.connectionReady)
        mutableState.value = state.value.copy(insertEnabled = form.copyEnabled && !insertRefused &&
            decision == ImeInputPolicy.Decision.INSERT)
        if (autoInsert && form.phase == FillPhase.EDITING && form.builtinsResolved) {
            autoInsert = false
            if (form.fields.isEmpty() && form.copyEnabled) it.fill.insert()
        }
        if (form.phase == FillPhase.DELIVERED && form.warnings.isEmpty() && !deliveryFinished) {
            deliveryFinished = true
            switch(epoch)
        }
    }

    fun handoff(epoch: Long) = withModels(epoch) {
        if (handingOff) return@withModels
        val snapshot = it.fill.handoff() ?: return@withModels
        val target = targetVersion
        handingOff = true
        try {
            val result = switch(epoch)
            if (result != ImeSwitchBack.Result.PREVIOUS && result != ImeSwitchBack.Result.PICKER) return@withModels
            // Successful switching can hide/unbind this view. A new start/target must cancel launch.
            if (destroyed || target != targetVersion) return@withModels
            if (shown && !isCurrent(epoch)) return@withModels
            val launched = try { launchHandoff(snapshot) } catch (_: Exception) { false }
            if (epoch != generation) return@withModels
            if (launched) retire() else mutableState.value = state.value.copy(handoffFailed = true)
        } finally { handingOff = false }
    }

    fun backToPicker(epoch: Long) = withModels(epoch) {
        if (!it.fill.state.value.cancelEnabled) return@withModels
        if (it.fill.state.value.phase == FillPhase.DELIVERED) { switch(epoch); return@withModels }
        retire()
        activate()
    }

    fun switch(epoch: Long): ImeSwitchBack.Result {
        if (!isCurrent(epoch)) return ImeSwitchBack.Result.STALE
        // An explicit switch works in password fields too, without constructing any prompt models.
        val result = try { switchKeyboard { isCurrent(epoch) } } catch (_: Exception) { ImeSwitchBack.Result.UNAVAILABLE }
        if (epoch == generation && !destroyed && shown) {
            mutableState.value = state.value.copy(switchUnavailable = result == ImeSwitchBack.Result.UNAVAILABLE)
        }
        return result
    }

    private fun withModels(epoch: Long, intent: (ImeModels) -> Unit) {
        if (!isActive(epoch)) return
        state.value.models?.let(intent)
    }

    private fun isActive(epoch: Long): Boolean = isCurrent(epoch) && !state.value.password && !state.value.inFillActivity

    private fun isCurrent(epoch: Long): Boolean {
        if (epoch != generation || destroyed || !inputStarted || !shown || root == null) return false
        val latest = currentEditor().retainOwnConnection(editor)
        if (editor?.matches(latest) == true) return true
        targetVersion++
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
        mutableState.value = ImeUiState(generation, password = !policy.promptsAllowed,
            inFillActivity = metadata.inFillActivity)
        if (!policy.promptsAllowed || metadata.inFillActivity) return
        val epoch = generation
        val session = FillSession(mode = DeliveryMode.IME_COMMIT, input = FillInput.INLINE,
            learning = if (policy.learning == ImeInputPolicy.Learning.EPHEMERAL) LearningPolicy.EPHEMERAL else LearningPolicy.NORMAL,
            isActive = { isActive(epoch) })
        val models = createModels(owner, session)
        mutableState.value = state.value.copy(models = models)
        models.fill.setForeground(true)
    }

    private fun retire() {
        generation++
        autoInsert = false
        deliveryFinished = false
        insertRefused = false
        val models = state.value.models
        mutableState.value = ImeUiState(generation)
        models?.fill?.endSession()
        if (models != null) root?.clearModels()
    }
}
