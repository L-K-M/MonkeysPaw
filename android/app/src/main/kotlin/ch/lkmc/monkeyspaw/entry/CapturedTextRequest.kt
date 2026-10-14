package ch.lkmc.monkeyspaw.entry

import android.content.Intent.ACTION_PROCESS_TEXT
import android.content.Intent.ACTION_SEND
import ch.lkmc.monkeyspaw.core.domain.Limits
import java.nio.charset.CharacterCodingException

/** A validated, plain-text snapshot, held only in the entry's in-memory session. */
internal class CapturedTextRequest private constructor(val source: Source, val text: String) {
    enum class Source { EDITABLE_SELECTION, READ_ONLY_SELECTION, SHARE }
    enum class Rejection(val message: String) {
        UNSUPPORTED_ACTION("Use a text-selection action or a plain-text share."),
        UNSUPPORTED_MIME("Share plain text only."),
        INVALID_TEXT("Supply captured text as a character sequence."),
        EMPTY_TEXT("Supply nonempty captured text."),
        TOO_LARGE("Captured text exceeds the UTF-8 byte limit."),
        INVALID_UNICODE("Supply well-formed Unicode text."),
    }
    class Rejected(val reason: Rejection) : Exception(reason.message)

    override fun toString(): String = "CapturedTextRequest(source=$source, text=<redacted>)"

    companion object {
        /** Intent adapters extract only these inputs; extra HTML, subjects, streams and URIs are ignored. */
        fun parse(action: String?, mimeType: String?, text: Any?, readOnly: Any? = null): CapturedTextRequest {
            val source = when (action) {
                ACTION_PROCESS_TEXT -> if (readOnly is Boolean && !readOnly) Source.EDITABLE_SELECTION else Source.READ_ONLY_SELECTION
                ACTION_SEND -> Source.SHARE
                else -> throw Rejected(Rejection.UNSUPPORTED_ACTION)
            }
            if (mimeType != "text/plain") throw Rejected(Rejection.UNSUPPORTED_MIME)
            if (text !is CharSequence) throw Rejected(Rejection.INVALID_TEXT)

            val plain = try {
                // UTF-8 cannot be smaller than the UTF-16 length; bound copying before stripping spans.
                if (text.length > Limits.capturedTextCapBytes) throw Rejected(Rejection.TOO_LARGE)
                text.toString()
            } catch (error: Rejected) {
                throw error
            } catch (_: Exception) {
                throw Rejected(Rejection.INVALID_TEXT)
            }
            if (plain.isEmpty()) throw Rejected(Rejection.EMPTY_TEXT)
            if (plain.length > Limits.capturedTextCapBytes) throw Rejected(Rejection.TOO_LARGE)
            val bytes = try {
                plain.encodeToByteArray(throwOnInvalidSequence = true)
            } catch (_: CharacterCodingException) {
                throw Rejected(Rejection.INVALID_UNICODE)
            }
            if (bytes.size > Limits.capturedTextCapBytes) throw Rejected(Rejection.TOO_LARGE)
            return CapturedTextRequest(source, plain)
        }
    }
}
