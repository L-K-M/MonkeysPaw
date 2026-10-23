package ch.lkmc.monkeyspaw.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

internal fun pawGroupedShape(index: Int, count: Int) = RoundedCornerShape(
    topStart = if (index == 0) PawSpacing.section else PawSpacing.xs,
    topEnd = if (index == 0) PawSpacing.section else PawSpacing.xs,
    bottomStart = if (index == count - 1) PawSpacing.section else PawSpacing.xs,
    bottomEnd = if (index == count - 1) PawSpacing.section else PawSpacing.xs,
)

/** Tonal inputs share a quiet resting state and an explicit focus/error outline. */
@Composable
internal fun pawInputColors(container: Color = MaterialTheme.colorScheme.surfaceContainerLow): TextFieldColors = OutlinedTextFieldDefaults.colors(
    unfocusedContainerColor = container,
    focusedContainerColor = container,
    disabledContainerColor = container,
    unfocusedBorderColor = Color.Transparent,
    disabledBorderColor = Color.Transparent,
)

@Composable
internal fun PawTextField(
    value: String, onValueChange: (String) -> Unit, label: String,
    modifier: Modifier = Modifier, enabled: Boolean = true, singleLine: Boolean = false,
    minLines: Int = 1, supportingText: String? = null, placeholder: String? = null,
    isError: Boolean = false, keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    OutlinedTextField(value, onValueChange, modifier.fillMaxWidth(), enabled = enabled,
        label = { Text(label) }, placeholder = placeholder?.let { { Text(it) } },
        supportingText = supportingText?.let { { Text(it) } },
        singleLine = singleLine, minLines = minLines, isError = isError,
        shape = MaterialTheme.shapes.medium, colors = pawInputColors(),
        keyboardOptions = keyboardOptions, keyboardActions = keyboardActions)
}

/** A compact introduction gives each task a purpose without adding another card. */
@Composable
internal fun PawIntro(title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
        Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.primaryContainer) {
            Icon(icon, null, Modifier.padding(PawSpacing.medium).size(PawSpacing.page),
                tint = MaterialTheme.colorScheme.onPrimaryContainer)
        }
        Text(title, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.semantics { heading() })
        Text(body, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Reading-width actions wrap at large font sizes and stay aligned with their form. */
@Composable
internal fun PawActionDock(content: @Composable FlowRowScope.() -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            FlowRow(Modifier.widthIn(max = PawLayout.readingWidth).fillMaxWidth()
                .padding(horizontal = PawLayout.pageGutter, vertical = PawSpacing.medium),
                horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium, Alignment.End),
                verticalArrangement = Arrangement.spacedBy(PawSpacing.small), content = content)
        }
    }
}
