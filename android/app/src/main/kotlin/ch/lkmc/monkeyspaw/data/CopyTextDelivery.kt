package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*
import javax.inject.Inject

/** Uses the existing sensitive-clipboard driver; insertion endpoints are supplied by their host. */
internal class CopyTextDelivery @Inject constructor(private val clipboard: Clipboard) : TextDelivery {
    override fun deliver(mode: DeliveryMode, text: String): TextDeliveryResult {
        if (mode != DeliveryMode.COPY) return TextDeliveryResult.REFUSED
        clipboard.writeText(text)
        return TextDeliveryResult.ACCEPTED
    }
}
