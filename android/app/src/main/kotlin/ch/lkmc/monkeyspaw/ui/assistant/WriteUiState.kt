package ch.lkmc.monkeyspaw.ui.assistant

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.services.AssistantAcceptanceOutcome
import ch.lkmc.monkeyspaw.core.services.AssistantPhase
import ch.lkmc.monkeyspaw.core.services.AssistantState

internal enum class AssistantUnavailable { PROVIDER, LIBRARY, ACCESS, BUSY, CONFLICT }

/** Session-only inputs and results. Never serialize this state or put it in saved state. */
internal data class WriteUiState(
    val isOpen: Boolean = false,
    val loading: Boolean = false,
    val loadFailed: Boolean = false,
    val brief: String = "",
    val feedback: String = "",
    val effort: AssistantEffort? = null,
    val assistant: AssistantState? = null,
    val acceptanceOutcome: AssistantAcceptanceOutcome? = null,
    val unavailable: AssistantUnavailable? = null,
    val canWrite: Boolean = false,
    val canRetry: Boolean = false,
    val canShowDiff: Boolean = false,
    val canAccept: Boolean = false,
) {
    val isWorking: Boolean get() = assistant?.phase == AssistantPhase.WORKING
    val isAccepting: Boolean get() = assistant?.isAccepting == true
    val canEdit: Boolean get() = isOpen && !isWorking && !isAccepting
    override fun toString(): String = "<assistant write state redacted>"
}
