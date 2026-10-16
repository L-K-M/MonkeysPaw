package ch.lkmc.monkeyspaw.ui.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance

private enum class FileDialog { RENAME, MOVE, DELETE }

/** Raw source stays in the ViewModel. Dialog input is local; only confirmed intents leave the view. */
@Composable
internal fun EditorScreen(
    state: EditorUiState,
    onEdit: (String) -> Unit,
    onNewPath: (String) -> Unit,
    onTab: (EditorTab) -> Unit,
    onSave: () -> Unit,
    onBack: () -> Unit,
    onReload: () -> Unit,
    onRename: (String) -> Unit,
    onMove: (String) -> Unit,
    onDelete: () -> Unit,
    onHistory: () -> Unit,
    onRevision: (EditorRevision) -> Unit,
    onRestore: (EditorRevision) -> Unit,
    onDecision: (Long, EditorDecision) -> Unit,
    onConflict: (EditorConflictChoice) -> Unit,
    onReview: (() -> Unit)? = null,
    onImprove: (() -> Unit)? = null,
    onClearQuote: () -> Unit,
    modifier: Modifier = Modifier,
    backLabel: Int = R.string.editor_back,
) {
    BackHandler(onBack = onBack)
    var dialog by remember(state.relativePath) { mutableStateOf<FileDialog?>(null) }
    var destination by remember(state.relativePath) { mutableStateOf("") }
    LazyColumn(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = onBack) { Text(stringResource(backLabel)) }
                TextButton(onClick = onSave, enabled = state.canSave) { Text(stringResource(R.string.editor_save)) }
            }
            Text(state.title.ifEmpty { stringResource(R.string.editor_title) }, style = MaterialTheme.typography.headlineSmall)
            Text(state.relativePath.orEmpty(), style = MaterialTheme.typography.bodySmall)
            if (state.dirty) Text(stringResource(R.string.editor_unsaved))
            if (state.writing || state.status == EditorStatus.LOADING) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (state.readOnlyReason != null) Text(stringResource(R.string.editor_read_only))
            if (onReview != null) TextButton(onClick = onReview) { Text(stringResource(R.string.assistant_review_title)) }
            if (onImprove != null) TextButton(onClick = onImprove) { Text(stringResource(R.string.assistant_improve_title)) }
        }
        if (state.isNew) item {
            OutlinedTextField(value = state.relativePath.orEmpty(), onValueChange = onNewPath,
                label = { Text(stringResource(R.string.editor_path)) }, singleLine = true,
                enabled = !state.writing, modifier = Modifier.fillMaxWidth())
        }
        state.failure?.let { failure -> item {
            Text(stringResource(failureString(failure)), color = MaterialTheme.colorScheme.error)
            for (issue in state.saveIssues.filterNot { state.tab == EditorTab.EDIT && it in state.issues }) {
                Text(issue.message, color = MaterialTheme.colorScheme.error)
            }
            if (!state.isNew) TextButton(onClick = onReload, enabled = !state.writing) { Text(stringResource(R.string.editor_reload)) }
        } }
        if (state.conflict?.presentation == EditorConflictPresentation.BANNER) item {
            Text(stringResource(R.string.editor_conflict_help))
            TextButton(onClick = { onConflict(EditorConflictChoice.REVIEW) }, enabled = !state.writing) {
                Text(stringResource(R.string.editor_review_conflict))
            }
        }
        if (state.historyMaintenanceFailed) item { Text(stringResource(R.string.editor_history_warning)) }
        if (state.provenanceMaintenanceFailed) item { Text(stringResource(R.string.editor_provenance_warning)) }
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(EditorTab.entries) { tab ->
                    FilterChip(selected = state.tab == tab, onClick = { onTab(tab) },
                        label = { Text(stringResource(tabString(tab))) })
                }
            }
        }
        when (state.tab) {
            EditorTab.EDIT -> {
                item {
                    if (state.source == null) Text(stringResource(R.string.editor_source_unavailable))
                    else EditorSourceField(state.source, state.quoteSelection, state.canEdit, onEdit, onClearQuote)
                    if (state.validating) Text(stringResource(R.string.editor_validating))
                }
                items(state.issues) { issue ->
                    Text(issue.message, color = MaterialTheme.colorScheme.error)
                    issue.location?.let { Text(it.toString(), style = MaterialTheme.typography.bodySmall) }
                }
            }
            EditorTab.PREVIEW -> item {
                Text(stringResource(R.string.editor_preview_help))
                if (state.validating) Text(stringResource(R.string.editor_validating))
                else if (state.previewAvailable) SelectionContainer { Text(state.preview) }
                else Text(stringResource(R.string.editor_preview_invalid))
            }
            EditorTab.FIELDS -> {
                if (state.fields.isEmpty()) item { Text(stringResource(R.string.editor_no_fields)) }
                items(state.fields) { field ->
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(field.label, style = MaterialTheme.typography.titleMedium)
                            Text(field.name + " · " + field.kind.rawValue)
                            if (field.isImplicit) Text(stringResource(R.string.editor_implicit))
                            field.description?.let { Text(it) }
                            Text(stringResource(R.string.editor_field_default, field.defaultValue))
                            if (field.options.isNotEmpty()) Text(field.options.joinToString("\n") { it.label + " · " + it.value })
                            Text(stringResource(if (field.optional) R.string.editor_optional else R.string.editor_required))
                            Text(stringResource(if (field.remember) R.string.editor_remembered else R.string.editor_not_remembered))
                        }
                    }
                }
            }
            EditorTab.HISTORY -> {
                item {
                    TextButton(onClick = onHistory, enabled = !state.writing && !state.history.loading && !state.isNew) {
                        Text(stringResource(R.string.editor_refresh_history))
                    }
                    if (state.history.loading) CircularProgressIndicator()
                    if (state.history.failure != null) Text(stringResource(R.string.editor_history_failed))
                    if (!state.history.loading && state.history.failure == null && !state.isNew) {
                        Text(stringResource(R.string.editor_current_revision), style = MaterialTheme.typography.titleMedium)
                        ProvenanceAttribution(state.history.currentProvenance)
                    }
                    if (!state.history.loading && state.history.revisions.isEmpty()) Text(stringResource(R.string.editor_no_history))
                }
                items(state.history.revisions, key = { it.revision.filename }) { entry ->
                    OutlinedCard(onClick = { onRevision(entry) }, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp)) {
                            Text(entry.revision.timestamp.toString())
                            Text(stringResource(R.string.editor_revision_size, entry.byteCount))
                            Text(stringResource(if (entry.canRestore) R.string.editor_revision_valid else R.string.editor_revision_forensic))
                            ProvenanceAttribution(entry.provenance)
                        }
                    }
                }
                state.history.selectedRevision?.let { selected -> item {
                    Text(stringResource(R.string.editor_revision_source), style = MaterialTheme.typography.titleMedium)
                    ProvenanceAttribution(selected.provenance)
                    if (selected.source == null) Text(stringResource(R.string.editor_source_unavailable))
                    else SelectionContainer { Text(selected.source) }
                    TextButton(onClick = { onRestore(selected) }, enabled = selected.canRestore && state.canCommand) {
                        Text(stringResource(R.string.editor_restore))
                    }
                } }
            }
        }
        if (!state.isNew) item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { destination = state.relativePath.orEmpty().substringAfterLast('/'); dialog = FileDialog.RENAME },
                    enabled = state.canCommand) { Text(stringResource(R.string.editor_rename)) }
                TextButton(onClick = { destination = state.relativePath.orEmpty().substringBeforeLast('/', ""); dialog = FileDialog.MOVE },
                    enabled = state.canCommand) { Text(stringResource(R.string.editor_move)) }
                TextButton(onClick = { dialog = FileDialog.DELETE }, enabled = state.canCommand) { Text(stringResource(R.string.editor_delete)) }
            }
            TextButton(onClick = onReload, enabled = !state.writing) { Text(stringResource(R.string.editor_reload)) }
        }
        item { Spacer(Modifier.height(12.dp)) }
    }
    dialog?.let { action ->
        AlertDialog(onDismissRequest = { dialog = null }, title = { Text(stringResource(when (action) {
            FileDialog.RENAME -> R.string.editor_rename
            FileDialog.MOVE -> R.string.editor_move
            FileDialog.DELETE -> R.string.editor_delete
        })) }, text = {
            if (action == FileDialog.DELETE) Text(stringResource(R.string.editor_delete_confirm))
            else OutlinedTextField(value = destination, onValueChange = { destination = it }, singleLine = true,
                label = { Text(stringResource(if (action == FileDialog.RENAME) R.string.editor_filename else R.string.editor_folder)) })
        }, confirmButton = {
            TextButton(onClick = {
                dialog = null
                when (action) {
                    FileDialog.RENAME -> onRename(destination)
                    FileDialog.MOVE -> onMove(destination)
                    FileDialog.DELETE -> onDelete()
                }
            }, enabled = state.canCommand) { Text(stringResource(R.string.editor_confirm)) }
        }, dismissButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.editor_cancel)) } })
    }
    EditorDecisionDialogs(state, onDecision, onConflict)
}

/** The assistant uses the editor's existing save/decision contract while its route is visible. */
@Composable
internal fun EditorDecisionDialogs(state: EditorUiState,
    onDecision: (Long, EditorDecision) -> Unit, onConflict: (EditorConflictChoice) -> Unit) {
    val conflict = state.conflict
    if (conflict?.presentation == EditorConflictPresentation.DIALOG) {
        AlertDialog(onDismissRequest = { if (!state.writing) onConflict(EditorConflictChoice.CANCEL) },
            title = { Text(stringResource(if (conflict.deleted) R.string.editor_deleted else R.string.editor_changed)) },
            text = { Text(stringResource(R.string.editor_conflict_help)) }, confirmButton = {
                TextButton(onClick = { onConflict(EditorConflictChoice.KEEP_MINE) },
                    enabled = !state.writing && !conflict.loading && conflict.failure == null && conflict.readOnlyReason == null) {
                    Text(stringResource(R.string.editor_keep_mine))
                }
            }, dismissButton = {
                Row {
                    TextButton(onClick = { onConflict(if (conflict.deleted) EditorConflictChoice.DISCARD else EditorConflictChoice.TAKE_THEIRS) },
                        enabled = !state.writing && !conflict.loading) {
                        Text(stringResource(if (conflict.deleted) R.string.editor_discard else R.string.editor_take_theirs))
                    }
                    TextButton(onClick = { onConflict(EditorConflictChoice.CANCEL) }, enabled = !state.writing) {
                        Text(stringResource(R.string.editor_cancel))
                    }
                }
            })
    } else state.pendingDecision?.let { decision ->
        AlertDialog(onDismissRequest = { onDecision(decision.id, EditorDecision.CANCEL) },
            title = { Text(stringResource(R.string.editor_unsaved)) }, text = { Text(stringResource(R.string.editor_guard_help)) },
            confirmButton = { TextButton(onClick = { onDecision(decision.id, EditorDecision.SAVE) }, enabled = state.canSave) {
                Text(stringResource(R.string.editor_save))
            } }, dismissButton = {
                Row {
                    TextButton(onClick = { onDecision(decision.id, EditorDecision.DISCARD) }, enabled = !state.writing) { Text(stringResource(R.string.editor_discard)) }
                    TextButton(onClick = { onDecision(decision.id, EditorDecision.CANCEL) }, enabled = !state.writing) { Text(stringResource(R.string.editor_cancel)) }
                }
            })
    }
}

@Composable
private fun ProvenanceAttribution(provenance: PromptProvenance?) {
    if (provenance == null) {
        Text(stringResource(R.string.editor_provenance_unrecorded))
        return
    }
    Text(stringResource(R.string.editor_provenance_llm, provenance.providerHost, provenance.model))
    Text(provenance.timestamp.toString(), style = MaterialTheme.typography.bodySmall)
    provenance.usage?.let { usage ->
        Text(stringResource(R.string.editor_provenance_usage, usage.inputTokens, usage.outputTokens),
            style = MaterialTheme.typography.bodySmall)
    }
}

private fun tabString(tab: EditorTab): Int = when (tab) {
    EditorTab.EDIT -> R.string.editor_edit
    EditorTab.PREVIEW -> R.string.editor_preview
    EditorTab.FIELDS -> R.string.editor_fields
    EditorTab.HISTORY -> R.string.editor_history
}

private fun failureString(failure: EditorFailure): Int = when (failure) {
    EditorFailure.DATA -> R.string.editor_data_failed
    EditorFailure.INVALID -> R.string.editor_invalid
    EditorFailure.READ_ONLY -> R.string.editor_read_only_failed
    EditorFailure.OCCUPIED -> R.string.editor_occupied
    EditorFailure.INVALID_PATH -> R.string.editor_invalid_path
    EditorFailure.IDENTITY -> R.string.editor_identity_failed
    EditorFailure.RECOVERY -> R.string.editor_recovery
    EditorFailure.UNVERIFIED -> R.string.editor_unverified
    EditorFailure.FORENSIC -> R.string.editor_revision_forensic
}
