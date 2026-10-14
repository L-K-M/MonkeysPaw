package ch.lkmc.monkeyspaw.ui.fill

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import ch.lkmc.monkeyspaw.core.ports.TextDelivery
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.data.CopyTextDelivery
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.entry.FillHandoff
import javax.inject.Inject

/** Activities and input-view owners construct the same model without saving form contents. */
internal class FillViewModelFactory @Inject constructor(
    private val repository: LibraryRepository,
    private val fill: FillService,
    private val copy: CopyTextDelivery,
) : ViewModelProvider.Factory {
    fun create(session: FillSession, endpoint: TextDelivery = copy): FillViewModel =
        FillViewModel(repository, fill, endpoint, session)

    fun restoreHandoff(model: FillViewModel, handoff: FillHandoff?) = model.restoreHandoff(handoff, copy)

    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass == FillViewModel::class.java)
        @Suppress("UNCHECKED_CAST")
        return create(FillSession()) as T
    }
}
