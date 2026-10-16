package ch.lkmc.monkeyspaw.ui.editor

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import ch.lkmc.monkeyspaw.core.ports.Clock
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.ApplicationScope
import ch.lkmc.monkeyspaw.di.IoDispatcher
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import javax.inject.Inject

/** Entry-owned stores use the same editor and singleton library graph as Library. */
internal class EditorViewModelFactory @Inject constructor(
    private val repository: LibraryRepository,
    @IoDispatcher private val worker: CoroutineDispatcher,
    private val clock: Clock,
    @ApplicationScope private val applicationScope: CoroutineScope,
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass == EditorViewModel::class.java)
        @Suppress("UNCHECKED_CAST")
        return EditorViewModel(repository, worker, clock, applicationScope) as T
    }
}
