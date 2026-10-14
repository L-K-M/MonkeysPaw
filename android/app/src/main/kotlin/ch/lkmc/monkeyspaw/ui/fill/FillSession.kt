package ch.lkmc.monkeyspaw.ui.fill

import ch.lkmc.monkeyspaw.core.ports.DeliveryMode
import ch.lkmc.monkeyspaw.core.ports.LearningPolicy
import ch.lkmc.monkeyspaw.entry.CapturedTextRequest

internal enum class FillInput { EDITABLE, INLINE }

/** The host owns session validity. No framework connection or saved-state payload belongs here. */
internal class FillSession(
    val mode: DeliveryMode = DeliveryMode.COPY,
    val learning: LearningPolicy = LearningPolicy.NORMAL,
    val capture: CapturedTextRequest? = null,
    val input: FillInput = FillInput.EDITABLE,
    val isActive: () -> Boolean = { true },
)
