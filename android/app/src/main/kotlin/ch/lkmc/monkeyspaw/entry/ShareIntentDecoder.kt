package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.content.Intent.ACTION_SEND
import android.content.Intent.EXTRA_TEXT

/** Shared text is capture only; no sender routes, attachments or metadata are consumed. */
internal object ShareIntentDecoder {
    fun read(intent: Intent): CapturedTextRequest? = try {
        decode(intent.action, intent.type) { key ->
            // Raw access avoids typed-getter coercion and diagnostics containing untrusted content.
            @Suppress("DEPRECATION")
            intent.extras?.get(key)
        }
    } catch (_: RuntimeException) {
        null
    }

    /** Pure extraction seam: real Intent/Bundle and span handling remain device checks. */
    fun decode(action: String?, mimeType: String?, extra: (String) -> Any?): CapturedTextRequest? {
        if (action != ACTION_SEND || mimeType != "text/plain") return null
        return try {
            CapturedTextRequest.parse(action, mimeType, extra(EXTRA_TEXT))
        } catch (_: Exception) {
            null
        }
    }
}
