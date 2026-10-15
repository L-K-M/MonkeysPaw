package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.DeliveryMode
import ch.lkmc.monkeyspaw.core.ports.TextDelivery
import ch.lkmc.monkeyspaw.core.ports.TextDeliveryResult
import ch.lkmc.monkeyspaw.ime.ImeEditor
import ch.lkmc.monkeyspaw.ime.ImeInputPolicy

/** The gateway exposes metadata/identity and one write, never target text or editor actions. */
internal interface ImeDeliveryGateway {
    fun editor(): ImeEditor
    fun commitText(editor: ImeEditor, text: String, newCursorPosition: Int): Boolean?
}

/** One endpoint per Fill session. A rejected commit leaves only explicit Copy available. */
internal class ImeTextDelivery(
    private val gateway: ImeDeliveryGateway,
    private val isActive: () -> Boolean,
    private val copy: TextDelivery,
) : TextDelivery {
    private enum class Attempt { READY, RUNNING, COPY_INSTEAD, ACCEPTED }
    private var attempt = Attempt.READY

    override fun deliver(mode: DeliveryMode, text: String): TextDeliveryResult {
        if (!isActive()) return TextDeliveryResult.STALE
        if (attempt == Attempt.RUNNING || attempt == Attempt.ACCEPTED) return TextDeliveryResult.REFUSED
        val editor = gateway.editor()
        if (!isActive()) return TextDeliveryResult.STALE
        val policy = ImeInputPolicy.classify(editor.inputType, editor.imeOptions)
        if (!policy.promptsAllowed || editor.inFillActivity) return TextDeliveryResult.REFUSED

        if (mode == DeliveryMode.COPY) {
            val previous = attempt
            attempt = Attempt.RUNNING
            val result = try { copy.deliver(mode, text) } catch (_: Exception) { TextDeliveryResult.REFUSED }
            attempt = if (result == TextDeliveryResult.ACCEPTED) Attempt.ACCEPTED else previous
            return result
        }
        if (mode != DeliveryMode.IME_COMMIT || attempt != Attempt.READY) return TextDeliveryResult.REFUSED
        if (policy.decide(text, editor.connectionReady) != ImeInputPolicy.Decision.INSERT) return TextDeliveryResult.REFUSED

        // Latch before the platform call: false/throw may still have changed the remote editor.
        attempt = Attempt.RUNNING
        val accepted = try { gateway.commitText(editor, text, 1) == true } catch (_: Exception) { false }
        attempt = if (accepted) Attempt.ACCEPTED else Attempt.COPY_INSTEAD
        if (accepted) return TextDeliveryResult.ACCEPTED
        return if (isActive()) TextDeliveryResult.REFUSED else TextDeliveryResult.STALE
    }
}
