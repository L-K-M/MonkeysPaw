package ch.lkmc.monkeyspaw.ui.assistant

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.PlaceholderChange
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.ui.components.PawLoading
import ch.lkmc.monkeyspaw.ui.components.PawActionDock
import ch.lkmc.monkeyspaw.ui.components.PawMessage
import ch.lkmc.monkeyspaw.ui.components.PawMessageTone
import ch.lkmc.monkeyspaw.ui.components.PawScreen
import ch.lkmc.monkeyspaw.ui.components.PawSectionHeading
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

/**
 * Shared chrome for the three assistant routes: a stable back/title/settings
 * app bar, a bounded reading column, a scrollable session header and a docked
 * bar carrying the current state's primary actions.
 */
@Composable
internal fun AssistantScaffold(
    title: String,
    onBack: () -> Unit,
    onSettings: () -> Unit,
    header: @Composable () -> Unit,
    dock: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    content: LazyListScope.() -> Unit,
) {
    PawScreen(title = title, modifier = modifier, onBack = onBack,
        actions = {
            IconButton(onClick = onSettings) {
                Icon(Icons.Rounded.Settings, stringResource(R.string.assistant_settings_title))
            }
        },
        bottomBar = { AssistantActionDock { dock() } }) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PawLayout.contentPadding,
            verticalArrangement = Arrangement.spacedBy(PawSpacing.large)) {
            item { header() }
            content()
        }
    }
}

/** Docked actions wrap onto extra rows, so large font scales keep every action reachable. */
@Composable
private fun AssistantActionDock(content: @Composable () -> Unit) {
    PawActionDock { content() }
}

internal enum class AssistantTone { INFO, WARNING, ERROR, SUCCESS }

/** One banner style for disclosures, failures, outcomes and warnings. */
@Composable
internal fun AssistantNotice(text: String, tone: AssistantTone = AssistantTone.INFO,
    actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    PawMessage(text, tone = when (tone) {
        AssistantTone.INFO -> PawMessageTone.INFO
        AssistantTone.WARNING -> PawMessageTone.WARNING
        AssistantTone.ERROR -> PawMessageTone.ERROR
        AssistantTone.SUCCESS -> PawMessageTone.SUCCESS
    }, actionLabel = actionLabel, onAction = onAction)
}

@Composable
internal fun AssistantSection(title: Int, supportingText: Int? = null) {
    PawSectionHeading(stringResource(title), supportingText = supportingText?.let { stringResource(it) })
}

@Composable
internal fun AssistantLoading() {
    PawLoading(stringResource(R.string.assistant_graph_loading))
}

/** Indeterminate work; the dock keeps cancel as the only offered action. */
@Composable
internal fun AssistantBusy() {
    LinearProgressIndicator(Modifier.fillMaxWidth())
}

@Composable
internal fun ArtifactDraft(artifact: LlmArtifact) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        AssistantSection(R.string.assistant_draft)
        Text(artifact.title, style = MaterialTheme.typography.titleMedium)
        Text(artifact.description, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (artifact.tags.isNotEmpty()) {
            Text(stringResource(R.string.assistant_draft_tags, artifact.tags.joinToString(", ")),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            SelectionContainer {
                Text(artifact.body, Modifier.fillMaxWidth().padding(PawSpacing.large),
                    style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

@Composable
internal fun ArtifactFields(fields: List<LlmArtifact.Field>) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        AssistantSection(R.string.editor_fields)
        if (fields.isEmpty()) {
            Text(stringResource(R.string.editor_no_fields), style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        for (field in fields) Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
            color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Column(Modifier.padding(PawSpacing.medium), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                Text(field.label, style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.assistant_field_type, field.name, field.type.rawValue),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (field.description.isNotEmpty()) {
                    Text(field.description, style = MaterialTheme.typography.bodyMedium)
                }
                Text(stringResource(R.string.editor_field_default, field.defaultValue),
                    style = MaterialTheme.typography.bodySmall)
                for (option in field.options) {
                    Text(stringResource(R.string.assistant_field_option, option.label, option.value),
                        style = MaterialTheme.typography.bodySmall)
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    FieldBadge(stringResource(if (field.optional) R.string.editor_optional else R.string.editor_required))
                    FieldBadge(stringResource(if (field.remember) R.string.editor_remembered else R.string.editor_not_remembered))
                }
            }
        }
    }
}

@Composable
private fun FieldBadge(text: String) {
    Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.secondaryContainer) {
        Text(text, Modifier.padding(horizontal = PawSpacing.small, vertical = PawSpacing.xs),
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSecondaryContainer)
    }
}

@Composable
internal fun ArtifactIssues(issues: List<PromptIssue>) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        for (issue in issues) {
            val location = issue.location?.toString()
            AssistantNotice(text = if (location == null) issue.message else "${issue.message}\n$location",
                tone = if (issue.severity == PromptIssueSeverity.ERROR) AssistantTone.ERROR else AssistantTone.WARNING)
        }
    }
}

@Composable
internal fun ArtifactNotes(notes: String) {
    if (notes.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        AssistantSection(R.string.assistant_notes)
        Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            SelectionContainer {
                Text(notes, Modifier.fillMaxWidth().padding(PawSpacing.large),
                    style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** The checked save consumes this exact canonical source, including its preflighted identity. */
@Composable
internal fun ArtifactPreview(candidate: AssistantCandidate) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        AssistantSection(R.string.assistant_save_preview, supportingText = R.string.assistant_save_preview_help)
        Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            SelectionContainer {
                Text(candidate.content.document.source, Modifier.fillMaxWidth().padding(PawSpacing.large),
                    fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
        }
        for (warning in candidate.diff.placeholderWarnings) {
            AssistantNotice(placeholderWarningText(warning), tone = AssistantTone.WARNING)
        }
    }
}

@Composable
internal fun placeholderWarningText(warning: PlaceholderChange): String = when (warning) {
    is PlaceholderChange.Added -> stringResource(R.string.assistant_placeholder_added, warning.name)
    is PlaceholderChange.Removed -> stringResource(R.string.assistant_placeholder_removed, warning.name)
    is PlaceholderChange.Renamed -> stringResource(R.string.assistant_placeholder_renamed, warning.from, warning.to)
}

@Composable
internal fun AssistantEffortControl(effort: AssistantEffort?, enabled: Boolean, onEffort: (AssistantEffort?) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        Text(stringResource(R.string.assistant_effort), style = MaterialTheme.typography.labelLarge)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small),
            verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
            FilterChip(selected = effort == null, onClick = { onEffort(null) }, enabled = enabled,
                label = { Text(stringResource(R.string.assistant_effort_default)) })
            for (value in AssistantEffort.entries) {
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
}

@Composable
internal fun AssistantFooter(state: AssistantState?, modifier: Modifier = Modifier) {
    val host = state?.providerHost
    val model = state?.modelID
    SelectionContainer(modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
            if (host == null || model == null) {
                Text(stringResource(R.string.assistant_inactive), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Text(stringResource(R.string.assistant_destination, host, model),
                    style = MaterialTheme.typography.bodySmall)
            }
            if (state != null && (state.phase == AssistantPhase.WORKING || state.elapsedSeconds > 0)) {
                Text(stringResource(R.string.assistant_elapsed, state.elapsedSeconds),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            state?.usage?.let {
                Text(stringResource(R.string.assistant_usage, it.inputTokens, it.outputTokens),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
internal fun AssistantResult(state: AssistantState?, outcome: AssistantAcceptanceOutcome?) {
    val failure = state?.failure
    val (message, tone) = when {
        state?.isAccepting == true -> R.string.assistant_accepting to AssistantTone.INFO
        outcome != null -> assistantOutcomeResource(outcome) to assistantOutcomeTone(outcome)
        failure != null -> assistantFailureResource(failure) to AssistantTone.ERROR
        state?.isStale == true -> R.string.assistant_stale to AssistantTone.WARNING
        else -> when (state?.phase) {
            AssistantPhase.WORKING -> R.string.assistant_working to AssistantTone.INFO
            AssistantPhase.DRAFT -> R.string.assistant_draft_help to AssistantTone.INFO
            AssistantPhase.READY -> R.string.assistant_ready to AssistantTone.INFO
            AssistantPhase.SAVED -> R.string.assistant_saved to AssistantTone.SUCCESS
            AssistantPhase.FAILED -> R.string.assistant_failed to AssistantTone.ERROR
            else -> R.string.assistant_idle to AssistantTone.INFO
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        AssistantNotice(stringResource(message), tone)
        if (outcome?.committed?.historyMaintenanceFailed == true) {
            AssistantNotice(stringResource(R.string.assistant_history_warning), AssistantTone.WARNING)
        }
    }
}

private fun assistantOutcomeTone(outcome: AssistantAcceptanceOutcome): AssistantTone = when (outcome) {
    is AssistantAcceptanceOutcome.Saved -> AssistantTone.SUCCESS
    is AssistantAcceptanceOutcome.CommittedWithProvenanceWarning -> AssistantTone.WARNING
    is AssistantAcceptanceOutcome.Conflict -> AssistantTone.WARNING
    is AssistantAcceptanceOutcome.Failed -> AssistantTone.ERROR
}
