package ch.lkmc.monkeyspaw.ime

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.fill.FillPhase
import ch.lkmc.monkeyspaw.ui.fill.FillScreen
import ch.lkmc.monkeyspaw.ui.fill.FillUiState
import ch.lkmc.monkeyspaw.ui.library.*
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

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
    onInsert: () -> Unit,
    onHandoff: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
) {
    val configuration = LocalConfiguration.current
    val height = imePickerHeight(configuration.screenWidthDp, configuration.screenHeightDp, LocalDensity.current.fontScale).dp
    val notices = listOfNotNull(
        stringResource(R.string.ime_switch_unavailable).takeIf { state.switchUnavailable },
        stringResource(R.string.ime_handoff_failed).takeIf { state.handoffFailed },
    )
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)) {
        // Use display configuration: measuring the wrapping IME window would feed back into its height.
        Column(Modifier.fillMaxWidth().height(height).navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = PawSpacing.large, vertical = PawSpacing.xs),
                horizontalArrangement = Arrangement.spacedBy(PawSpacing.small), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.ime_picker_title), style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (!state.password && !state.inFillActivity && library != null && (fill == null || fill.phase == FillPhase.PICKING)) {
                    IconButton(onClick = onRefresh, enabled = !library.refreshing) { Icon(Icons.Rounded.Refresh, stringResource(R.string.library_refresh)) }
                    IconButton(onClick = onHandoff) { Icon(Icons.Rounded.Search, stringResource(R.string.ime_search_in_app)) }
                } else if (!state.password && !state.inFillActivity && fill?.phase == FillPhase.EDITING) {
                    IconButton(onClick = onHandoff, enabled = fill.builtinsResolved) {
                        Icon(Icons.AutoMirrored.Rounded.OpenInNew, stringResource(R.string.fill_in_app))
                    }
                }
                FilledTonalIconButton(onClick = onSwitch) { Icon(Icons.Rounded.Language, stringResource(R.string.ime_switch_keyboard)) }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            if (state.password) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(PawSpacing.large),
                    verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                    PawMessage(stringResource(R.string.ime_password))
                    for (notice in notices) PawMessage(notice, tone = PawMessageTone.WARNING)
                }
            } else if (state.inFillActivity) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(PawSpacing.large),
                    verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                    PawMessage(stringResource(R.string.ime_fill_typing))
                    for (notice in notices) PawMessage(notice, tone = PawMessageTone.WARNING)
                }
            } else if (fill != null && fill.phase != FillPhase.PICKING) {
                val fillNotices = notices + listOfNotNull(stringResource(R.string.ime_copy_instead).takeIf { !state.insertEnabled && fill.copyEnabled })
                FillScreen(fill, onValue, onCopy, onCancel, onRetry, Modifier.weight(1f),
                    onInsert = onInsert.takeIf { state.insertEnabled }, onFillInApp = onHandoff,
                    notice = fillNotices.takeIf { it.isNotEmpty() }?.joinToString("\n"))
            } else if (library != null) {
                LibraryScreen(library, onQuery, onFilter, onSelect, {}, onClearFilters, onRefresh,
                    Modifier.weight(1f), onOpen = onOpen, mode = LibraryMode.IME_PICKER,
                    notice = notices.takeIf { it.isNotEmpty() }?.joinToString("\n"))
            } else PawLoading(stringResource(R.string.library_loading), Modifier.weight(1f))
        }
    }
}

/** Reserve target-app space even in short split-screen windows; large type gets some extra room. */
internal fun imePickerHeight(widthDp: Int, heightDp: Int, fontScale: Float): Int {
    val landscape = widthDp > heightDp
    val base = heightDp * if (landscape) 0.62f else 0.42f
    val scaled = (base + (fontScale - 1f).coerceIn(0f, 1f) * 48).toInt()
    val bounded = if (landscape) scaled.coerceIn(180, 260) else scaled.coerceIn(300, 400)
    return bounded.coerceAtMost((heightDp * 0.7f).toInt()).coerceAtLeast(0)
}
