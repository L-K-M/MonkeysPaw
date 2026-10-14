package ch.lkmc.monkeyspaw.ui.fill

import ch.lkmc.monkeyspaw.core.domain.format.PromptField
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.services.FillPreview

internal data class FillFieldState(val field: PromptField, val value: String)

internal enum class FillPhase { PICKING, LOADING, EDITING, COPYING, COPIED, FAILED, CLOSED }
internal enum class FillFailure { LOAD, SNAPSHOT, CLIPBOARD }
internal enum class FillWarning { REMEMBERED_VALUES_UNAVAILABLE, REMEMBERED_VALUES_NOT_SAVED, USAGE_NOT_SAVED }

internal data class FillUiState(
    val phase: FillPhase = FillPhase.PICKING,
    val foreground: Boolean = false,
    val title: String = "",
    val description: String? = null,
    val fields: List<FillFieldState> = emptyList(),
    val issues: List<PromptIssue> = emptyList(),
    val canRender: Boolean = false,
    val isReadOnly: Boolean = false,
    val builtinsResolved: Boolean = false,
    val preview: FillPreview? = null,
    val failure: FillFailure? = null,
    val warnings: List<FillWarning> = emptyList(),
) {
    val values: Map<String, String> get() = fields.associate { it.field.name to it.value }
    val copyEnabled: Boolean get() = phase == FillPhase.EDITING && foreground && builtinsResolved &&
        canRender && preview is FillPreview.Rendered
    val cancelEnabled: Boolean get() = phase != FillPhase.COPYING && phase != FillPhase.CLOSED
    val shouldFinish: Boolean get() = phase == FillPhase.CLOSED || (phase == FillPhase.COPIED && warnings.isEmpty())
}
