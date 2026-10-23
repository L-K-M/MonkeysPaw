package ch.lkmc.monkeyspaw.ui.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReviewSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.LlmRubricCriterion

@Composable
internal fun ReviewScreen(
    state: ReviewUiState,
    onReview: () -> Unit,
    onEffort: (AssistantEffort?) -> Unit,
    onFinding: (Int) -> Unit,
    onQuote: (Int) -> Unit,
    onImprove: () -> Unit,
    onFeedback: (String) -> Unit,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
    onBack: () -> Unit,
    onReload: () -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val result = state.assistant
    AssistantScaffold(
        title = stringResource(R.string.assistant_review_title),
        onBack = onBack,
        onSettings = onSettings,
        header = { AssistantFooter(result) },
        dock = {
            if (state.isWorking) {
                TextButton(onClick = onCancel) {
                    Text(stringResource(R.string.assistant_cancel))
                }
            } else if (result?.review != null) {
                Button(onClick = onImprove, enabled = state.canImproveWithThese) {
                    Text(stringResource(R.string.assistant_improve_selected))
                }
            } else {
                Button(onClick = onReview, enabled = state.canReview) {
                    Text(stringResource(R.string.assistant_review_send))
                }
            }
        },
        modifier = modifier,
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.assistant_review_disclosure),
                    style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.assistant_key_disclosure),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                AssistantEffortControl(state.effort, !state.isWorking, onEffort)
                if (result?.review != null && !state.isWorking) {
                    TextButton(onClick = onReview, enabled = state.canReview, modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.assistant_review_send))
                    }
                }
                state.unavailable?.let { reason ->
                    val providerDown = reason == ReviewUnavailable.PROVIDER
                    AssistantNotice(stringResource(reviewUnavailableResource(reason)),
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
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val failure = result?.failure
                AssistantNotice(
                    text = stringResource(when {
                        failure is ch.lkmc.monkeyspaw.core.services.AssistantFailure.Invalid -> R.string.assistant_review_invalid
                        failure != null -> assistantFailureResource(failure)
                        result?.isStale == true -> R.string.assistant_review_stale
                        state.isWorking -> R.string.assistant_working
                        result?.review != null -> R.string.assistant_review_complete
                        else -> R.string.assistant_review_help
                    }),
                    tone = when {
                        failure != null -> AssistantTone.ERROR
                        result?.isStale == true -> AssistantTone.WARNING
                        state.isWorking -> AssistantTone.INFO
                        result?.review != null -> AssistantTone.SUCCESS
                        else -> AssistantTone.INFO
                    })
                if (state.isWorking) AssistantBusy()
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistantSection(R.string.assistant_review_local)
                if (state.localIssues.isEmpty()) {
                    Text(stringResource(R.string.assistant_review_local_empty),
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                ArtifactIssues(state.localIssues)
            }
        }
        result?.review?.let { review ->
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    AssistantSection(R.string.assistant_review_summary)
                    SelectionContainer { Text(review.summary, style = MaterialTheme.typography.bodyMedium) }
                    if (review.findings.isEmpty()) {
                        Text(stringResource(R.string.assistant_review_empty),
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            itemsIndexed(review.findings) { index, finding ->
                ReviewFindingCard(index, finding, result.selectedFindings, state.canSelectFindings, onFinding, onQuote)
            }
        }
        if (state.canRetry) item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.assistant_review_retry_help),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(value = state.feedback, onValueChange = onFeedback,
                    label = { Text(stringResource(R.string.assistant_feedback)) }, minLines = 2,
                    modifier = Modifier.fillMaxWidth())
                TextButton(onClick = onRetry, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(R.string.assistant_retry_feedback))
                }
            }
        }
    }
}

@Composable
private fun ReviewFindingCard(
    index: Int,
    finding: LlmReview.Finding,
    selectedFindings: Set<Int>,
    canSelect: Boolean,
    onFinding: (Int) -> Unit,
    onQuote: (Int) -> Unit,
) {
    val (icon, tint) = when (finding.severity) {
        LlmReviewSeverity.HIGH -> Icons.Rounded.ErrorOutline to MaterialTheme.colorScheme.error
        LlmReviewSeverity.MEDIUM -> Icons.Rounded.WarningAmber to MaterialTheme.colorScheme.tertiary
        LlmReviewSeverity.LOW -> Icons.Rounded.Info to MaterialTheme.colorScheme.onSurfaceVariant
    }
    OutlinedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val heading = stringResource(R.string.assistant_review_finding,
                stringResource(reviewSeverityResource(finding.severity)),
                stringResource(reviewCriterionResource(finding.criterion)))
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = index in selectedFindings,
                enabled = canSelect, role = Role.Checkbox, onValueChange = { onFinding(index) }),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = index in selectedFindings, onCheckedChange = null, enabled = canSelect)
                Icon(icon, null, Modifier.size(18.dp), tint = tint)
                Text(heading, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f),
                    color = if (finding.severity == LlmReviewSeverity.HIGH) MaterialTheme.colorScheme.error
                        else MaterialTheme.colorScheme.onSurface)
            }
            SelectionContainer {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(R.string.assistant_review_problem, finding.problem),
                        style = MaterialTheme.typography.bodyMedium)
                    Text(stringResource(R.string.assistant_review_suggestion, finding.suggestion),
                        style = MaterialTheme.typography.bodyMedium)
                    Text(stringResource(R.string.assistant_review_quote, finding.quote),
                        fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                }
            }
            if (finding.quoteMatch is LlmReview.QuoteMatch.Matched) {
                TextButton(onClick = { onQuote(index) }, enabled = canSelect) {
                    Text(stringResource(R.string.assistant_review_show_quote))
                }
            } else {
                Text(stringResource(R.string.assistant_review_unmatched),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

internal fun reviewUnavailableResource(reason: ReviewUnavailable): Int = when (reason) {
    ReviewUnavailable.PROVIDER -> R.string.assistant_setup
    ReviewUnavailable.LIBRARY -> R.string.assistant_graph_failed
    ReviewUnavailable.ACCESS -> R.string.assistant_review_access
    ReviewUnavailable.BUSY -> R.string.assistant_editor_busy
    ReviewUnavailable.CONFLICT -> R.string.assistant_review_conflict
    ReviewUnavailable.SOURCE -> R.string.assistant_no_editor
    ReviewUnavailable.READ_ONLY -> R.string.editor_read_only_failed
    ReviewUnavailable.INVALID -> R.string.assistant_review_invalid
    ReviewUnavailable.PRIVATE -> R.string.assistant_private
    ReviewUnavailable.VALIDATING -> R.string.editor_validating
}

internal fun reviewSeverityResource(severity: LlmReviewSeverity): Int = when (severity) {
    LlmReviewSeverity.HIGH -> R.string.assistant_review_high
    LlmReviewSeverity.MEDIUM -> R.string.assistant_review_medium
    LlmReviewSeverity.LOW -> R.string.assistant_review_low
}

internal fun reviewCriterionResource(criterion: LlmRubricCriterion): Int = when (criterion) {
    LlmRubricCriterion.CLARITY -> R.string.assistant_review_clarity
    LlmRubricCriterion.CONTEXT -> R.string.assistant_review_context
    LlmRubricCriterion.ROLE -> R.string.assistant_review_role
    LlmRubricCriterion.DELIMITING -> R.string.assistant_review_delimiting
    LlmRubricCriterion.OUTPUT_FORMAT -> R.string.assistant_review_output_format
    LlmRubricCriterion.EXAMPLES -> R.string.assistant_review_examples
    LlmRubricCriterion.REASONING -> R.string.assistant_review_reasoning
    LlmRubricCriterion.VERIFIABILITY -> R.string.assistant_review_verifiability
    LlmRubricCriterion.DECOMPOSITION -> R.string.assistant_review_decomposition
    LlmRubricCriterion.PLACEHOLDERS -> R.string.assistant_review_placeholders
}
