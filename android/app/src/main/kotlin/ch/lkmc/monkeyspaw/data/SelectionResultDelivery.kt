package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*

/** One selection session; Copy is explicit and an accepted replacement never touches the clipboard. */
internal class SelectionResultDelivery(
    private val selectionMode: DeliveryMode,
    private val copy: TextDelivery,
    private val isActive: () -> Boolean,
    private val returnSelection: (String) -> Unit,
) : TextDelivery {
    private enum class State { READY, DELIVERING, ACCEPTED }
    private var state = State.READY

    override fun deliver(mode: DeliveryMode, text: String): TextDeliveryResult {
        if (!isActive()) return TextDeliveryResult.STALE
        if (state != State.READY) return TextDeliveryResult.REFUSED
        state = State.DELIVERING
        val result = try {
            when (mode) {
                DeliveryMode.COPY -> copy.deliver(mode, text)
                DeliveryMode.SELECTION_RESULT -> if (selectionMode == mode) {
                    returnSelection(text)
                    TextDeliveryResult.ACCEPTED
                } else TextDeliveryResult.REFUSED
                DeliveryMode.IME_COMMIT -> TextDeliveryResult.REFUSED
            }
        } catch (_: Exception) {
            TextDeliveryResult.REFUSED
        }
        state = if (result == TextDeliveryResult.ACCEPTED) State.ACCEPTED else State.READY
        return result
    }
}
