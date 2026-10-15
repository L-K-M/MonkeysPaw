package ch.lkmc.monkeyspaw.ime

import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.platform.createLifecycleAwareWindowRecomposer
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import ch.lkmc.monkeyspaw.data.AndroidImeGateway
import ch.lkmc.monkeyspaw.data.ImeSwitchBack
import ch.lkmc.monkeyspaw.entry.EntrySource
import ch.lkmc.monkeyspaw.entry.FillRoute
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

/** The exported binder is system-only. Opening this keyboard constructs only the local graph. */
@AndroidEntryPoint
class MonkeysPawImeService : InputMethodService() {
    @Inject internal lateinit var localGraph: ImeLocalGraph
    private val gateway by lazy { AndroidImeGateway(this, localGraph::inFillActivity) }
    private val switchBack by lazy { ImeSwitchBack(gateway) }
    private val sessions by lazy {
        ImeSessionController({ root, session -> localGraph.createModels(root, session, gateway) },
            gateway::editor, switchBack::switch, { handoff ->
                localGraph.launchHandoff(handoff) { token ->
                    startActivity(FillRoute(EntrySource.IME_HANDOFF, token).intent(this))
                }
            })
    }

    override fun onCreateInputView(): View {
        val view = ComposeView(this).apply {
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
        }
        val owners = ImeViewOwners(view::disposeComposition)
        owners.install(view)
        // The IME window's ancestors have no owners; each replacement needs its own recomposer.
        view.setParentCompositionContext(view.createLifecycleAwareWindowRecomposer(lifecycle = owners.lifecycle))
        sessions.replaceRoot(owners)
        owners.lifecycleScope.launch {
            owners.repeatOnLifecycle(Lifecycle.State.STARTED) {
                sessions.state.collectLatest { state ->
                    state.models?.fill?.state?.collect { sessions.fillChanged(state.generation) }
                }
            }
        }
        view.setContent {
            val state by sessions.state.collectAsState()
            val models = state.models
            val library = models?.library?.state?.collectAsStateWithLifecycle()?.value
            val fill = models?.fill?.state?.collectAsStateWithLifecycle()?.value
            val epoch = state.generation
            MaterialTheme {
                ImeScreen(state, library, fill,
                    onSwitch = { sessions.switch(epoch) },
                    onOpen = { sessions.open(epoch, it) },
                    onQuery = { sessions.query(epoch, it) },
                    onFilter = { sessions.filter(epoch, it) },
                    onSelect = { sessions.select(epoch, it) },
                    onClearFilters = { sessions.clearFilters(epoch) },
                    onRefresh = { sessions.refresh(epoch) },
                    onValue = { name, value -> sessions.value(epoch, name, value) },
                    onCopy = { sessions.copy(epoch) },
                    onInsert = { sessions.insert(epoch) },
                    onHandoff = { sessions.handoff(epoch) },
                    onCancel = { sessions.backToPicker(epoch) },
                    onRetry = { sessions.retry(epoch) })
            }
        }
        return view
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        sessions.startInput(gateway.editor(attribute))
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        sessions.show(gateway.editor(info))
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        if (finishingInput) sessions.finishInput() else sessions.hide()
        // The superclass finishes composing text; this picker never owns target composition.
    }

    override fun onWindowHidden() { sessions.hide() }
    override fun onFinishInput() { sessions.finishInput() }
    override fun onUnbindInput() { sessions.unbind() }

    override fun onDestroy() {
        sessions.destroy()
        super.onDestroy()
    }

    override fun onEvaluateFullscreenMode(): Boolean = false
    override fun onCreateExtractTextView(): View? = null
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
        candidatesStart: Int, candidatesEnd: Int) = Unit
}
