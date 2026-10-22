package ch.lkmc.monkeyspaw.ui.conflicts

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.assistant.ImproveDiffView
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

@Composable
internal fun ResolveScreen(
    state: ResolveUiState,
    onKeepServer: () -> Unit,
    onKeepMine: () -> Unit,
    onKeepBoth: () -> Unit,
    onRefresh: () -> Unit,
    onCancel: () -> Unit,
    onBack: () -> Unit,
    onConfirmClose: () -> Unit,
    onDismissClose: () -> Unit,
    onAccount: () -> Unit,
    onSyncDetails: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    var menuOpen by remember { mutableStateOf(false) }
    PawScreen(stringResource(R.string.resolve_title), modifier, onBack = onBack, actions = {
        IconButton(onClick = onRefresh, enabled = state.canRefresh) {
            Icon(Icons.Rounded.Refresh, stringResource(R.string.resolve_refresh))
        }
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Rounded.MoreVert, stringResource(R.string.design_more_options))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.resolve_sync_details)) },
                    leadingIcon = { Icon(Icons.Rounded.CloudUpload, null) },
                    onClick = { menuOpen = false; onSyncDetails() })
                DropdownMenuItem(text = { Text(stringResource(R.string.account_settings)) },
                    leadingIcon = { Icon(Icons.Rounded.AccountCircle, null) },
                    onClick = { menuOpen = false; onAccount() })
            }
        }
    }, bottomBar = {
        if (state.completionMessage != null) PawActionBar {
            Button(onClick = onBack, modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.resolve_done))
            }
        }
    }) {
        // A refreshed capability starts at its notice, rather than retaining an old comparison's scroll.
        key(state.previewID) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PawLayout.contentPadding,
                verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                        Text(state.copyPath, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(stringResource(R.string.resolve_help), style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                state.notice?.let { item { PawMessage(stringResource(it.message), tone = PawMessageTone.WARNING) } }
                state.completionMessage?.let { item { PawMessage(stringResource(it), tone = PawMessageTone.SUCCESS) } }
                state.failure?.let { item { PawMessage(stringResource(it.message), tone = PawMessageTone.ERROR) } }
                state.mineRefusal?.let { item { PawMessage(stringResource(it.message), tone = PawMessageTone.ERROR) } }
                if (state.busy) item {
                    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                        PawLoading(stringResource(if (state.status == ResolveStatus.LOADING)
                            R.string.resolve_loading else R.string.resolve_working))
                        TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.End)) {
                            Text(stringResource(R.string.resolve_cancel))
                        }
                    }
                }
                state.diff?.let { diff ->
                    item {
                        ImproveDiffView(diff, currentLabel = R.string.resolve_server_version,
                            candidateLabel = R.string.resolve_my_version, title = R.string.resolve_diff_title)
                    }
                }
                if (state.previewID != null) {
                    item { PawSectionHeading(stringResource(R.string.resolve_choices_title)) }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                            OutlinedButton(onClick = onKeepServer, enabled = state.canChoose && state.canKeepServer,
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.outlinedButtonColors(
                                    contentColor = MaterialTheme.colorScheme.error)) {
                                Text(stringResource(R.string.resolve_keep_server))
                            }
                            Text(stringResource(R.string.resolve_server_help),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                            OutlinedButton(onClick = onKeepMine, enabled = state.canChoose && state.canKeepMine,
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.outlinedButtonColors(
                                    contentColor = MaterialTheme.colorScheme.error)) {
                                Text(stringResource(R.string.resolve_keep_mine))
                            }
                            Text(stringResource(R.string.resolve_mine_help),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                            Button(onClick = onKeepBoth, enabled = state.canChoose && state.canKeepBoth,
                                modifier = Modifier.fillMaxWidth()) {
                                Text(stringResource(R.string.resolve_keep_both))
                            }
                            Text(stringResource(R.string.resolve_both_help),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
    if (state.closePending) AlertDialog(onDismissRequest = onDismissClose,
        title = { Text(stringResource(R.string.resolve_leave_title)) },
        text = { Text(stringResource(R.string.resolve_leave_help)) },
        confirmButton = { TextButton(onClick = onConfirmClose) { Text(stringResource(R.string.resolve_leave)) } },
        dismissButton = { TextButton(onClick = onDismissClose) { Text(stringResource(R.string.resolve_stay)) } })
}
