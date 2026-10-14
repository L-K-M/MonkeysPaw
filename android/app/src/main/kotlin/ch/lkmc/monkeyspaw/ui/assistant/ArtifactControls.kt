package ch.lkmc.monkeyspaw.ui.assistant

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.PlaceholderChange
import ch.lkmc.monkeyspaw.core.services.*

@Composable
internal fun ArtifactDraft(artifact: LlmArtifact) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.assistant_draft), style = MaterialTheme.typography.titleLarge)
        Text(artifact.title, style = MaterialTheme.typography.titleMedium)
        Text(artifact.description)
        if (artifact.tags.isNotEmpty()) Text(stringResource(R.string.assistant_draft_tags, artifact.tags.joinToString(", ")))
        SelectionContainer { Text(artifact.body, fontFamily = FontFamily.Monospace) }
    }
}

@Composable
internal fun ArtifactFields(fields: List<LlmArtifact.Field>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.editor_fields), style = MaterialTheme.typography.titleMedium)
        if (fields.isEmpty()) Text(stringResource(R.string.editor_no_fields))
        for (field in fields) Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(field.label, style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.assistant_field_type, field.name, field.type.rawValue))
                if (field.description.isNotEmpty()) Text(field.description)
                Text(stringResource(R.string.editor_field_default, field.defaultValue))
                for (option in field.options) Text(stringResource(R.string.assistant_field_option, option.label, option.value))
                Text(stringResource(if (field.optional) R.string.editor_optional else R.string.editor_required))
                Text(stringResource(if (field.remember) R.string.editor_remembered else R.string.editor_not_remembered))
            }
        }
    }
}

@Composable
internal fun ArtifactIssues(issues: List<PromptIssue>) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (issue in issues) {
            Text(issue.message, color = if (issue.severity == PromptIssueSeverity.ERROR) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant)
            issue.location?.let { Text(it.toString(), style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
internal fun ArtifactNotes(notes: String) {
    if (notes.isEmpty()) return
    Column {
        Text(stringResource(R.string.assistant_notes), style = MaterialTheme.typography.titleMedium)
        SelectionContainer { Text(notes) }
    }
}

/** The checked save consumes this exact canonical source, including its preflighted identity. */
@Composable
internal fun ArtifactPreview(candidate: AssistantCandidate) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.assistant_save_preview), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.assistant_save_preview_help), style = MaterialTheme.typography.bodySmall)
        SelectionContainer { Text(candidate.content.document.source, fontFamily = FontFamily.Monospace) }
        for (warning in candidate.diff.placeholderWarnings) Text(when (warning) {
            is PlaceholderChange.Added -> stringResource(R.string.assistant_placeholder_added, warning.name)
            is PlaceholderChange.Removed -> stringResource(R.string.assistant_placeholder_removed, warning.name)
            is PlaceholderChange.Renamed -> stringResource(R.string.assistant_placeholder_renamed, warning.from, warning.to)
        })
    }
}

@Composable
internal fun AssistantEffortControl(effort: AssistantEffort?, enabled: Boolean, onEffort: (AssistantEffort?) -> Unit) {
    Text(stringResource(R.string.assistant_effort), style = MaterialTheme.typography.labelLarge)
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            FilterChip(selected = effort == null, onClick = { onEffort(null) }, enabled = enabled,
                label = { Text(stringResource(R.string.assistant_effort_default)) })
        }
        items(AssistantEffort.entries) { value ->
            FilterChip(selected = effort == value, onClick = { onEffort(value) }, enabled = enabled,
                label = { Text(stringResource(when (value) {
                    AssistantEffort.LOW -> R.string.assistant_effort_low
                    AssistantEffort.MEDIUM -> R.string.assistant_effort_medium
                    AssistantEffort.HIGH -> R.string.assistant_effort_high
                    AssistantEffort.XHIGH -> R.string.assistant_effort_xhigh
                    AssistantEffort.MAX -> R.string.assistant_effort_max
                })) })
        }
    }
}

@Composable
internal fun AssistantFooter(state: AssistantState?, modifier: Modifier = Modifier) {
    val host = state?.providerHost
    val model = state?.modelID
    SelectionContainer(modifier) {
        Column {
            if (host == null || model == null) Text(stringResource(R.string.assistant_inactive))
            else Text(stringResource(R.string.assistant_destination, host, model))
            if (state != null && (state.phase == AssistantPhase.WORKING || state.elapsedSeconds > 0)) {
                Text(stringResource(R.string.assistant_elapsed, state.elapsedSeconds))
            }
            state?.usage?.let { Text(stringResource(R.string.assistant_usage, it.inputTokens, it.outputTokens)) }
        }
    }
}

@Composable
internal fun AssistantResult(state: AssistantState?, outcome: AssistantAcceptanceOutcome?) {
    val failure = state?.failure
    val message = when {
        state?.isAccepting == true -> R.string.assistant_accepting
        outcome != null -> assistantOutcomeResource(outcome)
        failure != null -> assistantFailureResource(failure)
        state?.isStale == true -> R.string.assistant_stale
        else -> when (state?.phase) {
            AssistantPhase.WORKING -> R.string.assistant_working
            AssistantPhase.DRAFT -> R.string.assistant_draft_help
            AssistantPhase.READY -> R.string.assistant_ready
            AssistantPhase.SAVED -> R.string.assistant_saved
            AssistantPhase.FAILED -> R.string.assistant_failed
            else -> R.string.assistant_idle
        }
    }
    Text(stringResource(message))
    if (outcome?.committed?.historyMaintenanceFailed == true) Text(stringResource(R.string.assistant_history_warning))
}
