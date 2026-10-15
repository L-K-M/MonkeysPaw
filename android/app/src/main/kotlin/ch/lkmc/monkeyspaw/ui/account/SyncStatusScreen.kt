package ch.lkmc.monkeyspaw.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R

@Composable
internal fun SyncFooter(state: SyncStatusUiState, onDetails: () -> Unit, modifier: Modifier = Modifier) {
    Surface(onClick = onDetails, modifier = modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(state.title), style = MaterialTheme.typography.labelLarge)
            state.counts?.let {
                Text(stringResource(R.string.sync_footer_counts, it.fileErrors, it.conflicts, it.held, it.pending),
                    style = MaterialTheme.typography.bodySmall)
            }
            state.lastSuccess?.let {
                Text(stringResource(R.string.sync_last_success, it), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
internal fun SyncStatusScreen(state: AccountUiState, onSyncNow: () -> Unit, onAccount: () -> Unit,
    onBack: () -> Unit, onRecover: () -> Unit, modifier: Modifier = Modifier) {
    LazyColumn(modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TextButton(onClick = onBack) { Text(stringResource(R.string.account_back)) }
            Text(stringResource(R.string.sync_details), style = MaterialTheme.typography.headlineMedium)
            Text(stringResource(state.sync.title))
            state.sync.blockingText?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            state.failure?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            Text(state.sync.lastSuccess?.let { stringResource(R.string.sync_last_success, it) }
                ?: stringResource(R.string.sync_never_succeeded))
            state.sync.counts?.let {
                Text(stringResource(R.string.sync_pass_counts, it.pulled, it.pushed))
                Text(stringResource(R.string.sync_footer_counts, it.fileErrors, it.conflicts, it.held, it.pending))
            }
            TextButton(onClick = onSyncNow, enabled = state.canSync) { Text(stringResource(R.string.sync_now)) }
            TextButton(onClick = onAccount) { Text(stringResource(R.string.account_title)) }
            if (state.condition == AccountCondition.RECOVERY) TextButton(onClick = onRecover, enabled = state.busy == null) {
                Text(stringResource(R.string.sync_retry_recovery))
            }
        }
        items(state.sync.details, key = { it.path + ":" + it.code }) {
            Text(stringResource(R.string.sync_file_error, it.path, it.code))
        }
    }
}
