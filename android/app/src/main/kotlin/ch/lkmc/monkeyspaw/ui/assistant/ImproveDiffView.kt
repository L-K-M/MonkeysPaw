package ch.lkmc.monkeyspaw.ui.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactDiff
import ch.lkmc.monkeyspaw.core.domain.llm.LineDiffLine
import ch.lkmc.monkeyspaw.core.domain.llm.PlaceholderChange

private val minimumDiffPaneWidth = 240.dp
private enum class DiffSide { CURRENT, CANDIDATE }

/** Both panes stay present on phones; rows share a height even when long lines wrap. */
@Composable
internal fun ImproveDiffView(diff: ArtifactDiff) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.assistant_diff_title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.assistant_diff_help), style = MaterialTheme.typography.bodySmall)
        for (warning in diff.placeholderWarnings) Text(when (warning) {
            is PlaceholderChange.Added -> stringResource(R.string.assistant_placeholder_added, warning.name)
            is PlaceholderChange.Removed -> stringResource(R.string.assistant_placeholder_removed, warning.name)
            is PlaceholderChange.Renamed -> stringResource(R.string.assistant_placeholder_renamed, warning.from, warning.to)
        }, color = MaterialTheme.colorScheme.error)
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val paneWidth = maxOf(minimumDiffPaneWidth, (maxWidth - 1.dp) / 2)
            Box(Modifier.horizontalScroll(rememberScrollState())) {
                // A bounded nested list keeps large valid comparisons lazy.
                LazyColumn(Modifier.width(paneWidth * 2 + 1.dp).heightIn(max = 420.dp)) {
                    item {
                        Row {
                            Text(stringResource(R.string.assistant_diff_current), Modifier.width(paneWidth).padding(8.dp))
                            Text(stringResource(R.string.assistant_diff_candidate), Modifier.width(paneWidth).padding(8.dp))
                        }
                    }
                    item { Text(stringResource(R.string.assistant_diff_front_matter), Modifier.padding(8.dp), style = MaterialTheme.typography.titleSmall) }
                    items(diff.frontMatter) { line -> DiffRow(line, paneWidth) }
                    item { Text(stringResource(R.string.assistant_diff_body), Modifier.padding(8.dp), style = MaterialTheme.typography.titleSmall) }
                    items(diff.body) { line -> DiffRow(line, paneWidth) }
                }
            }
        }
    }
}

@Composable
private fun DiffRow(line: LineDiffLine, paneWidth: Dp) {
    Row(Modifier.height(IntrinsicSize.Min)) {
        DiffLine(line, DiffSide.CURRENT, Modifier.width(paneWidth).fillMaxHeight())
        VerticalDivider()
        DiffLine(line, DiffSide.CANDIDATE, Modifier.width(paneWidth).fillMaxHeight())
    }
}

@Composable
private fun DiffLine(line: LineDiffLine, side: DiffSide, modifier: Modifier) {
    val present = when (side) {
        DiffSide.CURRENT -> line.kind != LineDiffLine.Kind.ADDED
        DiffSide.CANDIDATE -> line.kind != LineDiffLine.Kind.REMOVED
    }
    val background = when {
        !present || line.kind == LineDiffLine.Kind.UNCHANGED -> Color.Transparent
        side == DiffSide.CURRENT -> MaterialTheme.colorScheme.errorContainer
        else -> MaterialTheme.colorScheme.secondaryContainer
    }
    Row(modifier.background(background).padding(4.dp), verticalAlignment = Alignment.Top) {
        val number = if (side == DiffSide.CURRENT) line.originalLine else line.mergedLine
        Text(if (present) number?.toString().orEmpty() else "", Modifier.width(40.dp),
            fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        SelectionContainer(Modifier.weight(1f)) {
            Column {
                Text(if (present) displayDiffLine(line.text, stringResource(R.string.assistant_diff_no_newline)) else " ",
                    fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                if (present && line.placeholderWarnings.isNotEmpty()) {
                    Text(stringResource(R.string.assistant_diff_warning), color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }
}

/** Display markers are separate from Core's exact bytes used by checked acceptance. */
internal fun displayDiffLine(text: String, noNewline: String): String = when {
    text.endsWith("\r\n") -> text.dropLast(2) + " ␍↵"
    text.endsWith('\n') -> text.dropLast(1) + " ↵"
    else -> "$text ($noNewline)"
}
