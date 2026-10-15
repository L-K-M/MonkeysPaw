package ch.lkmc.monkeyspaw.ui.assistant

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.services.AssistantAcceptanceOutcome
import ch.lkmc.monkeyspaw.core.services.AssistantPhase
import ch.lkmc.monkeyspaw.core.services.AssistantState
import ch.lkmc.monkeyspaw.core.services.AssistantMutationAccess

/** Inputs and results belong only to this in-memory route. */
internal data class ImproveUiState(
    val isOpen: Boolean = false,
    val loading: Boolean = false,
    val loadFailed: Boolean = false,
    val effort: AssistantEffort? = null,
    val feedback: String = "",
    val assistant: AssistantState? = null,
    val acceptanceOutcome: AssistantAcceptanceOutcome? = null,
    val unavailable: ReviewUnavailable? = null,
    val canImprove: Boolean = false,
    val canRetry: Boolean = false,
    val canShowDiff: Boolean = false,
    val canAccept: Boolean = false,
) {
    val isWorking: Boolean get() = assistant?.phase == AssistantPhase.WORKING
    val isAccepting: Boolean get() = assistant?.isAccepting == true
    val isPrivateCopy: Boolean get() = assistant?.mutationAccess == AssistantMutationAccess.PRIVATE_COPY
    val canEdit: Boolean get() = isOpen && !loading && assistant != null && !isWorking && !isAccepting
    override fun toString(): String = "<assistant improve state redacted>"
}
