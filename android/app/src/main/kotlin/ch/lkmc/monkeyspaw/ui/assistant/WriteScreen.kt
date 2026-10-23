package ch.lkmc.monkeyspaw.ui.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.ui.components.PawIntro
import ch.lkmc.monkeyspaw.ui.components.PawTextField
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

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
    AssistantScaffold(
        title = stringResource(R.string.assistant_write_title),
        onBack = onBack,
        onSettings = onSettings,
        header = { AssistantFooter(state.assistant) },
        dock = {
            if (state.isWorking || state.isAccepting) {
                TextButton(onClick = onCancel) {
                    Text(stringResource(R.string.assistant_cancel))
                }
            } else if (state.assistant?.artifact != null) {
                OutlinedButton(onClick = onShowDiff, enabled = state.canShowDiff) {
                    Text(stringResource(R.string.assistant_show_diff))
                }
                Button(onClick = onAccept, enabled = state.canAccept) {
                    Text(stringResource(R.string.assistant_accept))
                }
                TextButton(onClick = onReject) {
                    Text(stringResource(R.string.assistant_reject))
                }
            } else {
                Button(onClick = onWrite, enabled = state.canWrite) {
                    Text(stringResource(R.string.assistant_write_send))
                }
            }
        },
        modifier = modifier,
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.large)) {
                if (state.assistant?.artifact == null) PawIntro(stringResource(R.string.design_assistant_intro),
                    stringResource(R.string.design_assistant_intro_help), Icons.Rounded.AutoAwesome)
                Text(stringResource(R.string.assistant_write_disclosure),
                    style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.assistant_key_disclosure),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                PawTextField(value = state.brief, onValueChange = onBrief, enabled = state.canEdit,
                    label = stringResource(R.string.assistant_write_brief), minLines = 3,
                    modifier = Modifier.fillMaxWidth())
                AssistantEffortControl(state.effort, state.canEdit, onEffort)
                if (state.assistant?.artifact != null && !state.isWorking && !state.isAccepting) {
                    TextButton(onClick = onWrite, enabled = state.canWrite, modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.assistant_write_send))
                    }
                }
                state.unavailable?.let { reason ->
                    val providerDown = reason == AssistantUnavailable.PROVIDER
                    AssistantNotice(stringResource(assistantUnavailableResource(reason)),
                        tone = AssistantTone.ERROR,
                        actionLabel = stringResource(R.string.assistant_settings_title).takeIf { providerDown },
                        onAction = onSettings.takeIf { providerDown })
                }
                if (state.loading) AssistantLoading()
                if (state.loadFailed) {
                    AssistantNotice(stringResource(R.string.assistant_graph_failed), tone = AssistantTone.ERROR,
                        actionLabel = stringResource(R.string.retry), onAction = onReload)
                }
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
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.isWorking || state.isAccepting) {
                    AssistantBusy()
                }
                if (state.canRetry) {
                    Text(stringResource(R.string.assistant_retry_help),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedTextField(value = state.feedback, onValueChange = onFeedback, enabled = state.canEdit,
                        label = { Text(stringResource(R.string.assistant_feedback)) }, minLines = 2,
                        modifier = Modifier.fillMaxWidth())
                    TextButton(onClick = onRetry, modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.assistant_retry_feedback))
                    }
                }
            }
        }
    }
}
