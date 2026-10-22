package ch.lkmc.monkeyspaw.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

@Composable
internal fun SyncFooter(state: SyncStatusUiState, onDetails: () -> Unit, modifier: Modifier = Modifier) {
    Surface(onClick = onDetails, modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Row(Modifier.fillMaxWidth().padding(horizontal = PawSpacing.large, vertical = PawSpacing.medium),
            horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Sync, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f)) {
                Text(stringResource(state.title), style = MaterialTheme.typography.labelLarge)
                state.counts?.let {
                    Text(stringResource(R.string.sync_footer_counts, it.fileErrors, it.conflicts, it.held, it.pending),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                state.lastSuccess?.let {
                    Text(stringResource(R.string.sync_last_success, it), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun SyncStatusScreen(state: AccountUiState, onSyncNow: () -> Unit, onAccount: () -> Unit,
    onBack: () -> Unit, onRecover: () -> Unit, modifier: Modifier = Modifier) {
    PawScreen(stringResource(R.string.sync_details), modifier, onBack = onBack) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(PawSpacing.large),
            verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
            item {
                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow,
                    modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(PawSpacing.large), verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium),
                            verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Sync, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                            Text(stringResource(state.sync.title), style = MaterialTheme.typography.titleMedium)
                        }
                        Text(state.sync.lastSuccess?.let { stringResource(R.string.sync_last_success, it) }
                            ?: stringResource(R.string.sync_never_succeeded), style = MaterialTheme.typography.bodyMedium)
                        state.sync.counts?.let {
                            Text(stringResource(R.string.sync_pass_counts, it.pulled, it.pushed),
                                style = MaterialTheme.typography.bodyMedium)
                            Text(stringResource(R.string.sync_footer_counts, it.fileErrors, it.conflicts, it.held, it.pending),
                                style = MaterialTheme.typography.bodyMedium)
                        }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                            Button(onClick = onSyncNow, enabled = state.canSync) {
                                Text(stringResource(R.string.sync_now))
                            }
                            if (state.condition == AccountCondition.RECOVERY) {
                                TextButton(onClick = onRecover, enabled = state.busy == null) {
                                    Text(stringResource(R.string.sync_retry_recovery))
                                }
                            }
                        }
                    }
                }
            }
            state.sync.blockingText?.let { item { PawMessage(stringResource(it), tone = PawMessageTone.ERROR) } }
            state.failure?.let { item { PawMessage(stringResource(it), tone = PawMessageTone.ERROR) } }
            if (state.sync.details.isNotEmpty()) {
                item { PawSectionHeading(stringResource(R.string.sync_errors)) }
                items(state.sync.details) { detail ->
                    ListItem(headlineContent = { Text(stringResource(R.string.sync_file_error, detail.path, detail.code)) },
                        leadingContent = { Icon(Icons.Rounded.ErrorOutline, null, tint = MaterialTheme.colorScheme.error) },
                        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow))
                }
            }
            item {
                Surface(shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth()) {
                    PawSettingRow(stringResource(R.string.account_title), stringResource(R.string.design_account_subtitle),
                        Icons.Rounded.AccountCircle, onAccount)
                }
            }
        }
    }
}
