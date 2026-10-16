package ch.lkmc.monkeyspaw.ui.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort

@Composable
internal fun ImproveScreen(
    state: ImproveUiState,
    onInstruction: (String) -> Unit,
    onEffort: (AssistantEffort?) -> Unit,
    onImprove: () -> Unit,
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
        Text(stringResource(if (state.isPrivateCopy) R.string.assistant_improve_copy else R.string.assistant_improve_title),
            style = MaterialTheme.typography.headlineMedium)
        val result = state.assistant
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Text(stringResource(R.string.assistant_improve_disclosure))
                Text(stringResource(R.string.assistant_key_disclosure), style = MaterialTheme.typography.bodySmall)
                if (state.isPrivateCopy) Text(stringResource(R.string.assistant_improve_copy_help))
                OutlinedTextField(value = result?.instruction.orEmpty(), onValueChange = onInstruction, enabled = state.canEdit,
                    label = { Text(stringResource(R.string.assistant_improve_instruction)) }, minLines = 2,
                    modifier = Modifier.fillMaxWidth())
                Text(stringResource(R.string.assistant_improve_help), style = MaterialTheme.typography.bodySmall)
                AssistantEffortControl(state.effort, state.canEdit, onEffort)
                Button(onClick = onImprove, enabled = state.canImprove) {
                    Text(stringResource(if (state.isPrivateCopy) R.string.assistant_improve_copy else R.string.assistant_improve_send))
                }
                state.unavailable?.let { Text(stringResource(improveUnavailableResource(it))) }
                if (state.unavailable == ReviewUnavailable.PROVIDER) {
                    TextButton(onClick = onSettings) { Text(stringResource(R.string.assistant_settings_title)) }
                }
                if (state.loading) CircularProgressIndicator()
                if (state.loadFailed) {
                    Text(stringResource(R.string.assistant_graph_failed), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onReload) { Text(stringResource(R.string.retry)) }
                }
            }
            result?.review?.let { review ->
                item {
                    Text(stringResource(R.string.assistant_improve_findings), style = MaterialTheme.typography.titleMedium)
                    if (result.selectedFindings.isEmpty()) Text(stringResource(R.string.assistant_improve_no_findings))
                    for (index in result.selectedFindings.sorted()) review.findings.getOrNull(index)?.let { finding ->
                        Card(Modifier.fillMaxWidth()) {
                            SelectionContainer {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(stringResource(R.string.assistant_review_finding,
                                        stringResource(reviewSeverityResource(finding.severity)),
                                        stringResource(reviewCriterionResource(finding.criterion))))
                                    Text(stringResource(R.string.assistant_review_problem, finding.problem))
                                    Text(stringResource(R.string.assistant_review_suggestion, finding.suggestion))
                                    Text(stringResource(R.string.assistant_review_quote, finding.quote))
                                }
                            }
                        }
                    }
                }
            }
            item {
                if (result?.failure == null && result?.artifact == null && result?.isStale != true && !state.isWorking && !state.isAccepting &&
                    state.acceptanceOutcome == null) Text(stringResource(R.string.assistant_improve_help))
                else AssistantResult(result, state.acceptanceOutcome)
            }
            result?.artifact?.let { artifact ->
                item { ArtifactDraft(artifact) }
                item { ArtifactFields(artifact.fields) }
                item { ArtifactNotes(artifact.notes) }
            }
            item { ArtifactIssues(result?.issues.orEmpty()) }
            result?.candidate?.let { candidate ->
                item { ImproveDiffView(candidate.diff) }
                item { ArtifactPreview(candidate) }
            }
            item {
                if (state.isWorking || state.isAccepting) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.assistant_cancel)) }
                } else if (result?.artifact != null) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = onShowDiff, enabled = state.canShowDiff) { Text(stringResource(R.string.assistant_show_diff)) }
                        Button(onClick = onAccept, enabled = state.canAccept) { Text(stringResource(R.string.assistant_accept)) }
                        TextButton(onClick = onReject) { Text(stringResource(R.string.assistant_reject)) }
                    }
                }
                if (state.canRetry) {
                    Text(stringResource(R.string.assistant_improve_retry_help), style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(value = state.feedback, onValueChange = onFeedback, enabled = state.canEdit,
                        label = { Text(stringResource(R.string.assistant_feedback)) }, minLines = 2,
                        modifier = Modifier.fillMaxWidth())
                    TextButton(onClick = onRetry) { Text(stringResource(R.string.assistant_retry_feedback)) }
                }
            }
            item { Spacer(Modifier.height(12.dp)) }
        }
        HorizontalDivider()
        AssistantFooter(result, Modifier.padding(vertical = 12.dp))
    }
}

internal fun improveUnavailableResource(reason: ReviewUnavailable): Int = when (reason) {
    ReviewUnavailable.INVALID -> R.string.assistant_improve_invalid
    ReviewUnavailable.CONFLICT -> R.string.assistant_editor_conflict
    else -> reviewUnavailableResource(reason)
}
