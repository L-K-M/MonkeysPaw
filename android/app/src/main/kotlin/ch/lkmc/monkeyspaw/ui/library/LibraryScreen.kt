package ch.lkmc.monkeyspaw.ui.library

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R

internal enum class LibraryMode { BROWSER, IME_PICKER }

/** Reusable picker surface. Entry activities supply intents and decide what selection opens. */
@Composable
internal fun LibraryScreen(
    state: LibraryUiState,
    onQuery: (String) -> Unit,
    onFilter: (LibraryFilter) -> Unit,
    onSelect: (LibrarySelection?) -> Unit,
    onToggleFavorite: (LibrarySelection) -> Unit,
    onClearFilters: () -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    onOpen: (LibrarySelection) -> Unit = {},
    onEdit: ((LibrarySelection) -> Unit)? = null,
    onCreate: (() -> Unit)? = null,
    onSettings: (() -> Unit)? = null,
    mode: LibraryMode = LibraryMode.BROWSER,
    onAssistantSettings: (() -> Unit)? = null,
    onWrite: (() -> Unit)? = null,
) {
    LazyColumn(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(stringResource(R.string.local_library_title), style = MaterialTheme.typography.headlineMedium)
                TextButton(onClick = onRefresh, enabled = !state.refreshing) { Text(stringResource(R.string.library_refresh)) }
            }
            if (state.refreshing) LinearProgressIndicator(Modifier.fillMaxWidth())
            onCreate?.let { TextButton(onClick = it) { Text(stringResource(R.string.editor_new)) } }
            onSettings?.let { TextButton(onClick = it) { Text(stringResource(R.string.settings_title)) } }
            if (mode == LibraryMode.BROWSER) {
                onWrite?.let { TextButton(onClick = it) { Text(stringResource(R.string.assistant_write_title)) } }
                onAssistantSettings?.let { TextButton(onClick = it) { Text(stringResource(R.string.assistant_settings_title)) } }
            }
        }
        item {
            OutlinedTextField(value = state.query, onValueChange = onQuery, singleLine = true,
                keyboardOptions = KeyboardOptions(showKeyboardOnFocus = mode != LibraryMode.IME_PICKER),
                label = { Text(stringResource(R.string.library_search)) }, modifier = Modifier.fillMaxWidth())
        }
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.sections, key = { sectionKey(it.filter) }) { section ->
                    FilterChip(selected = state.filter == section.filter, onClick = { onFilter(section.filter) },
                        label = { Text(stringResource(R.string.library_filter_count, sectionTitle(section), section.count)) })
                }
            }
        }
        state.failure?.let { failure ->
            item {
                Text(stringResource(when (failure) {
                    LibraryFailure.DATA -> R.string.library_data_failed
                    LibraryFailure.FAVOURITE -> R.string.library_favourite_failed
                    LibraryFailure.CHANGED -> R.string.library_prompt_changed
                }), color = MaterialTheme.colorScheme.error)
                TextButton(onClick = onRefresh, enabled = !state.refreshing) { Text(stringResource(R.string.retry)) }
            }
        }
        if (state.historyMaintenanceFailed) item { Text(stringResource(R.string.library_history_warning)) }
        state.selectedPrompt?.let { selected ->
            item {
                Text(stringResource(R.string.library_selected, selected.title), style = MaterialTheme.typography.titleSmall)
                TextButton(onClick = { onSelect(null) }) { Text(stringResource(R.string.library_clear_selection)) }
                onEdit?.let { edit -> TextButton(onClick = { edit(selected.selection) }) { Text(stringResource(R.string.editor_edit)) } }
            }
        }
        when (state.content) {
            LibraryContent.LOADING -> item {
                CircularProgressIndicator()
                Text(stringResource(R.string.library_loading))
            }
            LibraryContent.EMPTY -> item { Text(stringResource(R.string.library_empty)) }
            LibraryContent.NO_MATCH -> item {
                Text(stringResource(R.string.library_no_match))
                TextButton(onClick = onClearFilters) { Text(stringResource(R.string.library_clear_filters)) }
            }
            LibraryContent.FAILED -> Unit // The failure and retry stay above the search controls' results.
            LibraryContent.READY -> Unit
        }
        items(state.rows, key = { it.selection.relativePath }) { row ->
            PromptRow(row, selected = state.selectedPrompt?.selection == row.selection,
                favoriteEnabled = mode == LibraryMode.BROWSER && state.favoritePending == null && !row.isReadOnly,
                onSelect = { onSelect(row.selection); onOpen(row.selection) }, onToggleFavorite = { onToggleFavorite(row.selection) })
        }
        item { Spacer(Modifier.height(12.dp)) }
    }
}

private fun sectionKey(filter: LibraryFilter): String = when (filter) {
    LibraryFilter.All -> "all"
    LibraryFilter.Favourites -> "favourites"
    LibraryFilter.Recent -> "recent"
    is LibraryFilter.Folder -> "folder:" + filter.path
    is LibraryFilter.Tag -> "tag:" + filter.key
}

@Composable
private fun sectionTitle(section: LibrarySection): String = when (section.filter) {
    LibraryFilter.All -> stringResource(R.string.library_all)
    LibraryFilter.Favourites -> stringResource(R.string.library_favourites)
    LibraryFilter.Recent -> stringResource(R.string.library_recent)
    is LibraryFilter.Folder, is LibraryFilter.Tag -> section.title
}

@Composable
private fun PromptRow(row: LibraryRow, selected: Boolean, favoriteEnabled: Boolean,
    onSelect: () -> Unit, onToggleFavorite: () -> Unit) {
    Card(onClick = onSelect, modifier = Modifier.fillMaxWidth().semantics { this.selected = selected },
        colors = CardDefaults.cardColors(containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer
            else MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(row.title, style = MaterialTheme.typography.titleMedium)
            Text(row.selection.relativePath, style = MaterialTheme.typography.bodySmall)
            row.description?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            if (row.tags.isNotEmpty()) Text(row.tags.joinToString(" ") { "#$it" }, style = MaterialTheme.typography.bodySmall)
            if (row.isReadOnly) Text(stringResource(R.string.library_read_only), style = MaterialTheme.typography.labelLarge)
            for (issue in row.issues) Text(issue.message, color = MaterialTheme.colorScheme.error)
            val favoriteDescription = stringResource(if (row.favorite) R.string.library_remove_favourite else R.string.library_add_favourite, row.title)
            Row {
                Checkbox(checked = row.favorite, onCheckedChange = { onToggleFavorite() }, enabled = favoriteEnabled,
                    modifier = Modifier.semantics { contentDescription = favoriteDescription })
                Text(stringResource(R.string.library_favourite), modifier = Modifier.padding(top = 12.dp))
            }
        }
    }
}
