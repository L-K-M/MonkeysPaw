package ch.lkmc.monkeyspaw.ui.assistant

import ch.lkmc.monkeyspaw.core.services.AssistantContext
import ch.lkmc.monkeyspaw.core.services.AssistantSession
import ch.lkmc.monkeyspaw.di.AssistantGraph
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import kotlinx.coroutines.CoroutineScope

/** Shared native composition for Write, Review and Improve. All callbacks run on UI. */
internal class AssistantSessionBinding(
    private val graph: AssistantGraph,
    val editor: EditorViewModel,
    private val providers: AssistantProviderChanges,
    scope: CoroutineScope,
    private val onContextChange: () -> Unit,
) {
    fun context(): AssistantContext {
        val snapshot = editor.assistantSnapshot
        return AssistantContext(graph.id, graph.service.selectedProfile, snapshot,
            graph.access.current(snapshot?.relativePath), providers.generation.value)
    }

    val session = AssistantSession(graph.service, scope, ::context, graph.clock)
    private val editorObserver = editor.addAssistantContextObserver(::contextChanged)
    private val providerObserver = providers.addObserver {
        session.profileChanged()
        onContextChange()
    }

    /** The graph/access owner also forwards transitions here when its authority changes. */
    fun contextChanged() {
        session.contextChanged()
        onContextChange()
    }

    fun deactivate() {
        editor.removeAssistantContextObserver(editorObserver)
        providers.removeObserver(providerObserver)
        session.deactivate()
    }

    override fun toString(): String = "<assistant binding redacted>"
}
