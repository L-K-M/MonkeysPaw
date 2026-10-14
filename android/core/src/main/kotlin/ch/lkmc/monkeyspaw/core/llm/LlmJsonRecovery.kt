package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import java.nio.charset.CharacterCodingException

internal sealed interface LlmJsonValue {
    class Object(val members: Map<String, LlmJsonValue>) : LlmJsonValue
    class Array(val items: List<LlmJsonValue>) : LlmJsonValue
    class Text(val value: String) : LlmJsonValue
    class Boolean(val value: kotlin.Boolean) : LlmJsonValue
    class Number(val token: String) : LlmJsonValue
    data object Null : LlmJsonValue
}

internal fun LlmJsonValue.member(key: String): LlmJsonValue =
    (this as? LlmJsonValue.Object)?.members?.get(key) ?: throw AssistantError.InvalidOutput
internal fun LlmJsonValue.array(): List<LlmJsonValue> =
    (this as? LlmJsonValue.Array)?.items ?: throw AssistantError.InvalidOutput
internal fun LlmJsonValue.string(): String =
    (this as? LlmJsonValue.Text)?.value ?: throw AssistantError.InvalidOutput
internal fun LlmJsonValue.boolean(): Boolean =
    (this as? LlmJsonValue.Boolean)?.value ?: throw AssistantError.InvalidOutput

internal fun scalarBytes(text: String): ByteArray = try {
    text.encodeToByteArray(throwOnInvalidSequence = true)
} catch (_: CharacterCodingException) {
    throw AssistantError.InvalidOutput
}

/** Only the selected object owns string/bracket state; complete arrays stay wrappers. */
internal object LlmJsonRecovery {
    fun objectIn(output: String): ByteArray {
        if (output.length > Limits.responseCap) throw AssistantError.InvalidOutput
        val bytes = scalarBytes(output)
        if (bytes.size > Limits.responseCap) throw AssistantError.InvalidOutput
        var position = 0
        var start = -1
        val stack = mutableListOf<Int>()
        var inString = false
        var escaped = false
        while (position < bytes.size) {
            val byte = bytes[position].toInt()
            if (start < 0) {
                if (bytes.matches(position, "<think>")) {
                    position = endOfThinking(bytes, position)
                    continue
                }
                if (byte == 91) {
                    val end = try { LlmJsonParser(bytes, position).parsePrefix().second }
                        catch (_: AssistantError) { null }
                    if (end != null) { position = end; continue }
                }
                if (byte != 123) { position++; continue }
                start = position
            }
            if (inString) {
                if (escaped) escaped = false
                else if (byte == 92) escaped = true
                else if (byte == 34) inString = false
                position++
                continue
            }
            if (byte == 34) inString = true
            else if (byte == 123 || byte == 91) {
                stack.add(if (byte == 123) 125 else 93)
                if (stack.size > Limits.llmJSONNestingCap) throw AssistantError.InvalidOutput
            } else if ((byte == 125 || byte == 93) && stack.isNotEmpty()) {
                if (stack.removeAt(stack.lastIndex) != byte) throw AssistantError.InvalidOutput
                if (stack.isEmpty()) return bytes.copyOfRange(start, position + 1)
            }
            position++
        }
        throw AssistantError.InvalidOutput
    }

    private fun endOfThinking(bytes: ByteArray, start: Int): Int {
        var position = start + 7
        var depth = 1
        while (position < bytes.size) {
            if (bytes.matches(position, "<think>")) { depth++; position += 7 }
            else if (bytes.matches(position, "</think>")) {
                depth--; position += 8
                if (depth == 0) return position
            } else position++
        }
        throw AssistantError.InvalidOutput
    }
}

private fun ByteArray.matches(position: Int, ascii: String): Boolean =
    position + ascii.length <= size && ascii.indices.all { this[position + it].toInt() == ascii[it].code }

/** Separate from SyncAPI's reader: decoded duplicate keys and 32 open containers are strict. */
internal enum class AssistantJsonMode { OUTPUT, ENVELOPE }

internal class LlmJsonParser(private val bytes: ByteArray, private var position: Int = 0,
                            private val mode: AssistantJsonMode = AssistantJsonMode.OUTPUT) {
    init {
        // JSONDecoder accepts a document BOM; output recovery has its own pinned rules.
        if (mode == AssistantJsonMode.ENVELOPE && position == 0 && bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) position = 3
    }

    fun parse(): LlmJsonValue {
        val value = parsePrefix().first
        whitespace()
        if (position != bytes.size) throw AssistantError.InvalidOutput
        return value
    }

    fun parsePrefix(): Pair<LlmJsonValue, Int> = value(0) to position

    private fun value(depth: Int): LlmJsonValue {
        whitespace()
        if (position >= bytes.size) throw AssistantError.InvalidOutput
        val cap = if (mode == AssistantJsonMode.OUTPUT) Limits.llmJSONNestingCap else Limits.assistantEnvelopeNestingCap
        if ((peek() == 123 || peek() == 91) && depth >= cap) throw AssistantError.InvalidOutput
        return when (peek()) {
            123 -> {
                position++
                whitespace()
                val members = linkedMapOf<String, LlmJsonValue>()
                if (!consume(125)) {
                    do {
                        whitespace()
                        // Swift Dictionary<String, ...> uses canonical String equality.
                        val decoded = string()
                        val key = if (mode == AssistantJsonMode.OUTPUT) UnicodeText.nfc(decoded) else decoded
                        if (key in members && mode == AssistantJsonMode.OUTPUT) throw AssistantError.InvalidOutput
                        whitespace()
                        if (!consume(58)) throw AssistantError.InvalidOutput
                        val item = value(depth + 1)
                        // JSONDecoder's envelope keyed containers retain the first duplicate.
                        if (key !in members) members[key] = item
                        whitespace()
                    } while (consume(44))
                    if (!consume(125)) throw AssistantError.InvalidOutput
                }
                LlmJsonValue.Object(members)
            }
            91 -> {
                position++
                whitespace()
                val items = mutableListOf<LlmJsonValue>()
                if (!consume(93)) {
                    do { items.add(value(depth + 1)); whitespace() } while (consume(44))
                    if (!consume(93)) throw AssistantError.InvalidOutput
                }
                LlmJsonValue.Array(items)
            }
            34 -> LlmJsonValue.Text(string())
            116 -> { literal("true"); LlmJsonValue.Boolean(true) }
            102 -> { literal("false"); LlmJsonValue.Boolean(false) }
            110 -> { literal("null"); LlmJsonValue.Null }
            else -> {
                val start = position
                while (position < bytes.size && peek() !in listOf(9, 10, 13, 32, 44, 93, 125)) position++
                val token = String(bytes, start, position - start, Charsets.UTF_8)
                // Swift's fragment reader accepts a leading UTF-8 BOM, including NSNumber booleans.
                val fragment = if (mode == AssistantJsonMode.OUTPUT) token.removePrefix("\uFEFF") else token
                val bomBoolean = mode == AssistantJsonMode.OUTPUT && token.startsWith("\uFEFF") && fragment in setOf("true", "false")
                if (!bomBoolean && (!number.matches(fragment) ||
                    (mode == AssistantJsonMode.OUTPUT && fragment.toDoubleOrNull()?.isFinite() != true))) {
                    throw AssistantError.InvalidOutput
                }
                LlmJsonValue.Number(fragment)
            }
        }
    }

    private fun string(): String {
        if (!consume(34)) throw AssistantError.InvalidOutput
        val text = StringBuilder()
        var start = position
        while (position < bytes.size) {
            val byte = peek()
            if (byte < 32) throw AssistantError.InvalidOutput
            if (byte == 34 || byte == 92) {
                // The reference strips one literal BOM per raw UTF-8 run; escaped BOMs remain.
                try {
                    val run = bytes.decodeToString(start, position, throwOnInvalidSequence = true)
                    text.append(if (mode == AssistantJsonMode.OUTPUT) run.removePrefix("\uFEFF") else run)
                }
                catch (_: CharacterCodingException) { throw AssistantError.InvalidOutput }
                position++
                if (byte == 34) return text.toString()
                if (position >= bytes.size) throw AssistantError.InvalidOutput
                val escape = peek()
                position++
                when (escape) {
                    34, 47, 92 -> text.append(escape.toChar())
                    98 -> text.append('\b')
                    102 -> text.append('\u000C')
                    110 -> text.append('\n')
                    114 -> text.append('\r')
                    116 -> text.append('\t')
                    117 -> {
                        val first = hexQuad()
                        when (first) {
                            in 0xD800..0xDBFF -> {
                                if (!consume(92) || !consume(117)) throw AssistantError.InvalidOutput
                                val second = hexQuad()
                                if (second !in 0xDC00..0xDFFF) throw AssistantError.InvalidOutput
                                text.append(first.toChar()).append(second.toChar())
                            }
                            in 0xDC00..0xDFFF -> throw AssistantError.InvalidOutput
                            else -> text.append(first.toChar())
                        }
                    }
                    else -> throw AssistantError.InvalidOutput
                }
                start = position
            } else position++
        }
        throw AssistantError.InvalidOutput
    }

    private fun hexQuad(): Int {
        if (position + 4 > bytes.size) throw AssistantError.InvalidOutput
        var scalar = 0
        repeat(4) {
            val digit = peek().toChar().digitToIntOrNull(16) ?: throw AssistantError.InvalidOutput
            scalar = scalar * 16 + digit
            position++
        }
        return scalar
    }

    private fun literal(text: String) {
        if (!bytes.matches(position, text)) throw AssistantError.InvalidOutput
        position += text.length
    }

    private fun peek(): Int = bytes[position].toInt() and 255
    private fun consume(byte: Int): Boolean {
        if (position >= bytes.size || peek() != byte) return false
        position++
        return true
    }
    private fun whitespace() { while (position < bytes.size && peek() in listOf(9, 10, 13, 32)) position++ }

    companion object {
        private val number = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
    }
}
