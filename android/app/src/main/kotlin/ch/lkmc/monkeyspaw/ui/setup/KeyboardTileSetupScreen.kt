package ch.lkmc.monkeyspaw.ui.setup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R

@Composable
internal fun KeyboardTileSetupScreen(
    state: KeyboardTileSetupUiState,
    onEnable: () -> Unit,
    onSelect: () -> Unit,
    onAddTile: () -> Unit,
    onCheckStatus: () -> Unit,
    onContinue: () -> Unit,
    onSkip: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(enabled = state.visible) { if (state.canDecide) onSkip() }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.setup_title), style = MaterialTheme.typography.headlineMedium)
        if (state.loading) {
            CircularProgressIndicator()
            return@Column
        }
        state.error?.let {
            Text(stringResource(when (it) {
                KeyboardTileSetupError.LOAD -> R.string.setup_load_failed
                KeyboardTileSetupError.SAVE -> R.string.setup_save_failed
                KeyboardTileSetupError.SETTINGS -> R.string.setup_settings_failed
                KeyboardTileSetupError.PICKER -> R.string.setup_picker_failed
            }), color = MaterialTheme.colorScheme.error)
            if (it == KeyboardTileSetupError.LOAD || it == KeyboardTileSetupError.SAVE) {
                Button(onClick = onRetry, enabled = !state.saving) { Text(stringResource(R.string.retry)) }
            }
        }
        if (!state.visible) return@Column
        Text(stringResource(R.string.setup_step, state.step.ordinal + 1, KeyboardTileSetupStep.entries.size))
        val actionEnabled = state.canDecide && !state.externalActionPending
        when (state.step) {
            KeyboardTileSetupStep.ENABLE_KEYBOARD -> {
                Text(stringResource(R.string.setup_enable_title), style = MaterialTheme.typography.titleLarge)
                Text(stringResource(R.string.setup_privacy))
                Text(stringResource(when (state.enabled) {
                    true -> R.string.setup_enabled
                    false -> R.string.setup_disabled
                    null -> R.string.setup_enabled_unknown
                }))
                Button(onClick = onEnable, enabled = actionEnabled) { Text(stringResource(R.string.setup_enable_action)) }
                TextButton(onClick = onCheckStatus, enabled = state.canDecide) { Text(stringResource(R.string.setup_check_status)) }
            }
            KeyboardTileSetupStep.SELECT_KEYBOARD -> {
                Text(stringResource(R.string.setup_select_title), style = MaterialTheme.typography.titleLarge)
                Text(stringResource(R.string.setup_select_help))
                Text(stringResource(when (state.selected) {
                    true -> R.string.setup_selected
                    false -> R.string.setup_not_selected
                    null -> R.string.setup_selected_unknown
                }))
                Button(onClick = onSelect, enabled = actionEnabled) { Text(stringResource(R.string.setup_select_action)) }
                TextButton(onClick = onCheckStatus, enabled = state.canDecide) { Text(stringResource(R.string.setup_check_status)) }
            }
            KeyboardTileSetupStep.ADD_TILE -> {
                Text(stringResource(R.string.setup_tile_title), style = MaterialTheme.typography.titleLarge)
                Text(stringResource(R.string.setup_tile_help))
                Text(stringResource(when (state.tile) {
                    TileSetupState.IDLE -> R.string.setup_tile_offer
                    TileSetupState.MANUAL -> R.string.setup_tile_manual
                    TileSetupState.REQUESTING -> R.string.setup_tile_pending
                    TileSetupState.ADDED -> R.string.setup_tile_added
                    TileSetupState.ALREADY_ADDED -> R.string.setup_tile_already_added
                    TileSetupState.DENIED -> R.string.setup_tile_denied
                    TileSetupState.ERROR -> R.string.setup_tile_error
                }))
                if (state.tile != TileSetupState.MANUAL) {
                    Button(onClick = onAddTile, enabled = state.canDecide && state.tile != TileSetupState.REQUESTING) {
                        Text(stringResource(R.string.setup_tile_action))
                    }
                }
            }
        }
        if (state.saving) CircularProgressIndicator()
        Button(onClick = onContinue, enabled = state.canContinue) {
            Text(stringResource(if (state.tile == TileSetupState.MANUAL) R.string.setup_tile_confirm else R.string.continue_to_library))
        }
        TextButton(onClick = onSkip, enabled = state.canDecide) { Text(stringResource(R.string.setup_skip)) }
    }
}
