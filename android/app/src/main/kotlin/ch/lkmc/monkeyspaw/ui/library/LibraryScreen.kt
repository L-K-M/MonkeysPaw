package ch.lkmc.monkeyspaw.ui.library

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.ShortText
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawLayout
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing

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
    onAccount: (() -> Unit)? = null,
    onResolve: ((LibrarySelection) -> Unit)? = null,
    notice: String? = null,
) {
    if (mode == LibraryMode.IME_PICKER) {
        Column(modifier.fillMaxSize()) {
            LibraryFilters(state, onFilter, mode)
            LibraryResults(state, mode, onSelect, onOpen, onToggleFavorite, onClearFilters, onRefresh,
                Modifier.weight(1f), notice = notice)
        }
        return
    }

    var menuOpen by remember { mutableStateOf(false) }
    PawScreen(stringResource(R.string.design_library_title), modifier, contentMaxWidth = PawLayout.libraryWidth,
        style = PawScreenStyle.OVERVIEW,
        actions = {
            if (mode == LibraryMode.BROWSER) {
                onWrite?.let { write ->
                    IconButton(onClick = write) { Icon(Icons.Rounded.AutoAwesome, stringResource(R.string.assistant_write_title)) }
                }
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Rounded.MoreVert, stringResource(R.string.design_more_options))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.library_refresh)) },
                            leadingIcon = { Icon(Icons.Rounded.Refresh, null) }, enabled = !state.refreshing,
                            onClick = { menuOpen = false; onRefresh() })
                        onSettings?.let { settings -> DropdownMenuItem(text = { Text(stringResource(R.string.settings_title)) },
                            leadingIcon = { Icon(Icons.Rounded.Settings, null) }, onClick = { menuOpen = false; settings() }) }
                        onAccount?.let { account -> DropdownMenuItem(text = { Text(stringResource(R.string.account_title)) },
                            leadingIcon = { Icon(Icons.Rounded.AccountCircle, null) }, onClick = { menuOpen = false; account() }) }
                        onAssistantSettings?.let { settings -> DropdownMenuItem(text = { Text(stringResource(R.string.assistant_settings_title)) },
                            leadingIcon = { Icon(Icons.Rounded.Tune, null) }, onClick = { menuOpen = false; settings() }) }
                    }
                }
            }
        }, floatingActionButton = {
            // Material's extended FAB clears text semantics and uses its icon's label.
            onCreate?.takeIf { state.content != LibraryContent.EMPTY && state.content != LibraryContent.NO_MATCH }?.let { create -> ExtendedFloatingActionButton(onClick = create,
                icon = { Icon(Icons.Rounded.Add, stringResource(R.string.editor_new)) }, text = { Text(stringResource(R.string.editor_new)) }) }
        },
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= PawLayout.expandedBreakpoint
            val header: @Composable () -> Unit = {
                Column {
                    LibrarySearch(state, onQuery, mode)
                    if (!wide) LibraryFilters(state, onFilter, mode)
                    if (state.refreshing) LinearProgressIndicator(Modifier.fillMaxWidth())
                }
            }
            Row(Modifier.fillMaxSize()) {
                if (wide) {
                    Surface(Modifier.width(PawLayout.navigationWidth).fillMaxHeight().padding(PawSpacing.medium),
                        shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                        LazyColumn(contentPadding = PaddingValues(PawSpacing.small)) {
                            items(state.sections, key = { sectionKey(it.filter) }) { section ->
                                NavigationDrawerItem(label = { Text(sectionTitle(section), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                    selected = state.filter == section.filter, onClick = { onFilter(section.filter) },
                                    badge = { Text(section.count.toString()) },
                                    icon = { Icon(sectionIcon(section.filter), null) })
                            }
                        }
                    }
                }
                Column(Modifier.weight(1f)) {
                    LibraryResults(state, mode, onSelect, onOpen, onToggleFavorite, onClearFilters, onRefresh,
                        Modifier.weight(1f), onEdit, onCreate, onResolve,
                        scrollingHeader = header)
                }
            }
        }
    }
}

@Composable
private fun LibrarySearch(state: LibraryUiState, onQuery: (String) -> Unit, mode: LibraryMode) {
    OutlinedTextField(value = state.query, onValueChange = onQuery, singleLine = true,
        keyboardOptions = KeyboardOptions(showKeyboardOnFocus = mode != LibraryMode.IME_PICKER),
        placeholder = { Text(stringResource(R.string.library_search)) },
        leadingIcon = { Icon(Icons.Rounded.Search, null) },
        trailingIcon = { if (state.query.isNotEmpty()) IconButton(onClick = { onQuery("") }) {
            Icon(Icons.Rounded.Close, stringResource(R.string.design_clear_search))
        } }, shape = MaterialTheme.shapes.extraLarge,
        colors = OutlinedTextFieldDefaults.colors(unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow, unfocusedBorderColor = Color.Transparent),
        modifier = Modifier.fillMaxWidth().padding(horizontal = PawLayout.pageGutter, vertical = PawSpacing.small))
}

@Composable
private fun LibraryFilters(state: LibraryUiState, onFilter: (LibraryFilter) -> Unit, mode: LibraryMode) {
    val gutter = if (mode == LibraryMode.IME_PICKER) PawSpacing.medium else PawLayout.pageGutter
    val sections = libraryFilterSections(state.sections)
    val activeBrowse = sections.browse.firstOrNull { it.filter == state.filter }
    val activeTitle = activeBrowse?.let { sectionTitle(it) }
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(end = gutter), verticalAlignment = Alignment.CenterVertically) {
        LazyRow(Modifier.weight(1f), contentPadding = PaddingValues(start = gutter, end = PawSpacing.small),
            horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
            activeBrowse?.let { section -> item(key = sectionKey(section.filter)) {
                LibraryFilterChip(section, selected = true, onClick = { expanded = true })
            } }
            items(sections.quick, key = { sectionKey(it.filter) }) { section ->
                LibraryFilterChip(section, selected = state.filter == section.filter, onClick = { onFilter(section.filter) })
            }
        }
        if (sections.browse.isNotEmpty()) {
            Box {
                FilledTonalIconButton(onClick = { expanded = true }, modifier = Modifier.semantics {
                    activeTitle?.let { stateDescription = it }
                }) { Icon(Icons.Rounded.FolderOpen, stringResource(R.string.design_browse)) }
                // The external editor must remain the input target while the keyboard's menu is open.
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.heightIn(max = 360.dp),
                    properties = PopupProperties(focusable = mode == LibraryMode.BROWSER)) {
                    for (section in sections.browse) DropdownMenuItem(text = { Text(sectionTitle(section)) },
                        leadingIcon = { Icon(sectionIcon(section.filter), null) },
                        trailingIcon = { Text(section.count.toString(), style = MaterialTheme.typography.labelMedium) },
                        onClick = { expanded = false; onFilter(section.filter) })
                }
            }
        }
    }
}

@Composable
private fun LibraryFilterChip(section: LibrarySection, selected: Boolean, onClick: () -> Unit) {
    FilterChip(selected = selected, onClick = onClick,
        label = { Text(sectionTitle(section), maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.widthIn(max = PawLayout.filterLabelWidth)) },
        shape = MaterialTheme.shapes.extraLarge, border = null,
        colors = FilterChipDefaults.filterChipColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            selectedContainerColor = MaterialTheme.colorScheme.secondaryContainer),
        leadingIcon = if (selected) { { Icon(Icons.Rounded.Check, null, Modifier.size(18.dp)) } } else null)
}

@Composable
private fun LibraryResults(
    state: LibraryUiState, mode: LibraryMode, onSelect: (LibrarySelection?) -> Unit,
    onOpen: (LibrarySelection) -> Unit, onToggleFavorite: (LibrarySelection) -> Unit,
    onClearFilters: () -> Unit, onRefresh: () -> Unit, modifier: Modifier,
    onEdit: ((LibrarySelection) -> Unit)? = null, onCreate: (() -> Unit)? = null,
    onResolve: ((LibrarySelection) -> Unit)? = null, notice: String? = null,
    scrollingHeader: (@Composable () -> Unit)? = null,
) {
    val density = if (mode == LibraryMode.IME_PICKER) PawContentDensity.COMPACT else PawContentDensity.COMFORTABLE
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = if (onCreate != null) 96.dp else PawSpacing.large)) {
        // Keep one header location through IME resizing, and let short windows scroll past it.
        scrollingHeader?.let { header -> item { header() } }
        if (mode == LibraryMode.BROWSER && state.content == LibraryContent.READY) item {
            Text(pluralStringResource(R.plurals.design_prompt_count, state.rows.size, state.rows.size),
                style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = PawLayout.pageGutter, vertical = PawSpacing.medium))
        }
        notice?.let { item { PawMessage(it, Modifier.padding(PawSpacing.medium), PawMessageTone.WARNING) } }
        state.failure?.let { failure -> item {
            PawMessage(stringResource(when (failure) {
                LibraryFailure.DATA -> R.string.library_data_failed
                LibraryFailure.FAVOURITE -> R.string.library_favourite_failed
                LibraryFailure.CHANGED -> R.string.library_prompt_changed
            }), Modifier.padding(PawSpacing.large), PawMessageTone.ERROR,
                actionLabel = stringResource(R.string.retry), onAction = onRefresh.takeUnless { state.refreshing })
        } }
        if (state.historyMaintenanceFailed) item {
            PawMessage(stringResource(R.string.library_history_warning), Modifier.padding(PawSpacing.large), PawMessageTone.WARNING)
        }
        state.selectedPrompt?.takeIf { mode == LibraryMode.BROWSER && state.rows.none { row -> row.selection == it.selection } }?.let { selected -> item {
            ListItem(headlineContent = { Text(stringResource(R.string.library_selected, selected.title)) },
                supportingContent = { onEdit?.let { edit -> TextButton(onClick = { edit(selected.selection) }) { Text(stringResource(R.string.editor_edit)) } } },
                trailingContent = { IconButton(onClick = { onSelect(null) }) {
                    Icon(Icons.Rounded.Close, stringResource(R.string.library_clear_selection))
                } })
        } }
        when (state.content) {
            LibraryContent.LOADING -> item { PawLoading(stringResource(R.string.library_loading), density = density) }
            LibraryContent.EMPTY -> item {
                PawEmptyState(stringResource(R.string.design_empty_library_title), stringResource(R.string.design_empty_library_body),
                    Icons.Rounded.AutoAwesome, actionLabel = onCreate?.let { stringResource(R.string.editor_new) }, onAction = onCreate,
                    density = density)
            }
            LibraryContent.NO_MATCH -> item {
                val (title, body, icon) = when {
                    state.query.isBlank() && state.filter == LibraryFilter.Favourites ->
                        Triple(R.string.design_no_favourites, R.string.design_no_favourites_body, Icons.Rounded.StarBorder)
                    state.query.isBlank() && state.filter == LibraryFilter.Recent ->
                        Triple(R.string.design_no_recents, R.string.design_no_recents_body, Icons.Rounded.History)
                    else -> Triple(R.string.design_no_matches_title, R.string.library_no_match, Icons.Rounded.SearchOff)
                }
                Column {
                    PawEmptyState(stringResource(title), stringResource(body), icon,
                        actionLabel = stringResource(if (state.query.isBlank()) R.string.design_show_all_prompts else R.string.library_clear_filters),
                        onAction = onClearFilters, density = density)
                    onCreate?.let { create ->
                        TextButton(onClick = create, modifier = Modifier.align(Alignment.CenterHorizontally)
                            .heightIn(min = PawLayout.touchTarget)) {
                            Icon(Icons.Rounded.Add, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(PawSpacing.small))
                            Text(stringResource(R.string.editor_new))
                        }
                    }
                }
            }
            LibraryContent.FAILED, LibraryContent.READY -> Unit
        }
        items(state.rows, key = { it.selection.relativePath }) { row ->
            PromptRow(row, mode, selected = state.selectedPrompt?.selection == row.selection,
                favoriteEnabled = mode == LibraryMode.BROWSER && state.favoritePending == null && row.canFavorite,
                onOpen = { onSelect(row.selection); onOpen(row.selection) },
                onToggleFavorite = { onToggleFavorite(row.selection) },
                onEdit = onEdit?.let { edit -> { onSelect(row.selection); edit(row.selection) } },
                onClearSelection = { onSelect(null) }.takeIf { mode == LibraryMode.BROWSER && state.selectedPrompt?.selection == row.selection },
                onResolve = onResolve?.takeIf { row.syncOrigin != null }?.let { resolve ->
                    { onSelect(row.selection); resolve(row.selection) }
                })
            if (mode == LibraryMode.BROWSER) HorizontalDivider(Modifier.padding(horizontal = PawLayout.pageGutter),
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f))
        }
    }
}

@Composable
private fun PromptRow(row: LibraryRow, mode: LibraryMode, selected: Boolean, favoriteEnabled: Boolean,
    onOpen: () -> Unit, onToggleFavorite: () -> Unit, onEdit: (() -> Unit)?, onClearSelection: (() -> Unit)?, onResolve: (() -> Unit)?) {
    if (mode == LibraryMode.IME_PICKER) {
        Surface(onClick = onOpen, modifier = Modifier.fillMaxWidth()
            .padding(horizontal = PawSpacing.small, vertical = PawLayout.connectedGap).semantics { this.selected = selected },
            shape = MaterialTheme.shapes.small,
            color = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLowest) {
            Row(Modifier.heightIn(min = 64.dp).padding(horizontal = PawSpacing.medium, vertical = PawSpacing.small),
                horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium), verticalAlignment = Alignment.CenterVertically) {
                Icon(if (row.favorite) Icons.Rounded.Star else Icons.AutoMirrored.Rounded.ShortText, null,
                    Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                    Text(row.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    row.description?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(20.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        return
    }

    Surface(onClick = onOpen, modifier = Modifier.fillMaxWidth().semantics { this.selected = selected },
        color = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface) {
        Column(Modifier.padding(start = PawLayout.pageGutter, end = PawSpacing.small, top = PawSpacing.small, bottom = PawSpacing.large)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(row.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
                IconToggleButton(checked = row.favorite, onCheckedChange = { onToggleFavorite() }, enabled = favoriteEnabled) {
                    Icon(if (row.favorite) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                        stringResource(if (row.favorite) R.string.library_remove_favourite else R.string.library_add_favourite, row.title),
                        tint = if (row.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                PromptOptions(row.title, onEdit, onResolve, onClearSelection)
            }
            Column(Modifier.padding(end = PawSpacing.large), verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                row.description?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                if (mode == LibraryMode.BROWSER) {
                    val details = listOfNotNull(row.group?.let { stringResource(R.string.library_group_role, it.name, it.role.wireValue) }
                        ?: row.folder.takeIf { it.isNotEmpty() },
                        stringResource(R.string.library_read_only).takeIf { row.isReadOnly },
                        stringResource(R.string.library_private_copy).takeIf { row.syncOrigin != null })
                    val metadata = details + row.tags.map { "#$it" }
                    if (metadata.isNotEmpty()) Text(metadata.joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    for (issue in row.issues) Text(issue.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@Composable
private fun PromptOptions(title: String, onEdit: (() -> Unit)?, onResolve: (() -> Unit)?, onClearSelection: (() -> Unit)?) {
    if (onEdit == null && onResolve == null && onClearSelection == null) return
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) { Icon(Icons.Rounded.MoreVert,
            stringResource(R.string.design_prompt_options, title), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            onEdit?.let { edit -> DropdownMenuItem(text = { Text(stringResource(R.string.editor_edit)) },
                leadingIcon = { Icon(Icons.Rounded.Edit, null) }, onClick = { expanded = false; edit() }) }
            onResolve?.let { resolve -> DropdownMenuItem(text = { Text(stringResource(R.string.resolve_open)) },
                leadingIcon = { Icon(Icons.Rounded.Difference, null) }, onClick = { expanded = false; resolve() }) }
            onClearSelection?.let { clear -> DropdownMenuItem(text = { Text(stringResource(R.string.library_clear_selection)) },
                leadingIcon = { Icon(Icons.Rounded.Close, null) }, onClick = { expanded = false; clear() }) }
        }
    }
}

private fun sectionIcon(filter: LibraryFilter) = when (filter) {
    LibraryFilter.All -> Icons.Rounded.Description
    LibraryFilter.Favourites -> Icons.Rounded.StarBorder
    LibraryFilter.Recent -> Icons.Rounded.History
    LibraryFilter.Conflicts -> Icons.Rounded.Difference
    is LibraryFilter.Group -> Icons.Rounded.Group
    is LibraryFilter.Folder -> Icons.Rounded.FolderOpen
    is LibraryFilter.Tag -> Icons.Rounded.Tag
}

private fun sectionKey(filter: LibraryFilter): String = when (filter) {
    LibraryFilter.All -> "all"
    LibraryFilter.Favourites -> "favourites"
    LibraryFilter.Recent -> "recent"
    LibraryFilter.Conflicts -> "conflicts"
    is LibraryFilter.Group -> "group:" + filter.id.rawValue
    is LibraryFilter.Folder -> "folder:" + filter.path
    is LibraryFilter.Tag -> "tag:" + filter.key
}

@Composable
private fun sectionTitle(section: LibrarySection): String = when (section.filter) {
    LibraryFilter.All -> stringResource(R.string.library_all)
    LibraryFilter.Favourites -> stringResource(R.string.library_favourites)
    LibraryFilter.Recent -> stringResource(R.string.library_recent)
    LibraryFilter.Conflicts -> stringResource(R.string.library_conflicts)
    is LibraryFilter.Group -> stringResource(R.string.library_group_role, section.title, section.group?.role?.wireValue.orEmpty())
    is LibraryFilter.Folder, is LibraryFilter.Tag -> section.title
}
