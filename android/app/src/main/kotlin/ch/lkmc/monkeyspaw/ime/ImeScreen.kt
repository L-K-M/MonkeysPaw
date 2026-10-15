package ch.lkmc.monkeyspaw.ime

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.fill.FillPhase
import ch.lkmc.monkeyspaw.ui.fill.FillScreen
import ch.lkmc.monkeyspaw.ui.fill.FillUiState
import ch.lkmc.monkeyspaw.ui.library.*

/** Reuses picker/Fill rendering. The service supplies guarded intents, never target text. */
@Composable
@Suppress("ConfigurationScreenWidthHeight")
internal fun ImeScreen(
    state: ImeUiState,
    library: LibraryUiState?,
    fill: FillUiState?,
    onSwitch: () -> Unit,
    onOpen: (LibrarySelection) -> Unit,
    onQuery: (String) -> Unit,
    onFilter: (LibraryFilter) -> Unit,
    onSelect: (LibrarySelection?) -> Unit,
    onClearFilters: () -> Unit,
    onRefresh: () -> Unit,
    onValue: (String, String) -> Unit,
    onCopy: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
) {
    Surface {
        // The IME window wraps this view. Size from display configuration, not its measured window.
        val displayHeight = LocalConfiguration.current.screenHeightDp.dp
        Column(Modifier.fillMaxWidth().height(displayHeight / 2)) {
            TextButton(onClick = onSwitch) { Text(stringResource(R.string.ime_switch_keyboard)) }
            if (state.switchUnavailable) Text(stringResource(R.string.ime_switch_unavailable), Modifier.padding(horizontal = 16.dp))
            if (state.password) {
                Text(stringResource(R.string.ime_password), Modifier.padding(16.dp))
            } else if (fill != null && fill.phase != FillPhase.PICKING) {
                FillScreen(fill, onValue, onCopy, onCancel, onRetry, Modifier.weight(1f))
            } else if (library != null) {
                LibraryScreen(library, onQuery, onFilter, onSelect, {}, onClearFilters, onRefresh,
                    Modifier.weight(1f), onOpen = onOpen, mode = LibraryMode.IME_PICKER)
            }
        }
    }
}
