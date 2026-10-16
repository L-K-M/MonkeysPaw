package ch.lkmc.monkeyspaw.ui.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.selection.SelectionContainer
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
    onFeedback: (String) -> Unit,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
    onBack: () -> Unit,
    onReload: () -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        TextButton(onClick = onBack) { Text(stringResource(R.string.assistant_write_back)) }
        Text(stringResource(R.string.assistant_review_title), style = MaterialTheme.typography.headlineMedium)
        val result = state.assistant
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Text(stringResource(R.string.assistant_review_disclosure))
                Text(stringResource(R.string.assistant_key_disclosure), style = MaterialTheme.typography.bodySmall)
                AssistantEffortControl(state.effort, !state.isWorking, onEffort)
                Button(onClick = onReview, enabled = state.canReview) { Text(stringResource(R.string.assistant_review_send)) }
                state.unavailable?.let { Text(stringResource(reviewUnavailableResource(it))) }
                if (state.unavailable == ReviewUnavailable.PROVIDER) {
                    TextButton(onClick = onSettings) { Text(stringResource(R.string.assistant_settings_title)) }
                }
                if (state.loading) CircularProgressIndicator()
                if (state.loadFailed) {
                    Text(stringResource(R.string.assistant_graph_failed), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onReload) { Text(stringResource(R.string.retry)) }
                }
            }
            item {
                val failure = result?.failure
                Text(stringResource(when {
                    failure is ch.lkmc.monkeyspaw.core.services.AssistantFailure.Invalid -> R.string.assistant_review_invalid
                    failure != null -> assistantFailureResource(failure)
                    result?.isStale == true -> R.string.assistant_review_stale
                    state.isWorking -> R.string.assistant_working
                    result?.review != null -> R.string.assistant_review_complete
                    else -> R.string.assistant_review_help
                }))
                if (state.isWorking) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.assistant_cancel)) }
                }
            }
            item {
                Text(stringResource(R.string.assistant_review_local), style = MaterialTheme.typography.titleMedium)
                if (state.localIssues.isEmpty()) Text(stringResource(R.string.assistant_review_local_empty))
                ArtifactIssues(state.localIssues)
            }
            result?.review?.let { review ->
                item {
                    Text(stringResource(R.string.assistant_review_summary), style = MaterialTheme.typography.titleMedium)
                    SelectionContainer { Text(review.summary) }
                    if (review.findings.isEmpty()) Text(stringResource(R.string.assistant_review_empty))
                }
                itemsIndexed(review.findings) { index, finding ->
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            val heading = stringResource(R.string.assistant_review_finding,
                                stringResource(reviewSeverityResource(finding.severity)),
                                stringResource(reviewCriterionResource(finding.criterion)))
                            Row(Modifier.fillMaxWidth().toggleable(value = index in result.selectedFindings,
                                enabled = state.canSelectFindings, role = Role.Checkbox, onValueChange = { onFinding(index) }),
                                verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(checked = index in result.selectedFindings, onCheckedChange = null,
                                    enabled = state.canSelectFindings)
                                Text(heading, style = MaterialTheme.typography.titleSmall,
                                    color = if (finding.severity == LlmReviewSeverity.HIGH) MaterialTheme.colorScheme.error
                                        else MaterialTheme.colorScheme.onSurface)
                            }
                            SelectionContainer {
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(stringResource(R.string.assistant_review_problem, finding.problem))
                                    Text(stringResource(R.string.assistant_review_suggestion, finding.suggestion))
                                    Text(stringResource(R.string.assistant_review_quote, finding.quote), fontFamily = FontFamily.Monospace)
                                }
                            }
                            if (finding.quoteMatch is LlmReview.QuoteMatch.Matched) {
                                TextButton(onClick = { onQuote(index) }, enabled = state.canSelectFindings) {
                                    Text(stringResource(R.string.assistant_review_show_quote))
                                }
                            } else Text(stringResource(R.string.assistant_review_unmatched), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
            if (state.canRetry) item {
                Text(stringResource(R.string.assistant_review_retry_help), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(value = state.feedback, onValueChange = onFeedback,
                    label = { Text(stringResource(R.string.assistant_feedback)) }, minLines = 2, modifier = Modifier.fillMaxWidth())
                TextButton(onClick = onRetry) { Text(stringResource(R.string.assistant_retry_feedback)) }
            }
            item { Spacer(Modifier.height(12.dp)) }
        }
        HorizontalDivider()
        AssistantFooter(result, Modifier.padding(vertical = 12.dp))
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
