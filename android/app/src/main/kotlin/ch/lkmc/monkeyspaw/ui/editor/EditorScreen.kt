package ch.lkmc.monkeyspaw.ui.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DriveFileMove
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.services.SourceReadOnlyReason
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

private enum class FileDialog { RENAME, MOVE, DELETE, PRIVATE_COPY }

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
    onMove: (EditorMoveTarget) -> Unit,
    onPrivateCopy: (String) -> Unit,
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
    // Callers still pass a label; the stable app bar owns the back affordance now.
    @Suppress("UNUSED_PARAMETER") backLabel: Int = R.string.editor_back,
) {
    BackHandler(onBack = onBack)
    var dialog by remember(state.relativePath) { mutableStateOf<FileDialog?>(null) }
    var destination by remember(state.relativePath) { mutableStateOf("") }
    var moveDestination by remember(state.relativePath) { mutableStateOf(EditorDestination()) }
    var menuOpen by remember { mutableStateOf(false) }
    val privateCopyName = stringResource(R.string.editor_private_copy_filename,
        state.relativePath.orEmpty().substringAfterLast('/').removeSuffix(".md"))
    val title = state.title.ifEmpty {
        stringResource(if (state.isNew) R.string.editor_new else R.string.editor_title)
    }

    PawScreen(title, modifier, onBack = onBack, actions = {
        TextButton(onClick = onSave, enabled = state.canSave) { Text(stringResource(R.string.editor_save)) }
        if (!state.isNew || onReview != null || onImprove != null) Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Rounded.MoreVert, stringResource(R.string.design_more_options))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                onReview?.let { review ->
                    DropdownMenuItem(text = { Text(stringResource(R.string.assistant_review_title)) },
                        leadingIcon = { Icon(Icons.Rounded.RateReview, null) },
                        onClick = { menuOpen = false; review() })
                }
                onImprove?.let { improve ->
                    DropdownMenuItem(text = { Text(stringResource(R.string.assistant_improve_title)) },
                        leadingIcon = { Icon(Icons.Rounded.AutoAwesome, null) },
                        onClick = { menuOpen = false; improve() })
                }
                if (!state.isNew) {
                    if (onReview != null || onImprove != null) HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_rename)) },
                        leadingIcon = { Icon(Icons.Rounded.Edit, null) }, enabled = state.canCommand,
                        onClick = { menuOpen = false
                            destination = state.relativePath.orEmpty().substringAfterLast('/')
                            dialog = FileDialog.RENAME })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_move)) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Rounded.DriveFileMove, null) }, enabled = state.canCommand,
                        onClick = { menuOpen = false; destination = ""; moveDestination = EditorDestination()
                            dialog = FileDialog.MOVE })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_private_copy)) },
                        leadingIcon = { Icon(Icons.Rounded.FileCopy, null) }, enabled = state.canPrivateCopy,
                        onClick = { menuOpen = false; destination = privateCopyName
                            dialog = FileDialog.PRIVATE_COPY })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_reload)) },
                        leadingIcon = { Icon(Icons.Rounded.Refresh, null) }, enabled = !state.writing,
                        onClick = { menuOpen = false; onReload() })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_delete),
                        color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Rounded.Delete, null, tint = MaterialTheme.colorScheme.error) },
                        enabled = state.canCommand, onClick = { menuOpen = false; dialog = FileDialog.DELETE })
                }
            }
        }
    }) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PawLayout.contentPadding,
            verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    state.relativePath?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    state.group?.let {
                        Text(stringResource(R.string.library_group_role, it.name, it.role.wireValue),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (state.dirty) {
                        Text(stringResource(R.string.editor_unsaved), style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.tertiary)
                    }
                }
            }
            if (state.writing || state.status == EditorStatus.LOADING) {
                item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            }
            state.readOnlyReason?.let { reason -> item {
                PawMessage(stringResource(when (reason) {
                    SourceReadOnlyReason.GROUP_VIEWER -> R.string.editor_group_viewer
                    SourceReadOnlyReason.GROUP_UNAVAILABLE -> R.string.editor_group_unavailable
                    else -> R.string.editor_read_only
                }), tone = if (reason == SourceReadOnlyReason.GROUP_UNAVAILABLE) PawMessageTone.WARNING
                    else PawMessageTone.INFO)
            } }
            if (state.isNew) item {
                OutlinedTextField(value = state.relativePath.orEmpty(), onValueChange = onNewPath,
                    label = { Text(stringResource(R.string.editor_path)) }, singleLine = true,
                    enabled = !state.writing, modifier = Modifier.fillMaxWidth())
            }
            state.failure?.let { failure -> item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    PawMessage(stringResource(failureString(failure)), tone = PawMessageTone.ERROR)
                    for (issue in state.saveIssues.filterNot { state.tab == EditorTab.EDIT && it in state.issues }) {
                        Text(issue.message, color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall)
                    }
                    if (!state.isNew) TextButton(onClick = onReload, enabled = !state.writing,
                        modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.editor_reload))
                    }
                }
            } }
            if (state.conflict?.presentation == EditorConflictPresentation.BANNER) item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    PawMessage(stringResource(R.string.editor_conflict_help), tone = PawMessageTone.WARNING)
                    TextButton(onClick = { onConflict(EditorConflictChoice.REVIEW) }, enabled = !state.writing,
                        modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.editor_review_conflict))
                    }
                }
            }
            if (state.historyMaintenanceFailed) item {
                PawMessage(stringResource(R.string.editor_history_warning), tone = PawMessageTone.WARNING)
            }
            if (state.provenanceMaintenanceFailed) item {
                PawMessage(stringResource(R.string.editor_provenance_warning), tone = PawMessageTone.WARNING)
            }
            item {
                SecondaryScrollableTabRow(selectedTabIndex = state.tab.ordinal, modifier = Modifier.fillMaxWidth(),
                    edgePadding = PawSpacing.large) {
                    for (tab in EditorTab.entries) {
                        Tab(selected = state.tab == tab, onClick = { onTab(tab) },
                            text = { Text(stringResource(tabString(tab))) })
                    }
                }
            }
            when (state.tab) {
                EditorTab.EDIT -> {
                    item {
                        when {
                            state.status == EditorStatus.LOADING -> PawLoading(stringResource(R.string.editor_loading))
                            state.source == null -> PawMessage(stringResource(R.string.editor_source_unavailable))
                            else -> Column {
                                EditorSourceField(state.source, state.quoteSelection, state.canEdit, onEdit, onClearQuote)
                                if (state.validating) Text(stringResource(R.string.editor_validating),
                                    Modifier.padding(top = PawSpacing.small),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    items(state.issues) { issue ->
                        Column {
                            Text(issue.message, color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodyMedium)
                            issue.location?.let {
                                Text(it.toString(), style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
                EditorTab.PREVIEW -> item {
                    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                        Text(stringResource(R.string.editor_preview_help), style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        when {
                            state.validating -> PawLoading(stringResource(R.string.editor_validating))
                            state.previewAvailable -> Surface(shape = MaterialTheme.shapes.medium,
                                color = MaterialTheme.colorScheme.surfaceContainerLow,
                                modifier = Modifier.fillMaxWidth()) {
                                SelectionContainer {
                                    Text(state.preview, Modifier.padding(PawSpacing.large),
                                        style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
                                }
                            }
                            else -> PawMessage(stringResource(R.string.editor_preview_invalid))
                        }
                    }
                }
                EditorTab.FIELDS -> {
                    if (state.fields.isEmpty()) item {
                        PawEmptyState(stringResource(R.string.editor_no_fields),
                            stringResource(R.string.editor_no_fields_body), Icons.Rounded.TextFields)
                    }
                    // Invalid headers retain duplicate declarations for inspection.
                    items(state.fields) { field ->
                        Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                            color = MaterialTheme.colorScheme.surfaceContainerLow) {
                            Column(Modifier.padding(PawSpacing.large),
                                verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                                Text(field.label, style = MaterialTheme.typography.titleMedium)
                                Text(field.name + " · " + field.kind.rawValue,
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.primary)
                                if (field.isImplicit) Text(stringResource(R.string.editor_implicit),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.tertiary)
                                field.description?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                                Text(stringResource(R.string.editor_field_default, field.defaultValue),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                                if (field.options.isNotEmpty()) {
                                    Text(field.options.joinToString("\n") { it.label + " · " + it.value },
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Text(stringResource(if (field.optional) R.string.editor_optional
                                    else R.string.editor_required) + " · " +
                                    stringResource(if (field.remember) R.string.editor_remembered
                                        else R.string.editor_not_remembered),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
                EditorTab.HISTORY -> {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                            OutlinedButton(onClick = onHistory,
                                enabled = !state.writing && !state.history.loading && !state.isNew) {
                                Icon(Icons.Rounded.Refresh, null, Modifier.size(18.dp))
                                Spacer(Modifier.width(PawSpacing.small))
                                Text(stringResource(R.string.editor_refresh_history))
                            }
                            if (state.history.loading) PawLoading(stringResource(R.string.editor_history_loading))
                            if (state.history.failure != null) {
                                PawMessage(stringResource(R.string.editor_history_failed), tone = PawMessageTone.ERROR)
                            }
                            if (!state.history.loading && state.history.failure == null && !state.isNew) {
                                PawSectionHeading(stringResource(R.string.editor_current_revision))
                                ProvenanceAttribution(state.history.currentProvenance)
                            }
                            if (!state.history.loading && state.history.revisions.isEmpty()) {
                                PawEmptyState(stringResource(R.string.editor_no_history),
                                    stringResource(R.string.editor_no_history_body), Icons.Rounded.History)
                            }
                        }
                    }
                    items(state.history.revisions, key = { it.revision.filename }) { entry ->
                        OutlinedCard(onClick = { onRevision(entry) }, modifier = Modifier.fillMaxWidth()) {
                            ListItem(headlineContent = { Text(entry.revision.timestamp.toString()) },
                                supportingContent = {
                                    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                                        Text(stringResource(R.string.editor_revision_size, entry.byteCount))
                                        Text(stringResource(if (entry.canRestore) R.string.editor_revision_valid
                                            else R.string.editor_revision_forensic))
                                        ProvenanceAttribution(entry.provenance)
                                    }
                                },
                                trailingContent = {
                                    if (entry.revision == state.history.selected) {
                                        Icon(Icons.Rounded.CheckCircle, null, tint = MaterialTheme.colorScheme.primary)
                                    }
                                },
                                colors = ListItemDefaults.colors(containerColor = Color.Transparent))
                        }
                    }
                    state.history.selectedRevision?.let { selected -> item {
                        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                            PawSectionHeading(stringResource(R.string.editor_revision_source))
                            ProvenanceAttribution(selected.provenance)
                            if (selected.source == null) {
                                PawMessage(stringResource(R.string.editor_source_unavailable))
                            } else Surface(shape = MaterialTheme.shapes.medium,
                                color = MaterialTheme.colorScheme.surfaceContainerLow,
                                modifier = Modifier.fillMaxWidth()) {
                                SelectionContainer {
                                    Text(selected.source, Modifier.padding(PawSpacing.large),
                                        style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
                                }
                            }
                            Button(onClick = { onRestore(selected) }, enabled = selected.canRestore && state.canCommand) {
                                Text(stringResource(R.string.editor_restore))
                            }
                        }
                    } }
                }
            }
        }
    }

    dialog?.let { action ->
        AlertDialog(onDismissRequest = { dialog = null }, title = { Text(stringResource(when (action) {
            FileDialog.RENAME -> R.string.editor_rename
            FileDialog.MOVE -> R.string.editor_move
            FileDialog.DELETE -> R.string.editor_delete
            FileDialog.PRIVATE_COPY -> R.string.editor_private_copy
        })) }, text = {
            when (action) {
                FileDialog.DELETE -> Text(stringResource(R.string.editor_delete_confirm))
                FileDialog.MOVE -> Column(Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                    Text(stringResource(R.string.editor_destination), style = MaterialTheme.typography.titleSmall)
                    Column(Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState()).selectableGroup()) {
                        for (choice in state.destinations) {
                            val selected = moveDestination.group?.id == choice.group?.id
                            Row(Modifier.fillMaxWidth().selectable(selected = selected, enabled = choice.canWrite,
                                role = Role.RadioButton, onClick = { moveDestination = choice })
                                .heightIn(min = PawLayout.touchTarget),
                                verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = selected, onClick = null, enabled = choice.canWrite)
                                Text(if (choice.group == null) stringResource(R.string.editor_personal)
                                    else stringResource(R.string.library_group_role, choice.group.name, choice.group.role.wireValue))
                            }
                        }
                    }
                    OutlinedTextField(value = destination, onValueChange = { destination = it }, singleLine = true,
                        label = { Text(stringResource(R.string.editor_subfolder)) }, modifier = Modifier.fillMaxWidth())
                    Text(stringResource(R.string.editor_move_scope_help), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                FileDialog.PRIVATE_COPY -> Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                    Text(stringResource(R.string.editor_private_copy_help))
                    OutlinedTextField(value = destination, onValueChange = { destination = it }, singleLine = true,
                        label = { Text(stringResource(R.string.editor_path)) }, modifier = Modifier.fillMaxWidth())
                }
                FileDialog.RENAME -> OutlinedTextField(value = destination,
                    onValueChange = { destination = it }, singleLine = true,
                    label = { Text(stringResource(R.string.editor_filename)) }, modifier = Modifier.fillMaxWidth())
            }
        }, confirmButton = {
            TextButton(onClick = {
                dialog = null
                when (action) {
                    FileDialog.RENAME -> onRename(destination)
                    FileDialog.MOVE -> onMove(EditorMoveTarget(moveDestination.group?.id, destination))
                    FileDialog.DELETE -> onDelete()
                    FileDialog.PRIVATE_COPY -> onPrivateCopy(destination)
                }
            }, enabled = if (action == FileDialog.PRIVATE_COPY) state.canPrivateCopy else state.canCommand &&
                (action != FileDialog.MOVE || state.destinations.any { it.group?.id == moveDestination.group?.id && it.canWrite }),
                colors = if (action == FileDialog.DELETE)
                    ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                    else ButtonDefaults.textButtonColors()) {
                Text(stringResource(if (action == FileDialog.DELETE) R.string.editor_delete else R.string.editor_confirm))
            }
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
            text = { Text(stringResource(R.string.editor_conflict_help), Modifier.verticalScroll(rememberScrollState())) },
            // Let the dialog wrap compact choices; three full-width buttons clip in short windows.
            confirmButton = {
                Button(onClick = { onConflict(EditorConflictChoice.KEEP_MINE) },
                    enabled = state.canEdit && !state.writing && !conflict.loading && conflict.failure == null && conflict.readOnlyReason == null) {
                    Text(stringResource(R.string.editor_keep_mine))
                }
            }, dismissButton = {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    OutlinedButton(onClick = { onConflict(if (conflict.deleted) EditorConflictChoice.DISCARD else EditorConflictChoice.TAKE_THEIRS) },
                        enabled = !state.writing && !conflict.loading,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(stringResource(if (conflict.deleted) R.string.editor_discard else R.string.editor_take_theirs))
                    }
                    TextButton(onClick = { onConflict(EditorConflictChoice.CANCEL) }, enabled = !state.writing) {
                        Text(stringResource(R.string.editor_cancel))
                    }
                }
            })
    } else state.pendingDecision?.let { decision ->
        AlertDialog(onDismissRequest = { onDecision(decision.id, EditorDecision.CANCEL) },
            title = { Text(stringResource(R.string.editor_unsaved)) },
            text = { Text(stringResource(R.string.editor_guard_help), Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = {
                Button(onClick = { onDecision(decision.id, EditorDecision.SAVE) }, enabled = state.canSave) {
                    Text(stringResource(R.string.editor_save))
                }
            }, dismissButton = {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    OutlinedButton(onClick = { onDecision(decision.id, EditorDecision.DISCARD) }, enabled = !state.writing,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(stringResource(R.string.editor_discard))
                    }
                    TextButton(onClick = { onDecision(decision.id, EditorDecision.CANCEL) }, enabled = !state.writing) {
                        Text(stringResource(R.string.editor_cancel))
                    }
                }
            })
    }
}

@Composable
private fun ProvenanceAttribution(provenance: PromptProvenance?) {
    if (provenance == null) {
        Text(stringResource(R.string.editor_provenance_unrecorded), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    Text(stringResource(R.string.editor_provenance_llm, provenance.providerHost, provenance.model),
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(provenance.timestamp.toString(), style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
    provenance.usage?.let { usage ->
        Text(stringResource(R.string.editor_provenance_usage, usage.inputTokens, usage.outputTokens),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
    EditorFailure.ACCESS_CHANGED -> R.string.editor_access_changed
    EditorFailure.OCCUPIED -> R.string.editor_occupied
    EditorFailure.INVALID_PATH -> R.string.editor_invalid_path
    EditorFailure.IDENTITY -> R.string.editor_identity_failed
    EditorFailure.RECOVERY -> R.string.editor_recovery
    EditorFailure.UNVERIFIED -> R.string.editor_unverified
    EditorFailure.FORENSIC -> R.string.editor_revision_forensic
}
