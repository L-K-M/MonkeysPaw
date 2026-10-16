package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import ch.lkmc.monkeyspaw.core.domain.sync.SyncHash
import ch.lkmc.monkeyspaw.core.domain.sync.SyncIdentifiers
import ch.lkmc.monkeyspaw.core.ports.StorePath
import ch.lkmc.monkeyspaw.core.services.LibraryPath
import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UCharacterCategory
import com.ibm.icu.text.BreakIterator
import com.ibm.icu.util.ULocale
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

internal sealed class SyncNamingError private constructor() : Exception("Sync naming failed.", null, false, true) {
    data object InvalidPath : SyncNamingError()
    data object InvalidDate : SyncNamingError()
    data object Exhausted : SyncNamingError()
    final override fun toString(): String = "<sync naming error>"
}

/** Separate from editor/import copy names; every private destination fits the wire path cap. */
internal object SyncNaming {
    fun groupFolder(name: String, occupied: Collection<String>): String {
        val stem = component(name, "Group", Limits.syncPathSegmentMaxBytes)
        val keys = occupied.map(::pathKey).toSet()
        // Truncation can make the bare stem equal a numbered candidate.
        for (number in 1..keys.size + 2) {
            val suffix = if (number == 1) "" else " ($number)"
            val shortened = prefix(stem, Limits.syncPathSegmentMaxBytes - byteCount(suffix)).trim(' ', '.')
            val folder = shortened.ifEmpty { "Group" } + suffix
            SyncIdentifiers.folder(folder)
            if (pathKey(folder) !in keys) return folder
        }
        throw SyncNamingError.Exhausted
    }

    fun pathKey(path: String): String = try {
        StorePath.validate(path)
        UnicodeText.nfc(SyncPathCaseFold.fold(UnicodeText.nfc(path)))
    } catch (_: Exception) { throw SyncNamingError.InvalidPath }

    fun clash(path: String, scope: SyncPathValidator.Scope, occupiedPaths: Collection<String>): String {
        val checked = SyncPathValidator.validate(path, scope)
        val (parent, name) = split(checked.path)
        var stem = name.dropLast(3)
        var first = 2
        for (number in 2..Limits.syncPathClashMax) {
            val suffix = " ($number)"
            if (!stem.endsWith(suffix)) continue
            stem = stem.dropLast(suffix.length)
            first = number + 1
            break
        }
        if (first > Limits.syncPathClashMax) throw SyncNamingError.Exhausted
        val occupied = occupiedPaths.map(::pathKey).toSet()
        for (number in first..Limits.syncPathClashMax) {
            val candidate = SyncPathValidator.validate(filename(stem, " ($number).md", parent), scope)
            if (candidate.pathKey !in occupied) return candidate.path
        }
        throw SyncNamingError.Exhausted
    }

    fun conflict(source: String, groupFolder: String?, device: String, at: Instant, occupiedPaths: Collection<String>): String {
        val group = component(groupFolder ?: "Personal", "Personal", Limits.syncPathSegmentMaxBytes)
        val deviceText = scalars(device) { if (deviceScalar(it)) it else '-'.code }
        val safeDevice = component(deviceText, "Device", Limits.syncConflictDeviceMaxBytes)
        val stamp = utc(at, "yyyy-MM-dd HHmm")
        val name = split(source).second
        val stem = component(name.removeSuffix(".md"), "Prompt", Limits.syncPathSegmentMaxBytes)
        return available(stem, " (conflict $safeDevice $stamp).md", "Conflicts/$group/", occupiedPaths)
    }

    fun rescue(source: String, at: Instant, occupiedPaths: Collection<String>): String {
        StorePath.validate(source)
        val parent = "Conflicts/rescued-${utc(at, "yyyy-MM-dd")}/"
        val hierarchical = parent + source
        val checked = runCatching { SyncPathValidator.validate(hierarchical, SyncPathValidator.Scope.USER) }.getOrNull()
        if (checked?.path == hierarchical && LibraryPath.isPrompt(hierarchical) &&
            Limits.maxPathBytes - byteCount(split(hierarchical).first) > byteCount(" (20).md")) {
            return available(hierarchical, occupiedPaths)
        }
        val stem = component(split(source).second.removeSuffix(".md"), "Prompt", Limits.syncPathSegmentMaxBytes)
        val hash = SyncHash.of(source.encodeToByteArray(throwOnInvalidSequence = true)).rawValue.take(Limits.syncRescuePathHashLength)
        return available(stem, " ($hash).md", parent, occupiedPaths)
    }

    private fun available(path: String, occupiedPaths: Collection<String>): String {
        val checked = SyncPathValidator.validate(path, SyncPathValidator.Scope.USER)
        if (checked.pathKey !in occupiedPaths.map(::pathKey).toSet()) return path
        return clash(path, SyncPathValidator.Scope.USER, occupiedPaths)
    }

    private fun available(stem: String, suffix: String, parent: String, occupiedPaths: Collection<String>): String {
        val occupied = occupiedPaths.map(::pathKey).toSet()
        for (number in 1..Limits.syncPathClashMax) {
            val ending = if (number == 1) suffix else suffix.dropLast(3) + " ($number).md"
            val candidate = SyncPathValidator.validate(filename(stem, ending, parent), SyncPathValidator.Scope.USER)
            if (candidate.pathKey !in occupied) return candidate.path
        }
        throw SyncNamingError.Exhausted
    }

    private fun filename(stem: String, suffix: String, parent: String): String {
        val budget = minOf(Limits.syncPathSegmentMaxBytes, Limits.maxPathBytes - byteCount(parent)) - byteCount(suffix)
        if (budget <= 0) throw SyncNamingError.Exhausted
        val name = prefix(stem, budget).ifEmpty { prefix("Prompt", budget) }
        return parent + name + suffix
    }

    private fun component(text: String, fallback: String, maxBytes: Int): String {
        val nfc = try { UnicodeText.nfc(text) } catch (_: Exception) { throw SyncNamingError.InvalidPath }
        val sanitized = scalars(nfc) { if (UnicodeText.isControlOrFormat(it) || it == '/'.code || it == '\\'.code) '-'.code else it }
            .trim(' ', '.', '-', '_')
        return prefix(sanitized, maxBytes).trim(' ', '.', '-', '_').ifEmpty { fallback }
    }

    /** ICU's extended grapheme boundaries keep marks, emoji modifiers and flags whole. */
    private fun prefix(text: String, maxBytes: Int): String {
        val iterator = BreakIterator.getCharacterInstance(ULocale.ROOT)
        iterator.setText(text)
        var end = iterator.first()
        var count = 0
        var next = iterator.next()
        while (next != BreakIterator.DONE) {
            val size = byteCount(text.substring(end, next))
            if (count + size > maxBytes) break
            count += size
            end = next
            next = iterator.next()
        }
        return text.substring(0, end)
    }

    private fun deviceScalar(scalar: Int): Boolean = when (UCharacter.getType(scalar)) {
        UCharacterCategory.UPPERCASE_LETTER.toInt(), UCharacterCategory.LOWERCASE_LETTER.toInt(),
        UCharacterCategory.TITLECASE_LETTER.toInt(), UCharacterCategory.MODIFIER_LETTER.toInt(),
        UCharacterCategory.OTHER_LETTER.toInt(), UCharacterCategory.NON_SPACING_MARK.toInt(),
        UCharacterCategory.COMBINING_SPACING_MARK.toInt(), UCharacterCategory.ENCLOSING_MARK.toInt(),
        UCharacterCategory.DECIMAL_DIGIT_NUMBER.toInt(), UCharacterCategory.LETTER_NUMBER.toInt(),
        UCharacterCategory.OTHER_NUMBER.toInt() -> true
        else -> scalar == ' '.code || scalar == '-'.code || scalar == '_'.code
    }

    private fun scalars(text: String, transform: (Int) -> Int): String {
        if (text.codePoints().anyMatch { it in 0xD800..0xDFFF }) throw SyncNamingError.InvalidPath
        return buildString { text.codePoints().forEach { appendCodePoint(transform(it)) } }
    }

    private fun split(path: String): Pair<String, String> {
        val slash = path.lastIndexOf('/')
        return path.substring(0, slash + 1) to path.substring(slash + 1)
    }

    private fun byteCount(text: String): Int = text.encodeToByteArray(throwOnInvalidSequence = true).size

    private fun utc(at: Instant, format: String): String {
        if (at.epochSecond < 0 || at.epochSecond >= Limits.historyMaxUnixSeconds) throw SyncNamingError.InvalidDate
        return DateTimeFormatter.ofPattern(format, Locale.US).withZone(ZoneOffset.UTC).format(at)
    }
}
