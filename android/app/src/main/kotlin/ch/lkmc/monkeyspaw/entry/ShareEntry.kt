package ch.lkmc.monkeyspaw.entry

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.DeliveryMode
import ch.lkmc.monkeyspaw.core.ports.TextDelivery
import ch.lkmc.monkeyspaw.core.ports.TextDeliveryResult
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import ch.lkmc.monkeyspaw.ui.fill.FillSession
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal sealed interface ShareDestination {
    data object Choosing : ShareDestination
    class Filling(val form: FillViewModel) : ShareDestination
    class Editing(val editor: EditorViewModel) : ShareDestination
    data object Closed : ShareDestination
}

/** The chooser, capture and drafts survive rotation only in memory, never in saved state. */
internal class ShareEntry(
    private val createFill: (FillSession, TextDelivery) -> FillViewModel,
    private val copy: TextDelivery,
    private val editorFactory: ViewModelProvider.Factory,
) : ViewModel() {
    private val mutableDestination = MutableStateFlow<ShareDestination>(ShareDestination.Closed)
    val destination = mutableDestination.asStateFlow()
    private var models = ViewModelStore()
    private var capture: CapturedTextRequest? = null
    private var owner: Any? = null
    private var foreground = false
    private var generation = 0L
    private var closed = false
    var initialized = false
        private set

    /** A replacement always retires the old form before it can affect the new share. */
    fun start(request: CapturedTextRequest?) {
        if (closed) return
        initialized = true
        generation++
        capture = request?.takeIf { it.source == CapturedTextRequest.Source.SHARE }
        val previous = mutableDestination.value
        val previousModels = models
        models = ViewModelStore()
        // Publish first: old CLOSED callbacks must not finish the replacement entry.
        mutableDestination.value = if (capture == null) ShareDestination.Closed else ShareDestination.Choosing
        (previous as? ShareDestination.Filling)?.form?.endSession()
        previousModels.clear()
    }

    fun useInPrompt() {
        if (closed || destination.value != ShareDestination.Choosing) return
        val request = capture ?: return
        val epoch = generation
        val session = FillSession(mode = DeliveryMode.COPY, capture = request,
            isActive = { !closed && epoch == generation })
        val endpoint = TextDelivery { mode, text ->
            if (closed || epoch != generation || !foreground || owner == null ||
                destination.value !is ShareDestination.Filling) TextDeliveryResult.STALE
            else if (mode != DeliveryMode.COPY) TextDeliveryResult.REFUSED
            else copy.deliver(mode, text)
        }
        val form = ViewModelProvider(models, object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                require(modelClass == FillViewModel::class.java)
                @Suppress("UNCHECKED_CAST")
                return createFill(session, endpoint) as T
            }
        })[FillViewModel::class.java]
        capture = null
        mutableDestination.value = ShareDestination.Filling(form)
        form.setForeground(foreground)
    }

    fun saveAsNewPrompt() {
        if (closed || destination.value != ShareDestination.Choosing) return
        val request = capture ?: return
        val editor = ViewModelProvider(models, editorFactory)[EditorViewModel::class.java]
        editor.createDraft()
        // An empty header keeps a shared leading YAML fence in the body, not in metadata.
        editor.edit("---\n---\n" + request.text)
        capture = null
        mutableDestination.value = ShareDestination.Editing(editor)
    }

    fun attach(owner: Any) {
        if (closed) return
        foreground = false
        (destination.value as? ShareDestination.Filling)?.form?.setForeground(false)
        this.owner = owner
    }

    fun setForeground(owner: Any, visible: Boolean) {
        if (this.owner !== owner) return
        foreground = visible
        (destination.value as? ShareDestination.Filling)?.form?.setForeground(visible)
    }

    fun detach(owner: Any) {
        if (this.owner !== owner) return
        setForeground(owner, false)
        this.owner = null
    }

    fun back() {
        when (val current = destination.value) {
            is ShareDestination.Filling -> current.form.cancel()
            is ShareDestination.Editing -> current.editor.close()
            else -> close()
        }
    }

    fun close() {
        if (closed) return
        closed = true
        generation++
        capture = null
        owner = null
        foreground = false
        val previous = destination.value
        mutableDestination.value = ShareDestination.Closed
        (previous as? ShareDestination.Filling)?.form?.endSession()
        models.clear()
    }

    override fun onCleared() = close()
}
