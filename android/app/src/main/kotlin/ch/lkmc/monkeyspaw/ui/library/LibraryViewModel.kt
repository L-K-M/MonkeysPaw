package ch.lkmc.monkeyspaw.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.ranking.SearchNormalizer
import ch.lkmc.monkeyspaw.core.services.LibraryError
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.IoDispatcher
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

@HiltViewModel
internal class LibraryViewModel @Inject constructor(
    private val repository: LibraryRepository,
    @IoDispatcher private val worker: CoroutineDispatcher,
) : ViewModel() {
    private val mutableState = MutableStateFlow(LibraryUiState())
    val state = mutableState.asStateFlow()
    private var generation = 0L
    private var allRows = emptyList<LibraryRow>()
    private var preferredSelection: LibrarySelection? = null
    private var actionFailure: LibraryFailure? = null
    private var refreshJob: Job? = null

    init {
        viewModelScope.launch {
            repository.state.collect { library ->
                mutableState.value = mutableState.value.copy(refreshing = library.refreshing)
                if (library.refreshing) generation++ else load()
            }
        }
    }

    fun refresh() {
        if (refreshJob?.isActive == true) return
        actionFailure = null
        mutableState.value = mutableState.value.copy(failure = null, historyMaintenanceFailed = false)
        refreshJob = viewModelScope.launch { repository.refresh() }
    }

    fun setQuery(query: String) {
        if (query == state.value.query) return
        mutableState.value = mutableState.value.copy(query = query)
        load()
    }

    fun setFilter(requested: LibraryFilter) {
        val filter = if (requested is LibraryFilter.Tag) LibraryFilter.Tag(SearchNormalizer.normalize(requested.key)) else requested
        if (filter == state.value.filter || state.value.sections.none { it.filter == filter }) return
        mutableState.value = mutableState.value.copy(filter = filter)
        load()
    }

    fun clearFilters() {
        mutableState.value = mutableState.value.copy(query = "", filter = LibraryFilter.All)
        load()
    }

    fun select(selection: LibrarySelection?) {
        if (selection != null && state.value.rows.none { it.selection == selection }) return
        preferredSelection = selection
        mutableState.value = mutableState.value.copy(selectedPrompt = allRows.firstOrNull { it.selection == selection })
    }

    fun toggleFavorite(selection: LibrarySelection) {
        val row = allRows.firstOrNull { it.selection == selection } ?: return
        if (row.isReadOnly || state.value.favoritePending != null) return
        actionFailure = null
        mutableState.value = mutableState.value.copy(favoritePending = selection, failure = null, historyMaintenanceFailed = false)
        viewModelScope.launch {
            try {
                val saved = repository.withLibrary { library, _ ->
                    val entry = library.index.snapshot().prompts.firstOrNull {
                        it.entry.identity == selection.identity && it.entry.relativePath == selection.relativePath
                    }?.entry ?: throw LibraryError.Conflict
                    if (entry.stamp != row.stamp) throw LibraryError.Conflict
                    library.toggleFavorite(entry)
                }
                if (preferredSelection == selection) preferredSelection = LibrarySelection(saved.entry.identity, saved.entry.relativePath)
                mutableState.value = mutableState.value.copy(historyMaintenanceFailed = saved.historyMaintenanceFailed)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                actionFailure = if (error is LibraryError.Conflict) LibraryFailure.CHANGED else LibraryFailure.FAVOURITE
            } finally {
                mutableState.value = mutableState.value.copy(favoritePending = null)
            }
            load()
        }
    }

    private fun load() {
        val epoch = ++generation
        val query = state.value.query
        val filter = state.value.filter
        viewModelScope.launch {
            try {
                val loaded = repository.search(query)
                val projection = withContext(worker) { projectLibrary(loaded, filter) }
                if (epoch != generation) return@launch
                allRows = projection.all
                val selected = reconcileSelection()
                mutableState.value = mutableState.value.copy(
                    filter = projection.filter, sections = projection.sections, rows = projection.rows,
                    selectedPrompt = selected, content = projection.content,
                    failure = actionFailure ?: loaded.state.error?.let { LibraryFailure.DATA },
                )
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (epoch != generation) return@launch
                mutableState.value = mutableState.value.copy(failure = LibraryFailure.DATA,
                    content = if (allRows.isEmpty()) LibraryContent.FAILED else state.value.content)
            }
        }
    }

    private fun reconcileSelection(): LibraryRow? {
        val selection = preferredSelection ?: return null
        allRows.firstOrNull { it.selection == selection }?.let { return it }
        val sameIdentity = allRows.filter { it.selection.identity == selection.identity }
        if (sameIdentity.isEmpty()) return null
        if (sameIdentity.size != 1) {
            preferredSelection = null
            return null
        }
        return sameIdentity.single().also { preferredSelection = it.selection }
    }
}
