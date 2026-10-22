package ch.lkmc.monkeyspaw.ui.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
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
    val result = state.assistant
    AssistantScaffold(
        title = stringResource(if (state.isPrivateCopy) R.string.assistant_improve_copy else R.string.assistant_improve_title),
        onBack = onBack,
        onSettings = onSettings,
        footer = { AssistantFooter(result) },
        modifier = modifier,
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.assistant_improve_disclosure),
                    style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.assistant_key_disclosure),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (state.isPrivateCopy) {
                    AssistantNotice(stringResource(R.string.assistant_improve_copy_help), tone = AssistantTone.WARNING)
                }
                OutlinedTextField(value = result?.instruction.orEmpty(), onValueChange = onInstruction,
                    enabled = state.canEdit, label = { Text(stringResource(R.string.assistant_improve_instruction)) },
                    minLines = 2, modifier = Modifier.fillMaxWidth())
                Text(stringResource(R.string.assistant_improve_help),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                AssistantEffortControl(state.effort, state.canEdit, onEffort)
                Button(onClick = onImprove, enabled = state.canImprove, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(if (state.isPrivateCopy) R.string.assistant_improve_copy else R.string.assistant_improve_send))
                }
                state.unavailable?.let { reason ->
                    val providerDown = reason == ReviewUnavailable.PROVIDER
                    AssistantNotice(stringResource(improveUnavailableResource(reason)),
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
        result?.review?.let { review ->
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    AssistantSection(R.string.assistant_improve_findings)
                    if (result.selectedFindings.isEmpty()) {
                        Text(stringResource(R.string.assistant_improve_no_findings),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    for (index in result.selectedFindings.sorted()) review.findings.getOrNull(index)?.let { finding ->
                        OutlinedCard(Modifier.fillMaxWidth()) {
                            SelectionContainer {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(stringResource(R.string.assistant_review_finding,
                                        stringResource(reviewSeverityResource(finding.severity)),
                                        stringResource(reviewCriterionResource(finding.criterion))),
                                        style = MaterialTheme.typography.titleSmall)
                                    Text(stringResource(R.string.assistant_review_problem, finding.problem),
                                        style = MaterialTheme.typography.bodyMedium)
                                    Text(stringResource(R.string.assistant_review_suggestion, finding.suggestion),
                                        style = MaterialTheme.typography.bodyMedium)
                                    Text(stringResource(R.string.assistant_review_quote, finding.quote),
                                        fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    }
                }
            }
        }
        item {
            if (result?.failure == null && result?.artifact == null && result?.isStale != true && !state.isWorking &&
                !state.isAccepting && state.acceptanceOutcome == null) {
                Text(stringResource(R.string.assistant_improve_help),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else AssistantResult(result, state.acceptanceOutcome)
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
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.isWorking || state.isAccepting) {
                    AssistantBusy(onCancel)
                } else if (result?.artifact != null) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        OutlinedButton(onClick = onShowDiff, enabled = state.canShowDiff) {
                            Text(stringResource(R.string.assistant_show_diff))
                        }
                        Button(onClick = onAccept, enabled = state.canAccept) {
                            Text(stringResource(R.string.assistant_accept))
                        }
                        TextButton(onClick = onReject) {
                            Text(stringResource(R.string.assistant_reject))
                        }
                    }
                }
                if (state.canRetry) {
                    Text(stringResource(R.string.assistant_improve_retry_help),
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

internal fun improveUnavailableResource(reason: ReviewUnavailable): Int = when (reason) {
    ReviewUnavailable.INVALID -> R.string.assistant_improve_invalid
    ReviewUnavailable.CONFLICT -> R.string.assistant_editor_conflict
    else -> reviewUnavailableResource(reason)
}
