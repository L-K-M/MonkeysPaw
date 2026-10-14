package ch.lkmc.monkeyspaw.ime

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import ch.lkmc.monkeyspaw.data.CopyTextDelivery
import ch.lkmc.monkeyspaw.data.ImeActivityGuard
import ch.lkmc.monkeyspaw.data.ImeDeliveryGateway
import ch.lkmc.monkeyspaw.data.ImeTextDelivery
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.IoDispatcher
import ch.lkmc.monkeyspaw.entry.FillHandoff
import ch.lkmc.monkeyspaw.entry.FillHandoffLauncher
import ch.lkmc.monkeyspaw.entry.FillHandoffStore
import ch.lkmc.monkeyspaw.ui.fill.FillSession
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.fill.FillViewModelFactory
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import kotlinx.coroutines.CoroutineDispatcher
import javax.inject.Inject

/** Local index, shared Fill, delivery and one-use handoff only. */
internal class ImeLocalGraph @Inject constructor(
    private val repository: LibraryRepository,
    private val fillFactory: FillViewModelFactory,
    private val copy: CopyTextDelivery,
    private val activityGuard: ImeActivityGuard,
    private val handoffs: FillHandoffStore,
    @IoDispatcher private val worker: CoroutineDispatcher,
) {
    fun inFillActivity(): Boolean = activityGuard.inFillActivity

    fun launchHandoff(handoff: FillHandoff, launch: (String) -> Unit): Boolean =
        FillHandoffLauncher(handoffs, launch).open(handoff)

    fun createModels(root: ImeSessionRoot, session: FillSession, gateway: ImeDeliveryGateway): ImeModels {
        val owner = root as ImeViewOwners
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                val model = when (modelClass) {
                    LibraryViewModel::class.java -> LibraryViewModel(repository, worker)
                    FillViewModel::class.java -> fillFactory.create(session, ImeTextDelivery(gateway, session.isActive, copy))
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
