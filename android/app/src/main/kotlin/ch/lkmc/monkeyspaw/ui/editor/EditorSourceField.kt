package ch.lkmc.monkeyspaw.ui.editor

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.TextFieldValue
import ch.lkmc.monkeyspaw.R

/** Native cursor/composition state only; the model owns the raw buffer and checked quote range. */
@Composable
internal fun EditorSourceField(source: String, quote: ReviewQuoteSelection?, editable: Boolean,
    onEdit: (String) -> Unit, onClearQuote: () -> Unit) {
    var field by rememberEditorSourceField(source)
    val focus = remember { FocusRequester() }
    LaunchedEffect(quote) { if (quote != null) focus.requestFocus() }
    OutlinedTextField(value = editorSourceValue(field, source, quote),
        onValueChange = { value ->
            field = value
            onClearQuote()
            onEdit(value.text)
        }, readOnly = !editable, label = { Text(stringResource(R.string.editor_source)) }, minLines = 12,
        textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
        colors = OutlinedTextFieldDefaults.colors(
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        modifier = Modifier.fillMaxWidth().focusRequester(focus))
}

@Composable
internal fun rememberEditorSourceField(source: String): MutableState<TextFieldValue> =
    remember { mutableStateOf(TextFieldValue(source)) }

internal fun editorSourceValue(field: TextFieldValue, source: String, quote: ReviewQuoteSelection?): TextFieldValue {
    val selection = quote?.let { TextRange(it.start, it.endExclusive) }
        ?: if (field.text == source) field.selection else TextRange.Zero
    return if (field.text == source) field.copy(selection = selection) else TextFieldValue(source, selection)
}
