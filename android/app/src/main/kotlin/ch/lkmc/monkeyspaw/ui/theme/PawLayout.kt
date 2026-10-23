package ch.lkmc.monkeyspaw.ui.theme

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.unit.dp

internal object PawSpacing {
    val xs = 4.dp
    val small = 8.dp
    val medium = 12.dp
    val large = 16.dp
    val section = 24.dp
    val page = 32.dp
}

internal object PawLayout {
    val touchTarget = 48.dp
    val pageGutter = 24.dp
    val iconWell = 40.dp
    val connectedGap = 2.dp
    val filterLabelWidth = 200.dp
    val expandedBreakpoint = 840.dp
    val navigationWidth = 240.dp
    val readingWidth = 840.dp
    val libraryWidth = 1040.dp
    val contentPadding = PaddingValues(horizontal = PawSpacing.large, vertical = PawSpacing.large)
}
