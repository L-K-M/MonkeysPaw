package ch.lkmc.monkeyspaw.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

/** Activity insets are consumed by the host; nested app bars add no second inset. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PawScreen(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    bottomBar: @Composable () -> Unit = {},
    floatingActionButton: @Composable () -> Unit = {},
    contentMaxWidth: Dp = PawLayout.readingWidth,
    content: @Composable BoxScope.() -> Unit,
) {
    Scaffold(modifier.fillMaxSize().imePadding(), contentWindowInsets = WindowInsets(0, 0, 0, 0),
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            TopAppBar(title = {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
            }, navigationIcon = {
                onBack?.let { back ->
                    IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.design_back))
                    }
                }
            }, actions = actions, windowInsets = WindowInsets(0, 0, 0, 0),
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface))
        }, bottomBar = bottomBar, floatingActionButton = floatingActionButton,
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding), contentAlignment = Alignment.TopCenter) {
            Box(Modifier.widthIn(max = contentMaxWidth).fillMaxSize(), content = content)
        }
    }
}

internal enum class PawMessageTone { INFO, WARNING, ERROR, SUCCESS }

@Composable
internal fun PawMessage(
    text: String,
    modifier: Modifier = Modifier,
    tone: PawMessageTone = PawMessageTone.INFO,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    val (container, foreground, icon) = when (tone) {
        PawMessageTone.INFO -> Triple(colors.secondaryContainer, colors.onSecondaryContainer, Icons.Rounded.Info)
        PawMessageTone.WARNING -> Triple(colors.tertiaryContainer, colors.onTertiaryContainer, Icons.Rounded.WarningAmber)
        PawMessageTone.ERROR -> Triple(colors.errorContainer, colors.onErrorContainer, Icons.Rounded.ErrorOutline)
        PawMessageTone.SUCCESS -> Triple(colors.primaryContainer, colors.onPrimaryContainer, Icons.Rounded.CheckCircle)
    }
    Surface(modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
        shape = MaterialTheme.shapes.medium, color = container, contentColor = foreground) {
        Column(Modifier.padding(PawSpacing.large), verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
            Row(horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium), verticalAlignment = Alignment.Top) {
                Icon(icon, null, Modifier.size(20.dp))
                Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            }
            if (actionLabel != null && onAction != null) {
                TextButton(onClick = onAction, modifier = Modifier.align(Alignment.End)) { Text(actionLabel) }
            }
        }
    }
}

@Composable
internal fun PawSectionHeading(title: String, supportingText: String? = null, modifier: Modifier = Modifier) {
    Column(modifier.padding(top = PawSpacing.small), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.semantics { heading() })
        supportingText?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
internal fun PawLoading(label: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(PawSpacing.page).semantics { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(PawSpacing.large)) {
        CircularProgressIndicator(Modifier.size(32.dp), strokeWidth = 3.dp)
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun PawEmptyState(
    title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier,
    actionLabel: String? = null, onAction: (() -> Unit)? = null,
) {
    Column(modifier.fillMaxWidth().padding(horizontal = PawSpacing.section, vertical = PawSpacing.page),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.secondaryContainer) {
            Icon(icon, null, Modifier.padding(PawSpacing.large).size(32.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        Text(body, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.widthIn(max = 420.dp))
        if (actionLabel != null && onAction != null) Button(onClick = onAction) { Text(actionLabel) }
    }
}

@Composable
internal fun PawSettingRow(
    title: String, subtitle: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier,
) {
    ListItem(modifier = modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 76.dp),
        headlineContent = { Text(title, style = MaterialTheme.typography.titleMedium) },
        supportingContent = { Text(subtitle, style = MaterialTheme.typography.bodyMedium) },
        leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
        trailingContent = { Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow))
}

@Composable
internal fun PawActionBar(content: @Composable RowScope.() -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Row(Modifier.fillMaxWidth().padding(horizontal = PawSpacing.large, vertical = PawSpacing.medium),
            horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium), verticalAlignment = Alignment.CenterVertically,
            content = content)
    }
}
