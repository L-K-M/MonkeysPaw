package ch.lkmc.monkeyspaw.ui.fill

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.PromptRenderError
import ch.lkmc.monkeyspaw.core.services.FillPreview
import ch.lkmc.monkeyspaw.core.ports.DeliveryMode
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

@OptIn(ExperimentalMaterial3Api::class)
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
    notice: String? = null,
) {
    val content = modifier.fillMaxSize().let { if (state.input == FillInput.INLINE) it else it.imePadding() }
    val title = state.title.ifEmpty { stringResource(R.string.fill_title) }
    val density = if (state.input == FillInput.INLINE) PawContentDensity.COMPACT else PawContentDensity.COMFORTABLE
    Column(content) {
        if (state.input != FillInput.INLINE) TopAppBar(title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onClick = onCancel, enabled = state.cancelEnabled) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.design_back))
            } }, windowInsets = WindowInsets(0, 0, 0, 0),
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface))
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = PawLayout.readingWidth).fillMaxSize()) {
                LazyColumn(Modifier.weight(1f), contentPadding = if (state.input == FillInput.INLINE)
                    PaddingValues(horizontal = PawSpacing.medium, vertical = PawSpacing.small) else PaddingValues(PawSpacing.large),
                    verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                    state.description?.let { description -> item {
                        Text(description, style = if (state.input == FillInput.INLINE) MaterialTheme.typography.bodySmall
                            else MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = if (state.input == FillInput.INLINE) 2 else Int.MAX_VALUE, overflow = TextOverflow.Ellipsis)
                    } }
                    notice?.let { item { PawMessage(it, tone = PawMessageTone.WARNING) } }
                    if (state.phase == FillPhase.LOADING || state.phase == FillPhase.DELIVERING) item {
                        PawLoading(stringResource(if (state.phase == FillPhase.LOADING) R.string.fill_loading else R.string.fill_delivering),
                            density = density)
                    }
                    state.failure?.let { failure -> item {
                        PawMessage(stringResource(when (failure) {
                            FillFailure.LOAD -> R.string.fill_load_failed
                            FillFailure.SNAPSHOT -> R.string.fill_snapshot_failed
                            FillFailure.CLIPBOARD -> R.string.fill_clipboard_failed
                            FillFailure.DELIVERY -> R.string.fill_delivery_failed
                        }), tone = PawMessageTone.ERROR, actionLabel = stringResource(R.string.retry).takeIf { state.phase == FillPhase.FAILED },
                            onAction = onRetry)
                    } }
                    for (warning in state.warnings) item { PawMessage(stringResource(when (warning) {
                        FillWarning.REMEMBERED_VALUES_UNAVAILABLE -> R.string.fill_values_unavailable
                        FillWarning.REMEMBERED_VALUES_NOT_SAVED -> R.string.fill_values_not_saved
                        FillWarning.USAGE_NOT_SAVED -> R.string.fill_usage_not_saved
                    }), tone = PawMessageTone.WARNING) }
                    if (state.isReadOnly) item { PawMessage(stringResource(R.string.fill_read_only), tone = PawMessageTone.ERROR) }
                    for (issue in state.issues) item { PawMessage(issue.message, tone = PawMessageTone.ERROR) }
                    state.capturedText?.let { capture -> item {
                        var expanded by remember { mutableStateOf(false) }
                        ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { if (state.phase == FillPhase.EDITING) expanded = it }) {
                            OutlinedTextField(value = capture.candidates.firstOrNull { it.name == capture.selectedField }?.label
                                ?: stringResource(R.string.fill_ignore_capture), onValueChange = {}, readOnly = true,
                                enabled = state.phase == FillPhase.EDITING, label = { Text(stringResource(R.string.fill_captured_field)) },
                                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                                modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth())
                            ExposedDropdownMenu(expanded = expanded && state.phase == FillPhase.EDITING, onDismissRequest = { expanded = false }) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.fill_ignore_capture)) },
                                    onClick = { expanded = false; onCapturedField(null) })
                                for (field in capture.candidates) DropdownMenuItem(text = { Text(field.label) },
                                    onClick = { expanded = false; onCapturedField(field.name) })
                            }
                        }
                        if (capture.candidates.isEmpty()) Text(stringResource(R.string.fill_capture_no_field), style = MaterialTheme.typography.bodySmall)
                    } }
                    items(state.fields, key = { it.field.name }) { field ->
                        val error = (state.preview as? FillPreview.Blocked)?.error
                        val invalid = (error is PromptRenderError.MissingRequiredValue && error.field == field.field.name) ||
                            (error is PromptRenderError.InvalidChoiceValue && error.field == field.field.name)
                        FieldControl(field, input = state.input, enabled = state.phase == FillPhase.EDITING, invalid = invalid,
                            onEditInApp = onFillInApp.takeIf { state.builtinsResolved },
                            onValue = { onValue(field.field.name, it) })
                    }
                    if (state.phase == FillPhase.EDITING && !state.builtinsResolved && state.failure == null) item {
                        PawLoading(stringResource(R.string.fill_snapshot_pending), density = density)
                    }
                    state.preview?.let { preview -> item {
                        PawSectionHeading(stringResource(R.string.fill_preview))
                        Spacer(Modifier.height(PawSpacing.small))
                        when (preview) {
                            is FillPreview.Rendered -> {
                                var expanded by remember(preview.text) { mutableStateOf(false) }
                                var truncated by remember(preview.text) { mutableStateOf(false) }
                                Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                                    Column(Modifier.padding(if (state.input == FillInput.INLINE) PawSpacing.medium else PawSpacing.large)) {
                                        SelectionContainer { Text(preview.text, style = MaterialTheme.typography.bodyLarge,
                                            maxLines = if (state.input == FillInput.INLINE && !expanded) 3 else Int.MAX_VALUE,
                                            overflow = TextOverflow.Ellipsis, onTextLayout = { if (!expanded) truncated = it.hasVisualOverflow }) }
                                        if (state.input == FillInput.INLINE && (truncated || expanded)) TextButton(onClick = { expanded = !expanded }) {
                                            Text(stringResource(if (expanded) R.string.design_show_less else R.string.design_full_preview))
                                        }
                                    }
                                }
                            }
                            is FillPreview.Blocked -> PawMessage(stringResource(when (preview.error) {
                                PromptRenderError.InvalidPrompt -> R.string.fill_invalid_prompt
                                is PromptRenderError.UnsupportedFormat -> R.string.fill_read_only
                                is PromptRenderError.MissingRequiredValue -> R.string.fill_required_value
                                is PromptRenderError.InvalidChoiceValue -> R.string.fill_invalid_choice
                                is PromptRenderError.MissingBuiltin -> R.string.fill_snapshot_pending
                            }), tone = PawMessageTone.WARNING)
                        }
                    } }
                }
                Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
                    FlowRow(Modifier.fillMaxWidth().padding(horizontal = PawSpacing.large, vertical = PawSpacing.small),
                        horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium, Alignment.End),
                        verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                        if (state.phase != FillPhase.DELIVERED) {
                            if (state.deliveryMode != DeliveryMode.COPY) Button(onClick = { onInsert?.invoke() },
                                enabled = state.copyEnabled && onInsert != null, modifier = Modifier.heightIn(min = PawLayout.touchTarget)) {
                                Icon(Icons.AutoMirrored.Rounded.Send, null, Modifier.size(18.dp))
                                Spacer(Modifier.width(PawSpacing.small))
                                Text(stringResource(R.string.fill_insert))
                            }
                            if (state.deliveryMode == DeliveryMode.COPY || onInsert == null) {
                                Button(onClick = onCopy, enabled = state.copyEnabled, modifier = Modifier.heightIn(min = PawLayout.touchTarget)) {
                                    Icon(Icons.Rounded.ContentCopy, null, Modifier.size(18.dp))
                                    Spacer(Modifier.width(PawSpacing.small))
                                    Text(stringResource(R.string.fill_copy))
                                }
                            } else OutlinedButton(onClick = onCopy, enabled = state.copyEnabled,
                                modifier = Modifier.heightIn(min = PawLayout.touchTarget)) { Text(stringResource(R.string.fill_copy)) }
                        } else Button(onClick = onCancel, enabled = state.cancelEnabled,
                            modifier = Modifier.heightIn(min = PawLayout.touchTarget)) { Text(stringResource(R.string.fill_done)) }
                    }
                }
            }
        }
    }
}

/** Exposed boxes require an activity Back owner even while closed; IME popups also must not steal target focus. */
@Composable
private fun InlineChoiceControl(state: FillFieldState, label: String, enabled: Boolean, invalid: Boolean, onValue: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val field = state.field
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
        Box {
            OutlinedButton(onClick = { expanded = true }, enabled = enabled,
                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLowest),
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = MaterialTheme.shapes.medium) {
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(field.options.firstOrNull { it.value == state.value }?.label ?: state.value.ifEmpty { stringResource(R.string.fill_choose) },
                        style = MaterialTheme.typography.bodyLarge)
                }
                Icon(Icons.Rounded.ExpandMore, null, Modifier.size(20.dp))
            }
            DropdownMenu(expanded = expanded && enabled, onDismissRequest = { expanded = false },
                properties = PopupProperties(focusable = false)) {
                if (field.optional) DropdownMenuItem(text = { Text(stringResource(R.string.fill_clear_choice)) },
                    onClick = { expanded = false; onValue("") })
                for (option in field.options) DropdownMenuItem(text = { Text(option.label) },
                    onClick = { expanded = false; onValue(option.value) })
            }
        }
        if (invalid) Text(stringResource(R.string.fill_invalid_choice), color = MaterialTheme.colorScheme.error)
        field.description?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FieldControl(state: FillFieldState, input: FillInput, enabled: Boolean, invalid: Boolean,
    onEditInApp: (() -> Unit)?, onValue: (String) -> Unit) {
    val field = state.field
    val label = stringResource(if (field.optional) R.string.fill_optional_label else R.string.fill_required_label, field.label)
    if (field.kind == FieldKind.CHOICE) {
        if (input == FillInput.INLINE) {
            InlineChoiceControl(state, label, enabled, invalid, onValue)
            return
        }
        var expanded by remember { mutableStateOf(false) }
        ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { if (enabled) expanded = it }) {
            OutlinedTextField(value = field.options.firstOrNull { it.value == state.value }?.label ?: state.value.ifEmpty { stringResource(R.string.fill_choose) },
                onValueChange = {}, readOnly = true, enabled = enabled, isError = invalid, label = { Text(label) },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                supportingText = {
                    if (invalid) Text(stringResource(R.string.fill_invalid_choice))
                    else field.description?.let { Text(it) }
                }, modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth())
            ExposedDropdownMenu(expanded = expanded && enabled, onDismissRequest = { expanded = false }) {
                if (field.optional) DropdownMenuItem(text = { Text(stringResource(R.string.fill_clear_choice)) },
                    onClick = { expanded = false; onValue("") })
                for (option in field.options) DropdownMenuItem(text = { Text(option.label) },
                    onClick = { expanded = false; onValue(option.value) })
            }
        }
        return
    }
    if (input == FillInput.INLINE) {
        Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLowest) {
            Row(Modifier.fillMaxWidth().clickable(enabled = enabled && onEditInApp != null,
                role = Role.Button, onClickLabel = stringResource(R.string.fill_in_app), onClick = { onEditInApp?.invoke() })
                .heightIn(min = 56.dp).padding(PawSpacing.medium),
                horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(state.value.ifEmpty { stringResource(if (field.optional) R.string.fill_clear_choice else R.string.fill_required_value) },
                        style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (invalid) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                    field.description?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                }
                if (enabled && onEditInApp != null) Icon(Icons.AutoMirrored.Rounded.OpenInNew, null,
                    Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        return
    }
    OutlinedTextField(value = state.value, onValueChange = onValue, enabled = enabled, isError = invalid,
        singleLine = field.kind == FieldKind.TEXT, minLines = if (field.kind == FieldKind.MULTILINE) 3 else 1,
        label = { Text(label) }, supportingText = field.description?.let { description -> { Text(description) } },
        modifier = Modifier.fillMaxWidth())
}
