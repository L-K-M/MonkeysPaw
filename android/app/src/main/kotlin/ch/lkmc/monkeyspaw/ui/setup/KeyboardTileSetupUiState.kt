package ch.lkmc.monkeyspaw.ui.setup

internal enum class KeyboardTileSetupStep { ENABLE_KEYBOARD, SELECT_KEYBOARD, ADD_TILE }
internal enum class TileSetupState { IDLE, MANUAL, REQUESTING, ADDED, ALREADY_ADDED, DENIED, ERROR }
internal enum class KeyboardTileSetupError { LOAD, SAVE, SETTINGS, PICKER }

internal data class KeyboardTileSetupUiState(
    val loading: Boolean = true,
    val visible: Boolean = false,
    val settingsOpen: Boolean = false,
    val step: KeyboardTileSetupStep = KeyboardTileSetupStep.ENABLE_KEYBOARD,
    val enabled: Boolean? = null,
    val selected: Boolean? = null,
    val tile: TileSetupState = TileSetupState.IDLE,
    val saving: Boolean = false,
    val pendingSave: Boolean = false,
    val externalActionPending: Boolean = false,
    val error: KeyboardTileSetupError? = null,
) {
    val canDecide: Boolean get() = visible && !loading && !saving && !pendingSave
    val canContinue: Boolean get() = canDecide && when (step) {
        KeyboardTileSetupStep.ENABLE_KEYBOARD -> enabled == true
        KeyboardTileSetupStep.SELECT_KEYBOARD -> selected == true
        KeyboardTileSetupStep.ADD_TILE -> tile in setOf(TileSetupState.MANUAL, TileSetupState.ADDED, TileSetupState.ALREADY_ADDED)
    }
}
