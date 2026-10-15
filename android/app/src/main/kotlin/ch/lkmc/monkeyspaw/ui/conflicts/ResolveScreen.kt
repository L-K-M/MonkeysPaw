package ch.lkmc.monkeyspaw.ui.conflicts

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.assistant.ImproveDiffView

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
    // A refreshed capability starts at its notice, rather than retaining an old comparison's scroll.
    key(state.previewID) {
        LazyColumn(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                TextButton(onClick = onBack) { Text(stringResource(R.string.editor_back)) }
                Text(stringResource(R.string.resolve_title), style = MaterialTheme.typography.headlineSmall)
                Text(state.copyPath, style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.resolve_help))
            }
            item {
                state.notice?.let { Text(stringResource(it.message), color = MaterialTheme.colorScheme.error) }
                state.failure?.let { Text(stringResource(it.message), color = MaterialTheme.colorScheme.error) }
                state.completionMessage?.let { Text(stringResource(it)) }
                if (state.busy) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text(stringResource(if (state.status == ResolveStatus.LOADING) R.string.resolve_loading else R.string.resolve_working))
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.resolve_cancel)) }
                }
                state.mineRefusal?.let { Text(stringResource(it.message), color = MaterialTheme.colorScheme.error) }
                if (state.canRefresh) TextButton(onClick = onRefresh) { Text(stringResource(R.string.resolve_refresh)) }
            }
            state.diff?.let { diff ->
                item {
                    ImproveDiffView(diff, currentLabel = R.string.resolve_server_version,
                        candidateLabel = R.string.resolve_my_version, title = R.string.resolve_diff_title)
                }
            }
            if (state.previewID != null) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onKeepServer, enabled = state.canChoose && state.canKeepServer) {
                        Text(stringResource(R.string.resolve_keep_server))
                    }
                    Text(stringResource(R.string.resolve_server_help), style = MaterialTheme.typography.bodySmall)
                    Button(onClick = onKeepMine, enabled = state.canChoose && state.canKeepMine) {
                        Text(stringResource(R.string.resolve_keep_mine))
                    }
                    Text(stringResource(R.string.resolve_mine_help), style = MaterialTheme.typography.bodySmall)
                    Button(onClick = onKeepBoth, enabled = state.canChoose && state.canKeepBoth) {
                        Text(stringResource(R.string.resolve_keep_both))
                    }
                    Text(stringResource(R.string.resolve_both_help), style = MaterialTheme.typography.bodySmall)
                }
            }
            item {
                TextButton(onClick = onAccount) { Text(stringResource(R.string.account_settings)) }
                TextButton(onClick = onSyncDetails) { Text(stringResource(R.string.resolve_sync_details)) }
                if (state.completionMessage != null) TextButton(onClick = onBack) { Text(stringResource(R.string.resolve_done)) }
                Spacer(Modifier.height(12.dp))
            }
        }
    }
    if (state.closePending) AlertDialog(onDismissRequest = onDismissClose,
        title = { Text(stringResource(R.string.resolve_leave_title)) },
        text = { Text(stringResource(R.string.resolve_leave_help)) },
        confirmButton = { TextButton(onClick = onConfirmClose) { Text(stringResource(R.string.resolve_leave)) } },
        dismissButton = { TextButton(onClick = onDismissClose) { Text(stringResource(R.string.resolve_stay)) } })
}
