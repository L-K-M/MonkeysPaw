package ch.lkmc.monkeyspaw.core.domain.library

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.StorePath
import com.ibm.icu.text.BreakIterator
import java.time.Instant
import java.util.Locale

/** A title supplies a filename, never a directory or an ignored prompt. */
object PromptCreation {
    fun relativePath(title: String, now: Instant): String {
        val cleaned = buildString {
            title.codePoints().forEach { scalar ->
                if (scalar == '/'.code || scalar == '\\'.code || UnicodeText.isControlOrFormat(scalar)) append(' ')
                else appendCodePoint(scalar)
            }
        }
        val name = cleaned.trim { it == '.' || it == '_' || it.isWhitespace() || Character.isSpaceChar(it) }
        val path = "$name.md"
        if (name.isNotEmpty() && path != "README.md" && path.toByteArray(Charsets.UTF_8).size <= Limits.promptFilenameMaxBytes) {
            try { StorePath.validate(path); return path } catch (_: StoreError) { /* Use the bounded fallback. */ }
        }
        return "Prompt ${now.epochSecond}.md"
    }

    internal fun copyFilename(stem: String, suffix: Int): String {
        val ending = " $suffix.md"
        var remaining = Limits.promptFilenameMaxBytes - ending.toByteArray(Charsets.UTF_8).size
        val boundaries = BreakIterator.getCharacterInstance(Locale.ROOT).apply { setText(stem) }
        var end = boundaries.first()
        var next = boundaries.next()
        while (next != BreakIterator.DONE) {
            val count = stem.substring(end, next).toByteArray(Charsets.UTF_8).size
            if (count > remaining) break
            remaining -= count
            end = next
            next = boundaries.next()
        }
        return stem.substring(0, end) + ending
    }
}
