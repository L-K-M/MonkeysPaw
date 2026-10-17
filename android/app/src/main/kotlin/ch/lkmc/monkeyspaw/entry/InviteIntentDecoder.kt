package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.os.Bundle
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue

/** Only ACTION_VIEW data reaches Account's portable validator. Caller extras are never read. */
internal object InviteIntentDecoder {
    fun consume(intent: Intent, restored: Boolean = false): SecretValue? = try {
        decode(intent.action, intent.dataString, restored)
    } catch (_: RuntimeException) {
        null
    } finally {
        intent.data = null
        intent.clipData = null
        intent.selector = null
        intent.replaceExtras(null as Bundle?)
    }

    /** Intent stubs cannot execute on the JVM. A restored process must not replay a launch link. */
    fun decode(action: String?, data: String?, restored: Boolean = false): SecretValue? {
        if (restored || action != Intent.ACTION_VIEW) return null
        // Bare tokens belong to the explicitly selected server in the Account form, never a VIEW route.
        return SecretValue(data?.takeIf { it.startsWith("monkeyspaw://", ignoreCase = true) }.orEmpty())
    }
}
