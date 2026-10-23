package ch.lkmc.monkeyspaw.ui.editor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.PromptFieldSettings
import ch.lkmc.monkeyspaw.core.domain.format.PromptFieldSettingsIssue
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

/** Only Apply leaves the sheet; abandoning this local value never edits the document. */
@Composable
internal fun EditorFieldSettingsDialog(initial: PromptFieldSettings, onDismiss: () -> Unit,
    onApply: (PromptFieldSettings) -> Unit) {
    var staged by remember(initial) { mutableStateOf(StagedFieldSettings.of(initial)) }
    val draft = staged.settings
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.field_settings_title, initial.name)) },
        text = {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                Text(stringResource(R.string.field_settings_type), style = MaterialTheme.typography.labelLarge)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    for (kind in FieldKind.entries) FilterChip(selected = draft.kind == kind,
                        onClick = { staged = staged.edit { it.copy(kind = kind) } },
                        label = { Text(stringResource(when (kind) {
                            FieldKind.TEXT -> R.string.field_settings_text
                            FieldKind.MULTILINE -> R.string.field_settings_multiline
                            FieldKind.CHOICE -> R.string.field_settings_choice
                        })) })
                }
                OutlinedTextField(draft.label, { staged = staged.edit { s -> s.copy(label = it) } }, singleLine = true,
                    label = { Text(stringResource(R.string.field_settings_label)) }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(draft.description.orEmpty(), { staged = staged.edit { s -> s.copy(description = it.ifEmpty { null }) } },
                    label = { Text(stringResource(R.string.field_settings_description)) }, modifier = Modifier.fillMaxWidth())
                FieldToggle(stringResource(R.string.field_settings_use_default), draft.defaultValue != null) {
                    staged = staged.edit { s -> s.copy(defaultValue = if (it) "" else null) }
                }
                if (draft.defaultValue != null) OutlinedTextField(draft.defaultValue.orEmpty(),
                    { staged = staged.edit { s -> s.copy(defaultValue = it) } }, singleLine = draft.kind != FieldKind.MULTILINE,
                    label = { Text(stringResource(R.string.field_settings_default)) }, modifier = Modifier.fillMaxWidth())
                if (draft.kind == FieldKind.CHOICE) {
                    Text(stringResource(R.string.field_settings_options), style = MaterialTheme.typography.labelLarge)
                    for ((index, row) in staged.rows.withIndex()) {
                        key(row.id) {
                            Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(stringResource(R.string.field_settings_option, index + 1), Modifier.weight(1f))
                                    IconButton(onClick = { staged = staged.removeOption(row.id) }) {
                                        Icon(Icons.Rounded.Close, stringResource(R.string.field_settings_remove_option, index + 1))
                                    }
                                }
                                OutlinedTextField(row.option.label, { label ->
                                    staged = staged.editOption(row.id) { it.copy(label = label) }
                                }, singleLine = true, label = { Text(stringResource(R.string.field_settings_option_label)) },
                                    modifier = Modifier.fillMaxWidth())
                                OutlinedTextField(row.option.value, { value ->
                                    staged = staged.editOption(row.id) { it.copy(value = value) }
                                }, label = { Text(stringResource(R.string.field_settings_option_value)) }, modifier = Modifier.fillMaxWidth())
                            }
                        }
                    }
                    TextButton(onClick = { staged = staged.addOption() }) {
                        Text(stringResource(R.string.field_settings_add_option))
                    }
                }
                FieldToggle(stringResource(R.string.field_settings_optional), draft.optional) { staged = staged.edit { s -> s.copy(optional = it) } }
                FieldToggle(stringResource(R.string.field_settings_remember), draft.remember) { staged = staged.edit { s -> s.copy(remember = it) } }
                draft.validationIssue?.let { issue ->
                    Text(stringResource(when (issue) {
                        PromptFieldSettingsIssue.MISSING_OPTIONS -> R.string.field_settings_missing_options
                        PromptFieldSettingsIssue.INVALID_DEFAULT -> R.string.field_settings_invalid_default
                    }), color = MaterialTheme.colorScheme.error)
                }
                Text(stringResource(R.string.field_settings_draft_hint), style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = {
            TextButton(onClick = { onApply(staged.settings) }, enabled = draft.validationIssue == null) {
                Text(stringResource(R.string.field_settings_apply))
            }
        }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.editor_cancel)) } })
}

@Composable
private fun FieldToggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = PawLayout.touchTarget)
        .toggleable(value = checked, role = Role.Checkbox, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        Checkbox(checked, onCheckedChange = null)
        Text(label)
    }
}
