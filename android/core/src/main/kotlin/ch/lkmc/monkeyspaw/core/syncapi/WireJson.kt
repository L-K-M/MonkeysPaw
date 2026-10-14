package ch.lkmc.monkeyspaw.core.syncapi

import java.math.BigDecimal
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction.REPORT

class WireDecodingException internal constructor(name: String) :
    IllegalArgumentException("Invalid $name contract.")

class WireEncodingException internal constructor(name: String) :
    IllegalArgumentException("Invalid $name contract.")

internal class WireContractException : IllegalArgumentException("Invalid SyncAPI contract.")

internal fun wireRequire(condition: Boolean) {
    if (!condition) throw WireContractException()
}

/** Both directions use the same contract, including nested constructed values. */
class WireCodec<T> internal constructor(
    val name: String,
    private val read: (WireValue) -> T,
    private val write: (T) -> WireValue,
) {
    fun decode(bytes: ByteArray): T = try {
        read(WireJson.parse(bytes))
    } catch (_: WireContractException) {
        // Do not retain parser causes or input values in public diagnostics.
        throw WireDecodingException(name)
    }

    fun encode(value: T): ByteArray = try {
        val tree = write(value)
        read(tree)
        WireJson.canonical(tree)
    } catch (_: WireContractException) {
        throw WireEncodingException(name)
    }

    internal fun decodeValue(value: WireValue): T = read(value)
    internal fun encodeValue(value: T): WireValue = write(value)
}

// Numeric tokens stay exact until a typed reader requests a Long. The test-only
// schema validator can also examine decimals and out-of-range numbers.
internal sealed interface WireValue {
    data class Text(val value: String) : WireValue
    data class Number(val token: String) : WireValue
    data class BooleanValue(val value: Boolean) : WireValue
    data object Null : WireValue
    data class ArrayValue(val values: List<WireValue>) : WireValue
    data class ObjectValue(val fields: Map<String, WireValue>) : WireValue
}

internal fun WireValue.longValue(): Long {
    val number = this as? WireValue.Number ?: throw WireContractException()
    return try {
        BigDecimal(number.token).longValueExact()
    } catch (_: ArithmeticException) {
        throw WireContractException()
    } catch (_: NumberFormatException) {
        throw WireContractException()
    }
}

internal fun WireValue.stringValue(): String =
    (this as? WireValue.Text)?.value?.also { WireValidation.scalarCount(it) }
        ?: throw WireContractException()

internal fun wireString(value: String): WireValue = WireValue.Text(value)
internal fun wireNullable(value: String?): WireValue = value?.let(::wireString) ?: WireValue.Null
internal fun wireLong(value: Long): WireValue = WireValue.Number(value.toString())
internal fun wireBoolean(value: Boolean): WireValue = WireValue.BooleanValue(value)
internal fun wireObject(vararg fields: Pair<String, WireValue>): WireValue = WireValue.ObjectValue(mapOf(*fields))
internal fun <T> wireDtos(values: List<T>, codec: WireCodec<T>): WireValue =
    WireValue.ArrayValue(values.map(codec::encodeValue))

internal fun <T> objectCodec(
    name: String,
    read: (WireObject) -> T,
    write: (T) -> WireValue,
): WireCodec<T> = WireCodec(name, { read(WireObject(it)) }, write)

internal class WireObject(value: WireValue) {
    private val fields = (value as? WireValue.ObjectValue)?.fields ?: throw WireContractException()

    fun members(required: Set<String>, optional: Set<String> = emptySet(), minimum: Int = 0) {
        wireRequire(fields.keys.containsAll(required) && (required + optional).containsAll(fields.keys))
        wireRequire(fields.size >= minimum)
    }

    fun contains(key: String): Boolean = fields.containsKey(key)

    fun string(key: String, validate: (String) -> Unit = {}): String =
        value(key).stringValue().also(validate)

    fun nullableString(key: String, validate: (String) -> Unit = {}): String? =
        if (value(key) == WireValue.Null) null else string(key, validate)

    fun optionalString(key: String, validate: (String) -> Unit = {}): String? =
        if (contains(key)) string(key, validate) else null

    fun patchString(key: String, validate: (String) -> Unit = {}): OptionalValue<String> = when {
        !contains(key) -> OptionalValue.Omitted
        value(key) == WireValue.Null -> OptionalValue.Null
        else -> OptionalValue.Value(string(key, validate))
    }

    fun long(key: String, minimum: Long = Long.MIN_VALUE, maximum: Long = Long.MAX_VALUE): Long =
        value(key).longValue().also { wireRequire(it in minimum..maximum) }

    fun optionalLong(key: String, minimum: Long = Long.MIN_VALUE, maximum: Long = Long.MAX_VALUE): Long? =
        if (contains(key)) long(key, minimum, maximum) else null

    fun nullableLong(key: String, minimum: Long = Long.MIN_VALUE): Long? =
        if (value(key) == WireValue.Null) null else long(key, minimum)

    fun strings(key: String, validate: (String) -> Unit = {}): List<String> =
        ((value(key) as? WireValue.ArrayValue)?.values ?: throw WireContractException())
            .map { it.stringValue().also(validate) }

    fun stringMap(key: String, validateKey: (String) -> Unit, validateValue: (String) -> Unit): Map<String, String> =
        ((value(key) as? WireValue.ObjectValue)?.fields ?: throw WireContractException())
            .map { (name, value) -> name.also(validateKey) to value.stringValue().also(validateValue) }.toMap()

    fun boolean(key: String): Boolean =
        (value(key) as? WireValue.BooleanValue)?.value ?: throw WireContractException()

    fun optionalBoolean(key: String): Boolean? = if (contains(key)) boolean(key) else null

    fun <T> dto(key: String, codec: WireCodec<T>): T = codec.decodeValue(value(key))
    fun <T> optionalDto(key: String, codec: WireCodec<T>): T? = if (contains(key)) dto(key, codec) else null
    fun <T> dtos(key: String, codec: WireCodec<T>): List<T> =
        ((value(key) as? WireValue.ArrayValue)?.values ?: throw WireContractException()).map(codec::decodeValue)

    private fun value(key: String): WireValue = fields[key] ?: throw WireContractException()
}

internal fun MutableMap<String, WireValue>.setPatch(key: String, value: OptionalValue<String>) {
    when (value) {
        OptionalValue.Omitted -> Unit
        OptionalValue.Null -> put(key, WireValue.Null)
        is OptionalValue.Value -> put(key, wireString(value.value))
    }
}

internal object WireJson {
    private const val MAX_NESTING_DEPTH = 512

    fun parse(bytes: ByteArray): WireValue {
        val text = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(REPORT).onUnmappableCharacter(REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            throw WireContractException()
        }
        return Parser(text.removePrefix("\uFEFF")).parse()
    }

    fun canonical(value: WireValue): ByteArray = buildString { appendValue(value) }.toByteArray(Charsets.UTF_8)

    private fun StringBuilder.appendValue(value: WireValue) {
        when (value) {
            is WireValue.Text -> appendQuoted(value.value)
            is WireValue.Number -> append(value.longValue())
            is WireValue.BooleanValue -> append(value.value)
            WireValue.Null -> append("null")
            is WireValue.ArrayValue -> {
                append('[')
                value.values.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendValue(item)
                }
                append(']')
            }
            is WireValue.ObjectValue -> {
                append('{')
                value.fields.keys.sortedWith(utf8Order).forEachIndexed { index, key ->
                    if (index > 0) append(',')
                    appendQuoted(key)
                    append(':')
                    appendValue(value.fields.getValue(key))
                }
                append('}')
            }
        }
    }

    // Swift JSONEncoder .sortedKeys compares the unescaped, unsigned UTF-8 key bytes.
    private val utf8Order = Comparator<String> { left, right ->
        val a = left.toByteArray(Charsets.UTF_8)
        val b = right.toByteArray(Charsets.UTF_8)
        var result = 0
        for (index in 0 until minOf(a.size, b.size)) {
            result = (a[index].toInt() and 255).compareTo(b[index].toInt() and 255)
            if (result != 0) break
        }
        if (result != 0) result else a.size.compareTo(b.size)
    }

    private fun StringBuilder.appendQuoted(text: String) {
        WireValidation.scalarCount(text)
        append('"')
        for (char in text) when (char) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (char.code < 32) append("\\u" + char.code.toString(16).padStart(4, '0')) else append(char)
        }
        append('"')
    }

    /** Strict JSON grammar; duplicate members collapse as in the Swift decoder. */
    private class Parser(private val text: String) {
        private var index = 0

        fun parse(): WireValue {
            val result = value()
            whitespace()
            wireRequire(index == text.length)
            return result
        }

        private fun value(depth: Int = 0): WireValue {
            whitespace()
            return when (peek()) {
                '"' -> WireValue.Text(string())
                '{' -> objectValue(depth)
                '[' -> arrayValue(depth)
                't' -> literal("true", WireValue.BooleanValue(true))
                'f' -> literal("false", WireValue.BooleanValue(false))
                'n' -> literal("null", WireValue.Null)
                '-', in '0'..'9' -> number()
                else -> throw WireContractException()
            }
        }

        private fun objectValue(depth: Int): WireValue {
            // Reject excessive containers before recursion can exhaust the JVM stack.
            wireRequire(depth < MAX_NESTING_DEPTH)
            index++
            whitespace()
            val fields = linkedMapOf<String, WireValue>()
            if (take('}')) return WireValue.ObjectValue(fields)
            while (true) {
                whitespace()
                wireRequire(peek() == '"')
                val key = string()
                whitespace()
                wireRequire(take(':'))
                fields[key] = value(depth + 1)
                whitespace()
                if (take('}')) return WireValue.ObjectValue(fields)
                wireRequire(take(','))
            }
        }

        private fun arrayValue(depth: Int): WireValue {
            wireRequire(depth < MAX_NESTING_DEPTH)
            index++
            whitespace()
            val values = mutableListOf<WireValue>()
            if (take(']')) return WireValue.ArrayValue(values)
            while (true) {
                values.add(value(depth + 1))
                whitespace()
                if (take(']')) return WireValue.ArrayValue(values)
                wireRequire(take(','))
            }
        }

        private fun string(): String = buildString {
            wireRequire(take('"'))
            while (true) {
                wireRequire(index < text.length)
                val char = text[index++]
                if (char == '"') break
                wireRequire(char.code >= 32)
                if (char != '\\') { append(char); continue }
                wireRequire(index < text.length)
                when (text[index++]) {
                    '"' -> append('"')
                    '\\' -> append('\\')
                    '/' -> append('/')
                    'b' -> append('\b')
                    'f' -> append('\u000C')
                    'n' -> append('\n')
                    'r' -> append('\r')
                    't' -> append('\t')
                    'u' -> {
                        val first = hexChar()
                        wireRequire(!first.isLowSurrogate())
                        append(first)
                        if (first.isHighSurrogate()) {
                            wireRequire(take('\\') && take('u'))
                            val second = hexChar()
                            wireRequire(second.isLowSurrogate())
                            append(second)
                        }
                    }
                    else -> throw WireContractException()
                }
            }
        }

        private fun hexChar(): Char {
            wireRequire(index + 4 <= text.length)
            var result = 0
            repeat(4) {
                val char = text[index++]
                val digit = when (char) {
                    in '0'..'9' -> char - '0'
                    in 'a'..'f' -> char - 'a' + 10
                    in 'A'..'F' -> char - 'A' + 10
                    else -> throw WireContractException()
                }
                result = result * 16 + digit
            }
            return result.toChar()
        }

        private fun number(): WireValue {
            val start = index
            take('-')
            if (!take('0')) {
                wireRequire(peek() in '1'..'9')
                digits()
            }
            if (take('.')) { wireRequire(peek() in '0'..'9'); digits() }
            if (take('e') || take('E')) {
                if (!take('+')) take('-')
                wireRequire(peek() in '0'..'9')
                digits()
            }
            return WireValue.Number(text.substring(start, index))
        }

        private fun digits() { while (peek() in '0'..'9') index++ }

        private fun literal(spelling: String, result: WireValue): WireValue {
            wireRequire(text.startsWith(spelling, index))
            index += spelling.length
            return result
        }

        private fun whitespace() { while (peek() in listOf(' ', '\t', '\r', '\n')) index++ }
        private fun peek(): Char? = text.getOrNull(index)
        private fun take(char: Char): Boolean = if (peek() == char) { index++; true } else false
    }
}
