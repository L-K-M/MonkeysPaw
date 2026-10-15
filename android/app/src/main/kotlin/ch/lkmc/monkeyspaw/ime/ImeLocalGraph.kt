package ch.lkmc.monkeyspaw.ime

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import ch.lkmc.monkeyspaw.core.ports.TextDelivery
import ch.lkmc.monkeyspaw.core.ports.TextDeliveryResult
import ch.lkmc.monkeyspaw.data.CopyTextDelivery
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.IoDispatcher
import ch.lkmc.monkeyspaw.ui.fill.FillSession
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.fill.FillViewModelFactory
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.CoroutineDispatcher
import javax.inject.Inject

/** Only the existing process-local index, Fill service and explicit sensitive Copy are reachable. */
internal class ImeLocalGraph @Inject constructor(
    private val repository: LibraryRepository,
    private val fillFactory: FillViewModelFactory,
    private val copy: CopyTextDelivery,
    @IoDispatcher private val worker: CoroutineDispatcher,
) {
    fun createModels(root: ImeSessionRoot, session: FillSession): ImeModels {
        val owner = root as ImeViewOwners
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                val model = when (modelClass) {
                    LibraryViewModel::class.java -> LibraryViewModel(repository, worker)
                    FillViewModel::class.java -> fillFactory.create(session, TextDelivery { mode, text ->
                        if (!session.isActive()) TextDeliveryResult.STALE else copy.deliver(mode, text)
                    })
                    else -> error("Unsupported input-view model.")
                }
                @Suppress("UNCHECKED_CAST")
                return model as T
            }
        }
        val provider = ViewModelProvider(owner, factory)
        return ImeModels(provider[LibraryViewModel::class.java], provider[FillViewModel::class.java])
    }
}
