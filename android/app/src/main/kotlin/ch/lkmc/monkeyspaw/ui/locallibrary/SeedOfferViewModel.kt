package ch.lkmc.monkeyspaw.ui.locallibrary

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.data.SeedInstaller
import ch.lkmc.monkeyspaw.data.SeedSummary
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

internal sealed interface SeedOfferUiState {
    data object Loading : SeedOfferUiState
    data object Offer : SeedOfferUiState
    data object Installing : SeedOfferUiState
    data object Ready : SeedOfferUiState
    data class Failed(val partial: SeedSummary? = null) : SeedOfferUiState
}

@HiltViewModel
internal class SeedOfferViewModel @Inject constructor(
    private val installer: SeedInstaller,
    private val library: LibraryRepository,
) : ViewModel() {
    private val mutableState = MutableStateFlow<SeedOfferUiState>(SeedOfferUiState.Loading)
    val state = mutableState.asStateFlow()
    val libraryState = library.state
    private var work: Job? = null

    fun refresh() {
        if (work?.isActive == true) return
        mutableState.value = SeedOfferUiState.Loading
        work = viewModelScope.launch {
            try {
                library.refresh().error?.let { throw it }
                mutableState.value = if (installer.shouldOffer()) SeedOfferUiState.Offer else SeedOfferUiState.Ready
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value = SeedOfferUiState.Failed()
            }
        }
    }

    fun accept() {
        if (mutableState.value != SeedOfferUiState.Offer) return
        mutableState.value = SeedOfferUiState.Installing
        work = viewModelScope.launch {
            val result = installer.install()
            val refreshed = library.refresh()
            mutableState.value = when {
                result.error != null -> SeedOfferUiState.Failed(result.summary)
                refreshed.error != null -> SeedOfferUiState.Failed()
                else -> SeedOfferUiState.Ready
            }
        }
    }

    fun decline() {
        if (mutableState.value != SeedOfferUiState.Offer) return
        mutableState.value = SeedOfferUiState.Loading
        work = viewModelScope.launch {
            try {
                installer.decline()
                mutableState.value = SeedOfferUiState.Ready
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value = SeedOfferUiState.Failed()
            }
        }
    }
}
