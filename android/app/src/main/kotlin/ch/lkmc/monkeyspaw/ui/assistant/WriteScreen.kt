package ch.lkmc.monkeyspaw.ui.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort

/** Inputs and results stay in presentation state; this view only renders and forwards intents. */
@Composable
internal fun WriteScreen(
    state: WriteUiState,
    onBrief: (String) -> Unit,
    onEffort: (AssistantEffort?) -> Unit,
    onWrite: () -> Unit,
    onFeedback: (String) -> Unit,
    onRetry: () -> Unit,
    onShowDiff: () -> Unit,
    onAccept: () -> Unit,
    onReject: () -> Unit,
    onCancel: () -> Unit,
    onBack: () -> Unit,
    onReload: () -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        TextButton(onClick = onBack) { Text(stringResource(R.string.assistant_write_back)) }
        Text(stringResource(R.string.assistant_write_title), style = MaterialTheme.typography.headlineMedium)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Text(stringResource(R.string.assistant_write_disclosure))
                Text(stringResource(R.string.assistant_key_disclosure), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(value = state.brief, onValueChange = onBrief, enabled = state.canEdit,
                    label = { Text(stringResource(R.string.assistant_write_brief)) }, minLines = 3,
                    modifier = Modifier.fillMaxWidth())
                AssistantEffortControl(state.effort, state.canEdit, onEffort)
                Button(onClick = onWrite, enabled = state.canWrite) { Text(stringResource(R.string.assistant_write_send)) }
                state.unavailable?.let { Text(stringResource(assistantUnavailableResource(it))) }
                if (state.unavailable == AssistantUnavailable.PROVIDER) {
                    TextButton(onClick = onSettings) { Text(stringResource(R.string.assistant_settings_title)) }
                }
                if (state.loading) CircularProgressIndicator()
                if (state.loadFailed) {
                    Text(stringResource(R.string.assistant_graph_failed), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onReload) { Text(stringResource(R.string.retry)) }
                }
            }
            item { AssistantResult(state.assistant, state.acceptanceOutcome) }
            state.assistant?.artifact?.let { artifact ->
                item { ArtifactDraft(artifact) }
                item { ArtifactFields(artifact.fields) }
                item { ArtifactNotes(artifact.notes) }
            }
            item { ArtifactIssues(state.assistant?.issues.orEmpty()) }
            state.assistant?.candidate?.let { candidate -> item { ArtifactPreview(candidate) } }
            item {
                if (state.isWorking || state.isAccepting) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.assistant_cancel)) }
                } else if (state.assistant?.artifact != null) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        TextButton(onClick = onShowDiff, enabled = state.canShowDiff) { Text(stringResource(R.string.assistant_show_diff)) }
                        Button(onClick = onAccept, enabled = state.canAccept) { Text(stringResource(R.string.assistant_accept)) }
                        TextButton(onClick = onReject) { Text(stringResource(R.string.assistant_reject)) }
                    }
                }
                if (state.canRetry) {
                    Text(stringResource(R.string.assistant_retry_help), style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(value = state.feedback, onValueChange = onFeedback, enabled = state.canEdit,
                        label = { Text(stringResource(R.string.assistant_feedback)) }, minLines = 2,
                        modifier = Modifier.fillMaxWidth())
                    TextButton(onClick = onRetry) { Text(stringResource(R.string.assistant_retry_feedback)) }
                }
            }
            item { Spacer(Modifier.height(12.dp)) }
        }
        HorizontalDivider()
        AssistantFooter(state.assistant, Modifier.padding(vertical = 12.dp))
    }
}
