package ch.lkmc.monkeyspaw.ui.assistant

import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantEffort
import ch.lkmc.monkeyspaw.core.services.AssistantPhase
import ch.lkmc.monkeyspaw.core.services.AssistantState

internal enum class ReviewUnavailable { PROVIDER, LIBRARY, ACCESS, BUSY, CONFLICT, SOURCE, READ_ONLY, INVALID, PRIVATE, VALIDATING }
internal enum class ReviewDestination { FINDINGS, EDITOR, IMPROVE }

/** In-memory route and selection state; L19 continues the same review session for Improve. */
internal data class ReviewUiState(
    val isOpen: Boolean = false,
    val destination: ReviewDestination = ReviewDestination.FINDINGS,
    val loading: Boolean = false,
    val loadFailed: Boolean = false,
    val effort: AssistantEffort? = null,
    val feedback: String = "",
    val assistant: AssistantState? = null,
    val localIssues: List<PromptIssue> = emptyList(),
    val unavailable: ReviewUnavailable? = null,
    val canReview: Boolean = false,
    val canRetry: Boolean = false,
    val canSelectFindings: Boolean = false,
    val canImproveWithThese: Boolean = false,
) {
    val isWorking: Boolean get() = assistant?.phase == AssistantPhase.WORKING
    override fun toString(): String = "<assistant review state redacted>"
}
