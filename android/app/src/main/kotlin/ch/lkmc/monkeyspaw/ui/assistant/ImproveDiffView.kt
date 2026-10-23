package ch.lkmc.monkeyspaw.ui.assistant

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactDiff
import ch.lkmc.monkeyspaw.core.domain.llm.LineDiffLine
import ch.lkmc.monkeyspaw.ui.components.PawSectionHeading
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

private val minimumDiffPaneWidth = 240.dp
private val twoPaneDiffWidth = 600.dp
private enum class DiffSide { CURRENT, CANDIDATE }

/**
 * Wide layouts keep both panes; below the readable two-pane width (scaled for
 * font size) one unified list shows the same exact lines with +/- markers.
 */
@Composable
internal fun ImproveDiffView(diff: ArtifactDiff,
    currentLabel: Int = R.string.assistant_diff_current,
    candidateLabel: Int = R.string.assistant_diff_candidate,
    title: Int = R.string.assistant_diff_title,
) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        PawSectionHeading(stringResource(title), supportingText = stringResource(R.string.assistant_diff_help))
        for (warning in diff.placeholderWarnings) {
            AssistantNotice(placeholderWarningText(warning), tone = AssistantTone.ERROR)
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val sideBySide = maxWidth >= twoPaneDiffWidth * LocalDensity.current.fontScale
            Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                if (sideBySide) {
                    val paneWidth = maxOf(minimumDiffPaneWidth, (maxWidth - 1.dp) / 2)
                    Box(Modifier.horizontalScroll(rememberScrollState())) {
                        // A bounded nested list keeps large valid comparisons lazy.
                        LazyColumn(Modifier.width(paneWidth * 2 + 1.dp).heightIn(max = 420.dp)) {
                            item {
                                Row(Modifier.height(IntrinsicSize.Min)) {
                                    Text(stringResource(currentLabel), Modifier.width(paneWidth).padding(8.dp),
                                        style = MaterialTheme.typography.labelLarge)
                                    VerticalDivider()
                                    Text(stringResource(candidateLabel), Modifier.width(paneWidth).padding(8.dp),
                                        style = MaterialTheme.typography.labelLarge)
                                }
                            }
                            item {
                                Text(stringResource(R.string.assistant_diff_front_matter),
                                    Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(8.dp),
                                    style = MaterialTheme.typography.labelLarge)
                            }
                            items(diff.frontMatter) { line -> DiffRow(line, paneWidth) }
                            item {
                                Text(stringResource(R.string.assistant_diff_body),
                                    Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(8.dp),
                                    style = MaterialTheme.typography.labelLarge)
                            }
                            items(diff.body) { line -> DiffRow(line, paneWidth) }
                        }
                    }
                } else {
                    // The same bounded lazy comparison as one readable column.
                    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                        item {
                            Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh)
                                .padding(PawSpacing.xs)) {
                                Spacer(Modifier.width(20.dp))
                                Text(stringResource(R.string.assistant_diff_line_numbers,
                                    stringResource(currentLabel), stringResource(candidateLabel)),
                                    fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        item {
                            Text(stringResource(R.string.assistant_diff_front_matter),
                                Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(8.dp),
                                style = MaterialTheme.typography.labelLarge)
                        }
                        items(diff.frontMatter) { line -> UnifiedDiffRow(line) }
                        item {
                            Text(stringResource(R.string.assistant_diff_body),
                                Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(8.dp),
                                style = MaterialTheme.typography.labelLarge)
                        }
                        items(diff.body) { line -> UnifiedDiffRow(line) }
                    }
                }
            }
        }
    }
}

/** Both panes stay present on wide layouts; rows share a height even when long lines wrap. */
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
            fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
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

/** One unified row keeps both line numbers when two panes no longer fit. */
@Composable
private fun UnifiedDiffRow(line: LineDiffLine) {
    val background = when (line.kind) {
        LineDiffLine.Kind.REMOVED -> MaterialTheme.colorScheme.errorContainer
        LineDiffLine.Kind.ADDED -> MaterialTheme.colorScheme.secondaryContainer
        LineDiffLine.Kind.UNCHANGED -> Color.Transparent
    }
    Row(Modifier.fillMaxWidth().background(background).padding(PawSpacing.xs), verticalAlignment = Alignment.Top) {
        Text(text = when (line.kind) {
            LineDiffLine.Kind.REMOVED -> "-"
            LineDiffLine.Kind.ADDED -> "+"
            LineDiffLine.Kind.UNCHANGED -> " "
        }, Modifier.width(20.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        Text(unifiedDiffLineNumbers(line.originalLine, line.mergedLine),
            Modifier.widthIn(min = 40.dp).padding(end = PawSpacing.small),
            fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        SelectionContainer(Modifier.weight(1f)) {
            Column {
                Text(displayDiffLine(line.text, stringResource(R.string.assistant_diff_no_newline)),
                    fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                if (line.placeholderWarnings.isNotEmpty()) {
                    Text(stringResource(R.string.assistant_diff_warning), color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }
}

/** Both line numbers share one gutter: current → candidate, · when a side has no line. */
internal fun unifiedDiffLineNumbers(original: Int?, merged: Int?): String =
    "${original ?: "·"}→${merged ?: "·"}"

/** Display markers are separate from Core's exact bytes used by checked acceptance. */
internal fun displayDiffLine(text: String, noNewline: String): String = when {
    text.endsWith("\r\n") -> text.dropLast(2) + " ␍↵"
    text.endsWith('\n') -> text.dropLast(1) + " ↵"
    else -> "$text ($noNewline)"
}
