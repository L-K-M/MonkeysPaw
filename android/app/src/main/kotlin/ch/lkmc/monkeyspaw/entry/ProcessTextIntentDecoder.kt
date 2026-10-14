package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.content.Intent.ACTION_PROCESS_TEXT
import android.content.Intent.EXTRA_PROCESS_TEXT
import android.content.Intent.EXTRA_PROCESS_TEXT_READONLY

/** Reads only the selection contract; caller extras never become Fill routes or result intents. */
internal object ProcessTextIntentDecoder {
    fun read(intent: Intent): CapturedTextRequest? = try {
        decode(intent.action, intent.type) { key ->
            // Typed Bundle getters can coerce/default mistyped values and log their contents.
            @Suppress("DEPRECATION")
            intent.extras?.get(key)
        }
    } catch (_: RuntimeException) {
        null
    }

    /** Pure extraction seam: JVM tests cannot execute Android's Intent/Bundle stubs. */
    fun decode(action: String?, mimeType: String?, extra: (String) -> Any?): CapturedTextRequest? {
        if (action != ACTION_PROCESS_TEXT || mimeType != "text/plain") return null
        return try {
            CapturedTextRequest.parse(action, mimeType, extra(EXTRA_PROCESS_TEXT), extra(EXTRA_PROCESS_TEXT_READONLY))
        } catch (_: Exception) {
            null
        }
    }
}
