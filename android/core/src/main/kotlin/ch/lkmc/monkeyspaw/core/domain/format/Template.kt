package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits
import java.nio.charset.CharacterCodingException

sealed interface TemplateToken {
    data class Literal(val text: String) : TemplateToken
    object EscapedOpener : TemplateToken
    data class Placeholder(val name: String) : TemplateToken
}

enum class BuiltinName(val rawValue: String) {
    CLIPBOARD("clipboard"), DATE("date"), TIME("time");

    companion object {
        internal fun fromName(name: String): BuiltinName? = entries.firstOrNull { it.rawValue == name }
    }
}

/** One pass over UTF-8 bytes: ASCII syntax and byte-based diagnostics, verbatim literal text. */
@ConsistentCopyVisibility
data class Template private constructor(
    val tokens: List<TemplateToken>,
    val names: List<String>,
    val issues: List<PromptIssue>,
    internal val firstUseOffsets: Map<String, Int>,
) {
    val builtins: List<BuiltinName> get() = names.mapNotNull(BuiltinName::fromName)

    companion object {
        internal val deferredNames = setOf("selection", "cursor", "datetime", "uuid")

        fun parse(body: String): Template {
            if (body.length > Limits.maxPromptBytes) return oversized(body)
            val bytes = try {
                // JVM strings can contain lone surrogates; default encoding silently repairs them.
                body.encodeToByteArray(throwOnInvalidSequence = true)
            } catch (_: CharacterCodingException) {
                return Template(emptyList(), emptyList(), listOf(PromptIssue(PromptIssueCode.INVALID_UTF8)), emptyMap())
            }
            if (bytes.size > Limits.maxPromptBytes) return oversized(body)
            val tokens = mutableListOf<TemplateToken>()
            val offsets = linkedMapOf<String, Int>()
            val issues = mutableListOf<PromptIssue>()
            var position = 0
            var literalStart = 0

            fun literal(until: Int) {
                if (until > literalStart) tokens.add(TemplateToken.Literal(String(bytes, literalStart, until - literalStart, Charsets.UTF_8)))
            }

            while (position < bytes.size) {
                if (bytes[position] == 92.toByte() && position + 2 < bytes.size &&
                    bytes[position + 1] == 123.toByte() && bytes[position + 2] == 123.toByte()) {
                    literal(position)
                    tokens.add(TemplateToken.EscapedOpener)
                    position += 3
                    literalStart = position
                    continue
                }
                if (bytes[position] != 123.toByte() || position + 1 >= bytes.size || bytes[position + 1] != 123.toByte()) {
                    position++
                    continue
                }

                val opener = position
                var end = position + 2
                while (end + 1 < bytes.size && !(bytes[end] == 125.toByte() && bytes[end + 1] == 125.toByte())) end++
                if (end + 1 >= bytes.size) {
                    issues.add(PromptIssue(PromptIssueCode.UNBALANCED_OPENER, PromptIssueLocation.Body(opener)))
                    break
                }
                var start = opener + 2
                var nameEnd = end
                while (start < nameEnd && isSpaceOrTab(bytes[start])) start++
                while (nameEnd > start && isSpaceOrTab(bytes[nameEnd - 1])) nameEnd--
                val name = String(bytes, start, nameEnd - start, Charsets.UTF_8)
                if (isValidName(name)) {
                    literal(opener)
                    tokens.add(TemplateToken.Placeholder(name))
                    offsets.putIfAbsent(name, opener)
                    literalStart = end + 2
                } else {
                    issues.add(PromptIssue(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueLocation.Body(opener)))
                }
                position = end + 2
            }
            literal(bytes.size)
            return Template(tokens.toList(), offsets.keys.toList(), issues.toList(), offsets.toMap())
        }

        internal fun isValidName(name: String): Boolean {
            if (name.isEmpty() || !(isLetter(name[0]) || name[0] == '_')) return false
            return name.all { isLetter(it) || it in '0'..'9' || it == '_' || it == '-' }
        }

        internal fun isReserved(name: String): Boolean = BuiltinName.fromName(name) != null || name in deferredNames

        private fun oversized(body: String) = Template(listOf(TemplateToken.Literal(body)), emptyList(),
            listOf(PromptIssue(PromptIssueCode.SOURCE_TOO_LARGE)), emptyMap())

        private fun isLetter(character: Char): Boolean = character in 'A'..'Z' || character in 'a'..'z'
        private fun isSpaceOrTab(byte: Byte): Boolean = byte == 32.toByte() || byte == 9.toByte()
    }
}
