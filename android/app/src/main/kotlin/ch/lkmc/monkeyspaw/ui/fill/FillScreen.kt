package ch.lkmc.monkeyspaw.ui.fill

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.PromptRenderError
import ch.lkmc.monkeyspaw.core.services.FillPreview
import ch.lkmc.monkeyspaw.core.ports.DeliveryMode

@Composable
internal fun FillScreen(
    state: FillUiState,
    onValue: (String, String) -> Unit,
    onCopy: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    onInsert: (() -> Unit)? = null,
    onCapturedField: (String?) -> Unit = {},
    onFillInApp: (() -> Unit)? = null,
) {
    LazyColumn(modifier.fillMaxSize().imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text(state.title.ifEmpty { stringResource(R.string.fill_title) }, style = MaterialTheme.typography.headlineMedium)
            state.description?.let { Text(it) }
        }
        if (state.phase == FillPhase.LOADING || state.phase == FillPhase.DELIVERING) item {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(stringResource(if (state.phase == FillPhase.LOADING) R.string.fill_loading else R.string.fill_delivering))
        }
        state.failure?.let { failure -> item {
            Text(stringResource(when (failure) {
                FillFailure.LOAD -> R.string.fill_load_failed
                FillFailure.SNAPSHOT -> R.string.fill_snapshot_failed
                FillFailure.CLIPBOARD -> R.string.fill_clipboard_failed
                FillFailure.DELIVERY -> R.string.fill_delivery_failed
            }), color = MaterialTheme.colorScheme.error)
            if (state.phase == FillPhase.FAILED) TextButton(onClick = onRetry) { Text(stringResource(R.string.retry)) }
        } }
        for (warning in state.warnings) item { Text(stringResource(when (warning) {
            FillWarning.REMEMBERED_VALUES_UNAVAILABLE -> R.string.fill_values_unavailable
            FillWarning.REMEMBERED_VALUES_NOT_SAVED -> R.string.fill_values_not_saved
            FillWarning.USAGE_NOT_SAVED -> R.string.fill_usage_not_saved
        })) }
        if (state.isReadOnly) item { Text(stringResource(R.string.fill_read_only), color = MaterialTheme.colorScheme.error) }
        for (issue in state.issues) item { Text(issue.message, color = MaterialTheme.colorScheme.error) }
        state.capturedText?.let { capture -> item {
            var expanded by remember { mutableStateOf(false) }
            Column {
                Text(stringResource(R.string.fill_captured_field), style = MaterialTheme.typography.labelLarge)
                Box {
                    OutlinedButton(onClick = { expanded = true }, enabled = state.phase == FillPhase.EDITING) {
                        Text(capture.candidates.firstOrNull { it.name == capture.selectedField }?.label
                            ?: stringResource(R.string.fill_ignore_capture))
                    }
                    DropdownMenu(expanded = expanded && state.phase == FillPhase.EDITING,
                        onDismissRequest = { expanded = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.fill_ignore_capture)) },
                            onClick = { expanded = false; onCapturedField(null) })
                        for (field in capture.candidates) DropdownMenuItem(text = { Text(field.label) },
                            onClick = { expanded = false; onCapturedField(field.name) })
                    }
                }
            }
        } }
        items(state.fields, key = { it.field.name }) { field ->
            val error = (state.preview as? FillPreview.Blocked)?.error
            val invalid = (error is PromptRenderError.MissingRequiredValue && error.field == field.field.name) ||
                (error is PromptRenderError.InvalidChoiceValue && error.field == field.field.name)
            FieldControl(field, input = state.input, enabled = state.phase == FillPhase.EDITING, invalid = invalid,
                onValue = { onValue(field.field.name, it) })
        }
        if (state.phase == FillPhase.EDITING && !state.builtinsResolved && state.failure == null) item {
            Text(stringResource(R.string.fill_snapshot_pending))
        }
        state.preview?.let { preview -> item {
            Text(stringResource(R.string.fill_preview), style = MaterialTheme.typography.titleMedium)
            when (preview) {
                is FillPreview.Rendered -> Text(preview.text)
                is FillPreview.Blocked -> Text(stringResource(when (preview.error) {
                    PromptRenderError.InvalidPrompt -> R.string.fill_invalid_prompt
                    is PromptRenderError.UnsupportedFormat -> R.string.fill_read_only
                    is PromptRenderError.MissingRequiredValue -> R.string.fill_required_value
                    is PromptRenderError.InvalidChoiceValue -> R.string.fill_invalid_choice
                    is PromptRenderError.MissingBuiltin -> R.string.fill_snapshot_pending
                }), color = MaterialTheme.colorScheme.error)
            }
        } }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.phase != FillPhase.DELIVERED) {
                    if (state.deliveryMode != DeliveryMode.COPY) Button(onClick = { onInsert?.invoke() },
                        enabled = state.copyEnabled && onInsert != null) {
                        Text(stringResource(R.string.fill_insert))
                    }
                    Button(onClick = onCopy, enabled = state.copyEnabled) { Text(stringResource(R.string.fill_copy)) }
                }
                TextButton(onClick = onCancel, enabled = state.cancelEnabled) {
                    Text(stringResource(if (state.phase == FillPhase.DELIVERED) R.string.fill_done else R.string.fill_cancel))
                }
            }
            if (state.input == FillInput.INLINE && state.phase == FillPhase.EDITING && onFillInApp != null) {
                TextButton(onClick = onFillInApp, enabled = state.builtinsResolved) {
                    Text(stringResource(R.string.fill_in_app))
                }
            }
        }
    }
}

@Composable
private fun FieldControl(state: FillFieldState, input: FillInput, enabled: Boolean, invalid: Boolean, onValue: (String) -> Unit) {
    val field = state.field
    val label = stringResource(if (field.optional) R.string.fill_optional_label else R.string.fill_required_label, field.label)
    if (field.kind == FieldKind.CHOICE) {
        var expanded by remember { mutableStateOf(false) }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label, style = MaterialTheme.typography.labelLarge)
            Box {
                OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                    Text(field.options.firstOrNull { it.value == state.value }?.label ?: state.value.ifEmpty {
                        stringResource(R.string.fill_choose)
                    })
                }
                DropdownMenu(expanded = expanded && enabled, onDismissRequest = { expanded = false }) {
                    if (field.optional) DropdownMenuItem(text = { Text(stringResource(R.string.fill_clear_choice)) },
                        onClick = { expanded = false; onValue("") })
                    for (option in field.options) DropdownMenuItem(text = { Text(option.label) },
                        onClick = { expanded = false; onValue(option.value) })
                }
            }
            if (invalid) Text(stringResource(R.string.fill_invalid_choice), color = MaterialTheme.colorScheme.error)
            field.description?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        return
    }
    if (input == FillInput.INLINE) {
        Column {
            Text(label, style = MaterialTheme.typography.labelLarge)
            Text(state.value.ifEmpty { stringResource(if (field.optional) R.string.fill_clear_choice else R.string.fill_required_value) })
            field.description?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        return
    }
    OutlinedTextField(value = state.value, onValueChange = onValue, enabled = enabled, isError = invalid,
        singleLine = field.kind == FieldKind.TEXT, minLines = if (field.kind == FieldKind.MULTILINE) 3 else 1,
        label = { Text(label) }, supportingText = field.description?.let { description -> { Text(description) } },
        modifier = Modifier.fillMaxWidth())
}
