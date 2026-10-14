package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError

/** Foundation JSONSerialization's sorted-key profile for assistant wire objects. */
internal object AssistantJson {
    fun encode(value: Any): String = buildString { appendValue(value) }

    private fun StringBuilder.appendValue(value: Any?) {
        when (value) {
            is String -> appendQuoted(value)
            is Boolean -> append(value)
            is Int, is Long -> append(value)
            is List<*> -> {
                append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendValue(item)
                }
                append(']')
            }
            is Map<*, *> -> {
                // All assistant/schema property names are trusted ASCII literals.
                val members = value.entries.map { (key, item) ->
                    val name = key as? String ?: throw AssistantError.InvalidOutput
                    if (name.any { it.code !in 32..126 }) throw AssistantError.InvalidOutput
                    name to item
                }.sortedBy { it.first }
                append('{')
                members.forEachIndexed { index, (key, item) ->
                    if (index > 0) append(',')
                    appendQuoted(key)
                    append(':')
                    appendValue(item)
                }
                append('}')
            }
            else -> throw AssistantError.InvalidOutput
        }
    }

    private fun StringBuilder.appendQuoted(text: String) {
        scalarBytes(text)
        append('"')
        for (char in text) when (char) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '/' -> append("\\/")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (char.code < 32) append("\\u" + char.code.toString(16).padStart(4, '0')) else append(char)
        }
        append('"')
    }
}
