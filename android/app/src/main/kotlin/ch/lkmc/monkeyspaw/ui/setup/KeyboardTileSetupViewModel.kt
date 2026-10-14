package ch.lkmc.monkeyspaw.ui.setup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.data.AndroidSettingsStore
import ch.lkmc.monkeyspaw.data.KeyboardSetupStatus
import ch.lkmc.monkeyspaw.data.KeyboardTileSetup
import ch.lkmc.monkeyspaw.data.KeyboardTileSetupProgress
import ch.lkmc.monkeyspaw.data.SetupDecision
import ch.lkmc.monkeyspaw.data.TileAddResult
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
internal class KeyboardTileSetupViewModel @Inject constructor(private val settings: AndroidSettingsStore) : ViewModel() {
    private val mutableState = MutableStateFlow(KeyboardTileSetupUiState())
    val state = mutableState.asStateFlow()
    private var host: KeyboardTileSetup? = null
    private var progress: KeyboardTileSetupProgress? = null
    private var pending: KeyboardTileSetupProgress? = null
    private var work: Job? = null
    private var revisiting = false
    private var supportsTileRequest = false
    private var requestSerial = 0L
    private var tileRequest: Long? = null

    fun resumed(host: KeyboardTileSetup) {
        this.host = host
        supportsTileRequest = host.supportsTileRequest
        checkStatus()
        if (progress != null || work?.isActive == true) return
        mutableState.value = state.value.copy(loading = true, error = null)
        work = viewModelScope.launch {
            try {
                progress = settings.read().keyboardTileSetup
                val next = firstPending()
                mutableState.value = state.value.copy(loading = false, visible = next != null, error = null)
                next?.let(::showStep)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value = state.value.copy(loading = false, error = KeyboardTileSetupError.LOAD)
            }
        }
    }

    fun paused() { host = null }

    fun checkStatus() {
        val host = host ?: return
        val status = try { host.keyboardStatus() } catch (_: Exception) { KeyboardSetupStatus() }
        mutableState.value = state.value.copy(enabled = status.enabled, selected = status.selected,
            externalActionPending = false,
            tile = if (state.value.step == KeyboardTileSetupStep.ADD_TILE && !supportsTileRequest)
                TileSetupState.MANUAL else state.value.tile)
    }

    fun openSettings() { mutableState.value = state.value.copy(settingsOpen = true) }
    fun closeSettings() { mutableState.value = state.value.copy(settingsOpen = false) }

    fun reopen() {
        if (progress == null || state.value.saving || state.value.pendingSave) return
        tileRequest = null
        revisiting = true
        mutableState.value = state.value.copy(visible = true, error = null)
        checkStatus()
        showStep(KeyboardTileSetupStep.ENABLE_KEYBOARD)
    }

    fun enableKeyboard() = launchExternal(KeyboardTileSetupStep.ENABLE_KEYBOARD,
        KeyboardTileSetupError.SETTINGS) { it.openKeyboardSettings() }

    fun selectKeyboard() = launchExternal(KeyboardTileSetupStep.SELECT_KEYBOARD,
        KeyboardTileSetupError.PICKER) { it.showKeyboardPicker() }

    private fun launchExternal(step: KeyboardTileSetupStep, error: KeyboardTileSetupError,
        launch: (KeyboardTileSetup) -> Boolean) {
        val host = host ?: return
        if (!state.value.canDecide || state.value.step != step || state.value.externalActionPending) return
        mutableState.value = state.value.copy(externalActionPending = true, error = null)
        val launched = try { launch(host) } catch (_: Exception) { false }
        if (!launched) mutableState.value = state.value.copy(externalActionPending = false, error = error)
    }

    fun addTile() {
        val host = host ?: return
        if (!state.value.canDecide || state.value.step != KeyboardTileSetupStep.ADD_TILE ||
            !host.supportsTileRequest || tileRequest != null) return
        val request = ++requestSerial
        tileRequest = request
        mutableState.value = state.value.copy(tile = TileSetupState.REQUESTING, error = null)
        val reply: (TileAddResult) -> Unit = { result ->
            if (tileRequest == request && state.value.canDecide && state.value.step == KeyboardTileSetupStep.ADD_TILE) {
                tileRequest = null
                mutableState.value = state.value.copy(tile = when (result) {
                    TileAddResult.ADDED -> TileSetupState.ADDED
                    TileAddResult.ALREADY_ADDED -> TileSetupState.ALREADY_ADDED
                    TileAddResult.DENIED -> TileSetupState.DENIED
                    TileAddResult.ERROR -> TileSetupState.ERROR
                })
            }
        }
        try { host.requestTile(reply) } catch (_: Exception) { reply(TileAddResult.ERROR) }
    }

    fun continueStep() {
        if (host == null) return
        checkStatus()
        if (state.value.canContinue) decide(SetupDecision.COMPLETE)
    }

    fun skip() {
        if (state.value.canDecide) decide(SetupDecision.SKIPPED)
    }

    fun retry() {
        if (state.value.saving || work?.isActive == true) return
        if (pending != null) savePending() else host?.let(::resumed)
    }

    private fun decide(decision: SetupDecision) {
        val progress = progress ?: return
        pending = when (state.value.step) {
            KeyboardTileSetupStep.ENABLE_KEYBOARD -> progress.copy(enableKeyboard = decision)
            KeyboardTileSetupStep.SELECT_KEYBOARD -> progress.copy(selectKeyboard = decision)
            KeyboardTileSetupStep.ADD_TILE -> progress.copy(addTile = decision)
        }
        tileRequest = null
        savePending()
    }

    private fun savePending() {
        val pending = pending ?: return
        mutableState.value = state.value.copy(saving = true, pendingSave = true, error = null)
        work = viewModelScope.launch {
            try {
                progress = settings.setKeyboardTileSetup(pending).keyboardTileSetup
                this@KeyboardTileSetupViewModel.pending = null
                val next = if (revisiting) KeyboardTileSetupStep.entries.getOrNull(state.value.step.ordinal + 1) else firstPending()
                mutableState.value = state.value.copy(saving = false, pendingSave = false, visible = next != null)
                next?.let(::showStep)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value = state.value.copy(saving = false, error = KeyboardTileSetupError.SAVE)
            }
        }
    }

    private fun firstPending(): KeyboardTileSetupStep? = progress?.let {
        when {
            it.enableKeyboard == SetupDecision.PENDING -> KeyboardTileSetupStep.ENABLE_KEYBOARD
            it.selectKeyboard == SetupDecision.PENDING -> KeyboardTileSetupStep.SELECT_KEYBOARD
            it.addTile == SetupDecision.PENDING -> KeyboardTileSetupStep.ADD_TILE
            else -> null
        }
    }

    private fun showStep(step: KeyboardTileSetupStep) {
        mutableState.value = state.value.copy(step = step, externalActionPending = false,
            tile = if (step == KeyboardTileSetupStep.ADD_TILE && !supportsTileRequest)
                TileSetupState.MANUAL else TileSetupState.IDLE)
    }

    override fun onCleared() {
        host = null
        tileRequest = null
    }
}
