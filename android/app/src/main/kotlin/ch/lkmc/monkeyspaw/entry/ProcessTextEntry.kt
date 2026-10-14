package ch.lkmc.monkeyspaw.entry

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.DeliveryMode
import ch.lkmc.monkeyspaw.core.ports.TextDelivery
import ch.lkmc.monkeyspaw.data.SelectionResultDelivery
import ch.lkmc.monkeyspaw.ui.fill.FillPhase
import ch.lkmc.monkeyspaw.ui.fill.FillSession
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Retains the shared form across recreation, with no activity, capture or result in saved state. */
internal class ProcessTextEntry(
    private val createFill: (FillSession, TextDelivery) -> FillViewModel,
    private val copy: TextDelivery,
) : ViewModel() {
    private class Host(val owner: Any, val result: (String?) -> Unit)
    private var models = ViewModelStore()
    private val mutableForm = MutableStateFlow<FillViewModel?>(null)
    val form = mutableForm.asStateFlow()
    private var host: Host? = null
    private var foreground = false
    private var generation = 0L
    private var closed = false
    private var acceptedText: String? = null
    var initialized = false
        private set

    /** Null rejects invalid input or process loss before constructing any form. */
    fun start(request: CapturedTextRequest?) {
        if (closed) return
        initialized = true
        val epoch = ++generation
        acceptedText = null
        host?.result?.invoke(null)
        val previous = mutableForm.value
        val previousModels = models
        models = ViewModelStore()
        val next = if (request == null || request.source == CapturedTextRequest.Source.SHARE) null
            else createForm(request, epoch)
        // Publish the replacement before retiring the old form; its CLOSED reply cannot finish us.
        mutableForm.value = next
        previous?.endSession()
        previousModels.clear()
        next?.setForeground(foreground)
    }

    private fun createForm(request: CapturedTextRequest, epoch: Long): FillViewModel {
        val mode = if (request.source == CapturedTextRequest.Source.EDITABLE_SELECTION) {
            DeliveryMode.SELECTION_RESULT
        } else DeliveryMode.COPY
        val session = FillSession(mode = mode, capture = request, isActive = { !closed && epoch == generation })
        val endpoint = SelectionResultDelivery(mode, copy, isActive = {
            !closed && epoch == generation && foreground && host != null &&
                mutableForm.value != null && mutableForm.value?.state?.value?.phase != FillPhase.CLOSED
        }) { text ->
            val receiver = checkNotNull(host)
            receiver.result(text)
            // A reentrant new entry must not inherit the previous caller's accepted output.
            if (!closed && epoch == generation) acceptedText = text
        }
        return ViewModelProvider(models, object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                require(modelClass == FillViewModel::class.java)
                @Suppress("UNCHECKED_CAST")
                return createFill(session, endpoint) as T
            }
        })[FillViewModel::class.java]
    }

    /** Reapply a staged result after rotation, without another delivery or learning operation. */
    fun attach(owner: Any, result: (String?) -> Unit) {
        if (closed) return
        foreground = false
        mutableForm.value?.setForeground(false)
        host = Host(owner, result)
        result(acceptedText)
    }

    fun setForeground(owner: Any, visible: Boolean) {
        if (host?.owner !== owner) return
        foreground = visible
        mutableForm.value?.setForeground(visible)
    }

    fun detach(owner: Any) {
        if (host?.owner !== owner) return
        setForeground(owner, false)
        host = null
    }

    fun close() {
        if (closed) return
        closed = true
        generation++
        foreground = false
        host = null
        acceptedText = null
        mutableForm.value?.endSession()
        models.clear()
        mutableForm.value = null
    }

    override fun onCleared() = close()
}
