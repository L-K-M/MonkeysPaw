package ch.lkmc.monkeyspaw.ime

import android.view.View
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner

/** The tested transition sequence is separate from Android's unexecutable JVM owner stubs. */
internal class ImeViewLifecycle(
    private val event: (Lifecycle.Event) -> Unit,
    private val clear: () -> Unit,
    private val dispose: () -> Unit,
) {
    private var shown = false
    private var destroyed = false

    init { event(Lifecycle.Event.ON_CREATE) }

    fun show() {
        if (destroyed || shown) return
        shown = true
        event(Lifecycle.Event.ON_START)
        event(Lifecycle.Event.ON_RESUME)
    }

    fun hide() {
        if (destroyed || !shown) return
        shown = false
        event(Lifecycle.Event.ON_PAUSE)
        event(Lifecycle.Event.ON_STOP)
    }

    fun destroy() {
        if (destroyed) return
        hide()
        destroyed = true
        event(Lifecycle.Event.ON_DESTROY)
        clear()
        dispose()
    }
}

/** One owner per input root. Saved state exists for Compose attachment, never for a form payload. */
internal class ImeViewOwners(disposeComposition: () -> Unit) : LifecycleOwner, ViewModelStoreOwner,
    SavedStateRegistryOwner, ImeSessionRoot {
    private val registry = LifecycleRegistry(this)
    private val savedState = SavedStateRegistryController.create(this)
    override val lifecycle: Lifecycle get() = registry
    override val viewModelStore = ViewModelStore()
    override val savedStateRegistry: SavedStateRegistry get() = savedState.savedStateRegistry
    private val transitions: ImeViewLifecycle

    init {
        savedState.performAttach()
        savedState.performRestore(null)
        transitions = ImeViewLifecycle(registry::handleLifecycleEvent, viewModelStore::clear, disposeComposition)
    }

    fun install(view: View) {
        view.setViewTreeLifecycleOwner(this)
        view.setViewTreeViewModelStoreOwner(this)
        view.setViewTreeSavedStateRegistryOwner(this)
    }

    override fun show() = transitions.show()
    override fun hide() = transitions.hide()
    override fun clearModels() = viewModelStore.clear()
    override fun destroy() = transitions.destroy()
}
