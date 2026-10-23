package ch.lkmc.monkeyspaw.ui.editor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.PromptEdit
import ch.lkmc.monkeyspaw.ui.components.PawSectionHeading
import ch.lkmc.monkeyspaw.ui.components.PawTextField
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

@Composable
internal fun EditorForm(form: EditorFormState, enabled: Boolean, onEdit: (PromptEdit) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
        PawTextField(form.title, { onEdit(PromptEdit.Title(it)) }, stringResource(R.string.design_prompt_name),
            enabled = enabled, singleLine = true, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next))
        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
            PawSectionHeading(stringResource(R.string.design_prompt_body), stringResource(R.string.design_prompt_body_help))
            PawTextField(form.body, { onEdit(PromptEdit.Body(it)) }, stringResource(R.string.design_prompt_body),
                modifier = Modifier.heightIn(min = PawLayout.bodyEditorHeight), enabled = enabled, minLines = 7,
                placeholder = stringResource(R.string.design_prompt_body_example))
        }
        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
            PawSectionHeading(stringResource(R.string.design_prompt_details))
            PawTextField(form.description, { onEdit(PromptEdit.Description(it)) }, stringResource(R.string.design_description),
                enabled = enabled, supportingText = stringResource(R.string.design_description_help))
            EditorTags(form.tags, enabled) { onEdit(PromptEdit.Tags(it)) }
        }
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Row(Modifier.fillMaxWidth().toggleable(form.isPrivate, enabled = enabled, role = Role.Switch,
                onValueChange = { onEdit(PromptEdit.IsPrivate(it)) }).padding(PawSpacing.large),
                horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Lock, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    Text(stringResource(R.string.design_private_prompt), style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.design_private_prompt_help), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(form.isPrivate, onCheckedChange = null, enabled = enabled)
            }
        }
    }
}

@Composable
private fun EditorTags(tags: List<String>, enabled: Boolean, onTags: (List<String>) -> Unit) {
    var editing by remember(tags) { mutableStateOf<Int?>(null) }
    var input by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
        Text(stringResource(R.string.design_tags), style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
            tags.forEachIndexed { index, tag ->
                InputChip(selected = false, onClick = { input = tag; editing = index }, enabled = enabled,
                    label = { Text(tag) })
            }
            AssistChip(onClick = { input = ""; editing = tags.size }, enabled = enabled,
                label = { Text(stringResource(R.string.design_add_tag)) },
                leadingIcon = { Icon(Icons.Rounded.Add, null, Modifier.size(PawSpacing.large)) })
        }
    }
    editing?.let { index ->
        AlertDialog(onDismissRequest = { editing = null },
            title = { Text(stringResource(if (index < tags.size) R.string.design_edit_tag else R.string.design_add_tag)) },
            text = { PawTextField(input, { input = it }, stringResource(R.string.design_tag_name), singleLine = true) },
            confirmButton = { TextButton(onClick = {
                val updated = tags.toMutableList()
                if (index < updated.size) updated[index] = input.trim() else updated.add(input.trim())
                editing = null
                onTags(updated)
            }, enabled = enabled && input.isNotBlank()) { Text(stringResource(R.string.editor_confirm)) } },
            dismissButton = {
                Row {
                    if (index < tags.size) TextButton(onClick = {
                        editing = null
                        onTags(tags.filterIndexed { position, _ -> position != index })
                    }, enabled = enabled, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(stringResource(R.string.design_remove_tag))
                    }
                    TextButton(onClick = { editing = null }) { Text(stringResource(R.string.editor_cancel)) }
                }
            })
    }
}
