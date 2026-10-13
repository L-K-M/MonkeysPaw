package ch.lkmc.monkeyspaw.core.domain.paths

/** Checked sync spelling and per-scope key. Local filesystem paths retain their original bytes. */
@ConsistentCopyVisibility
data class SyncPath internal constructor(val path: String, val pathKey: String)

object SyncPathValidator {
    enum class Scope { USER, GROUP }

    private const val MAX_PATH_BYTES = 1_024
    private const val SEGMENT_MAX_BYTES = 255

    /** First failure wins. Limits apply to NFC path bytes, never to the expanded folded key. */
    fun validate(input: String, scope: Scope): SyncPath {
        if (input.isEmpty()) throw SyncPathIssue(SyncPathIssueCode.EMPTY_PATH)
        val path = nfc(input)
        val bytes = path.toByteArray(Charsets.UTF_8)
        if (bytes.firstOrNull() == 47.toByte()) throw SyncPathIssue(SyncPathIssueCode.ABSOLUTE_PATH)
        if (bytes.size > MAX_PATH_BYTES) throw SyncPathIssue(SyncPathIssueCode.PATH_TOO_LONG)

        val segments = UnicodeText.slashSegments(bytes)
        for ((index, segment) in segments.withIndex()) {
            fun fail(code: SyncPathIssueCode): Nothing = throw SyncPathIssue(code, index)

            if (segment.isEmpty()) fail(SyncPathIssueCode.EMPTY_SEGMENT)
            if (segment.contentEquals(byteArrayOf(46)) || segment.contentEquals(byteArrayOf(46, 46))) {
                fail(SyncPathIssueCode.DOT_SEGMENT)
            }
            if (index != segments.lastIndex && segment.first() == 46.toByte()) {
                fail(SyncPathIssueCode.HIDDEN_DIRECTORY)
            }
            if (segment.contains(92.toByte())) fail(SyncPathIssueCode.BACKSLASH)
            if (segment.toString(Charsets.UTF_8).codePoints().anyMatch(UnicodeText::isControlOrFormat)) {
                fail(SyncPathIssueCode.CONTROL_CHARACTER)
            }
            if (segment.last() == 46.toByte() || segment.last() == 32.toByte()) {
                fail(SyncPathIssueCode.TRAILING_DOT_OR_SPACE)
            }
            if (segment.size > SEGMENT_MAX_BYTES) fail(SyncPathIssueCode.SEGMENT_TOO_LONG)
        }

        if (!path.endsWith(".md")) throw SyncPathIssue(SyncPathIssueCode.INVALID_EXTENSION)
        val key = nfc(SyncPathCaseFold.fold(path))
        if (scope == Scope.USER && key.startsWith("groups/")) {
            throw SyncPathIssue(SyncPathIssueCode.RESERVED_GROUPS_PREFIX)
        }
        return SyncPath(path, key)
    }

    private fun nfc(text: String): String = try {
        UnicodeText.nfc(text)
    } catch (_: RuntimeException) {
        throw SyncPathIssue(SyncPathIssueCode.NORMALIZATION_FAILED)
    }
}

/** Diagnostics retain no input path. Segment indices are zero-based; global issues use null. */
class SyncPathIssue internal constructor(val code: SyncPathIssueCode, val segmentIndex: Int? = null) :
    IllegalArgumentException(code.message)

enum class SyncPathIssueCode(val wireCode: String, internal val message: String) {
    EMPTY_PATH("path.empty", "Supply a relative prompt path."),
    NORMALIZATION_FAILED("path.normalization_failed", "The sync path could not be normalized."),
    ABSOLUTE_PATH("path.absolute", "Use a relative path without a leading slash."),
    PATH_TOO_LONG("path.too_long", "Keep the NFC path within 1024 UTF-8 bytes."),
    EMPTY_SEGMENT("path.segment_empty", "Use nonempty path segments separated by a single slash."),
    DOT_SEGMENT("path.segment_dot", "Replace dot and dot-dot path segments with names."),
    HIDDEN_DIRECTORY("path.segment_hidden", "Use folder names without a leading dot."),
    BACKSLASH("path.backslash", "Use forward slashes to separate path segments."),
    CONTROL_CHARACTER("path.control_character", "Remove control characters from the path."),
    TRAILING_DOT_OR_SPACE("path.trailing_dot_or_space", "Remove trailing dots and spaces from path segments."),
    SEGMENT_TOO_LONG("path.segment_too_long", "Keep each NFC segment within 255 UTF-8 bytes."),
    INVALID_EXTENSION("path.invalid_extension", "End the prompt path with the exact lowercase .md suffix."),
    RESERVED_GROUPS_PREFIX("path.reserved_groups_prefix", "Use a private path outside the reserved Groups folder."),
}
