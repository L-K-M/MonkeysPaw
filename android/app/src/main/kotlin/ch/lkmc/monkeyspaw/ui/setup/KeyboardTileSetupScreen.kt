package ch.lkmc.monkeyspaw.ui.setup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardAlt
import androidx.compose.material.icons.rounded.Widgets
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

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
    BackHandler(enabled = state.handlesBack) { if (state.canDecide) onSkip() }
    if (state.loading) {
        PawLoading(stringResource(R.string.design_setup_loading), modifier)
        return
    }
    PawScreen(stringResource(R.string.design_setup_title), modifier, bottomBar = {
        if (state.visible) PawActionDock {
                TextButton(onClick = onSkip, enabled = state.canDecide) { Text(stringResource(R.string.setup_skip)) }
                Button(onClick = onContinue, enabled = state.canContinue) {
                    Text(stringResource(when {
                        state.step != KeyboardTileSetupStep.ADD_TILE -> R.string.design_setup_continue
                        state.tile == TileSetupState.MANUAL -> R.string.setup_tile_confirm
                        else -> R.string.continue_to_library
                    }))
                }
        }
    }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(PawSpacing.section),
            verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
            state.error?.let {
                PawMessage(stringResource(when (it) {
                    KeyboardTileSetupError.LOAD -> R.string.setup_load_failed
                    KeyboardTileSetupError.SAVE -> R.string.setup_save_failed
                    KeyboardTileSetupError.SETTINGS -> R.string.setup_settings_failed
                    KeyboardTileSetupError.PICKER -> R.string.setup_picker_failed
                }), tone = PawMessageTone.ERROR,
                    actionLabel = if (it == KeyboardTileSetupError.LOAD || it == KeyboardTileSetupError.SAVE) stringResource(R.string.retry) else null,
                    onAction = onRetry.takeUnless { state.saving })
            }
            if (!state.visible) return@Column
            Text(stringResource(R.string.setup_step, state.step.ordinal + 1, KeyboardTileSetupStep.entries.size),
                style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            LinearProgressIndicator(progress = { (state.step.ordinal + 1f) / KeyboardTileSetupStep.entries.size }, modifier = Modifier.fillMaxWidth())
            val icon = when (state.step) {
                KeyboardTileSetupStep.ENABLE_KEYBOARD -> Icons.Rounded.Keyboard
                KeyboardTileSetupStep.SELECT_KEYBOARD -> Icons.Rounded.KeyboardAlt
                KeyboardTileSetupStep.ADD_TILE -> Icons.Rounded.Widgets
            }
            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.primaryContainer) {
                Icon(icon, null, Modifier.padding(PawSpacing.large).size(36.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
            }
            val actionEnabled = state.canDecide && !state.externalActionPending
            when (state.step) {
                KeyboardTileSetupStep.ENABLE_KEYBOARD -> {
                    Text(stringResource(R.string.setup_enable_title), style = MaterialTheme.typography.headlineMedium)
                    Text(stringResource(R.string.setup_privacy), style = MaterialTheme.typography.bodyLarge)
                    PawMessage(stringResource(when (state.enabled) {
                        true -> R.string.setup_enabled
                        false -> R.string.setup_disabled
                        null -> R.string.setup_enabled_unknown
                    }), tone = if (state.enabled == true) PawMessageTone.SUCCESS else PawMessageTone.INFO)
                    FilledTonalButton(onClick = onEnable, enabled = actionEnabled, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.setup_enable_action))
                    }
                    TextButton(onClick = onCheckStatus, enabled = state.canDecide) { Text(stringResource(R.string.setup_check_status)) }
                }
                KeyboardTileSetupStep.SELECT_KEYBOARD -> {
                    Text(stringResource(R.string.setup_select_title), style = MaterialTheme.typography.headlineMedium)
                    Text(stringResource(R.string.setup_select_help), style = MaterialTheme.typography.bodyLarge)
                    PawMessage(stringResource(when (state.selected) {
                        true -> R.string.setup_selected
                        false -> R.string.setup_not_selected
                        null -> R.string.setup_selected_unknown
                    }), tone = if (state.selected == true) PawMessageTone.SUCCESS else PawMessageTone.INFO)
                    FilledTonalButton(onClick = onSelect, enabled = actionEnabled, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.setup_select_action))
                    }
                    TextButton(onClick = onCheckStatus, enabled = state.canDecide) { Text(stringResource(R.string.setup_check_status)) }
                }
                KeyboardTileSetupStep.ADD_TILE -> {
                    Text(stringResource(R.string.setup_tile_title), style = MaterialTheme.typography.headlineMedium)
                    Text(stringResource(R.string.setup_tile_help), style = MaterialTheme.typography.bodyLarge)
                    PawMessage(stringResource(when (state.tile) {
                        TileSetupState.IDLE -> R.string.setup_tile_offer
                        TileSetupState.MANUAL -> R.string.setup_tile_manual
                        TileSetupState.REQUESTING -> R.string.setup_tile_pending
                        TileSetupState.ADDED -> R.string.setup_tile_added
                        TileSetupState.ALREADY_ADDED -> R.string.setup_tile_already_added
                        TileSetupState.DENIED -> R.string.setup_tile_denied
                        TileSetupState.ERROR -> R.string.setup_tile_error
                    }), tone = when (state.tile) {
                        TileSetupState.ADDED, TileSetupState.ALREADY_ADDED -> PawMessageTone.SUCCESS
                        TileSetupState.ERROR, TileSetupState.DENIED -> PawMessageTone.WARNING
                        else -> PawMessageTone.INFO
                    })
                    if (state.tile != TileSetupState.MANUAL) FilledTonalButton(onClick = onAddTile,
                        enabled = state.canDecide && state.tile != TileSetupState.REQUESTING, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.setup_tile_action))
                    }
                }
            }
            if (state.saving) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}
