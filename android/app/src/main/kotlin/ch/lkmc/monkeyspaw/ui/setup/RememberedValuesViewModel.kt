package ch.lkmc.monkeyspaw.ui.setup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.data.LibraryRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

internal enum class RememberedValuesState { IDLE, CONFIRMING, CLEARING, CLEARED, FAILED }

@HiltViewModel
internal class RememberedValuesViewModel @Inject constructor(
    private val repository: LibraryRepository,
    private val fill: FillService,
) : ViewModel() {
    private val mutableState = MutableStateFlow(RememberedValuesState.IDLE)
    val state = mutableState.asStateFlow()

    fun requestForget() {
        if (state.value != RememberedValuesState.CLEARING) mutableState.value = RememberedValuesState.CONFIRMING
    }

    fun cancel() {
        if (state.value != RememberedValuesState.CLEARING) mutableState.value = RememberedValuesState.IDLE
    }

    fun forget() {
        if (state.value != RememberedValuesState.CONFIRMING && state.value != RememberedValuesState.FAILED) return
        mutableState.value = RememberedValuesState.CLEARING
        viewModelScope.launch {
            try {
                repository.withLibrary { _, _ -> fill.forgetAllValues() }
                mutableState.value = RememberedValuesState.CLEARED
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                mutableState.value = RememberedValuesState.FAILED
            }
        }
    }
}
