package ch.lkmc.monkeyspaw.core.conformance

import java.math.BigDecimal
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction.REPORT
import kotlin.test.assertContentEquals
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

internal fun strictUtf8(bytes: ByteArray): String = try {
    Charsets.UTF_8.newDecoder().onMalformedInput(REPORT).onUnmappableCharacter(REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()
} catch (_: java.nio.charset.CharacterCodingException) {
    throw CorpusException("Invalid UTF-8")
}

internal fun assertBytesEqual(expected: ByteArray, actual: ByteArray, message: String? = null) {
    assertContentEquals(expected, actual, message)
}

internal fun assertUtf8Equal(expected: String, actual: String, message: String? = null) {
    assertBytesEqual(expected.toByteArray(Charsets.UTF_8), actual.toByteArray(Charsets.UTF_8), message)
}

private val jsonNumber = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")

internal fun parseFixtureJson(bytes: ByteArray): JsonElement {
    // JsonPrimitive retains the original numeric token, including Int64s beyond 2^53.
    // Duplicate keys collapse, as in Swift; the corpus promises unique producer keys.
    val value = try {
        Json.parseToJsonElement(strictUtf8(bytes).removePrefix("\uFEFF"))
    } catch (_: SerializationException) {
        throw CorpusException("Malformed fixture JSON")
    }
    fun validate(element: JsonElement) {
        when (element) {
            is JsonObject -> element.values.forEach(::validate)
            is JsonArray -> element.forEach(::validate)
            is JsonPrimitive -> corpusRequire(element.isString || element == JsonNull ||
                element.booleanOrNull != null || jsonNumber.matches(element.content), "Malformed JSON number")
        }
    }
    validate(value)
    return value
}

internal fun JsonElement?.objectValue(): JsonObject =
    this as? JsonObject ?: throw CorpusException("Expected a JSON object")

internal fun JsonElement?.arrayValue(): JsonArray =
    this as? JsonArray ?: throw CorpusException("Expected a JSON array")

internal fun JsonElement?.stringValue(): String {
    val value = this as? JsonPrimitive
    corpusRequire(value != null && value.isString, "Expected a JSON string")
    return value!!.content
}

internal fun JsonElement?.booleanValue(): Boolean {
    val value = this as? JsonPrimitive
    corpusRequire(value != null && !value.isString && value.booleanOrNull != null, "Expected a JSON boolean")
    return value!!.booleanOrNull!!
}

internal fun JsonElement?.numberValue(): BigDecimal {
    val value = this as? JsonPrimitive
    corpusRequire(value != null && !value.isString && jsonNumber.matches(value.content), "Expected a JSON number")
    return value!!.content.toBigDecimalOrNull() ?: throw CorpusException("Invalid decimal number")
}

internal fun JsonElement?.integerValue(): BigInteger = try {
    numberValue().toBigIntegerExact()
} catch (_: ArithmeticException) {
    throw CorpusException("Expected an integer")
}

internal fun JsonObject.members(required: Set<String>, optional: Set<String> = emptySet()) {
    corpusRequire(keys.containsAll(required) && (required + optional).containsAll(keys),
        "Unknown or missing members: expected $required (optional $optional), got $keys")
}

internal fun JsonElement?.strings(): List<String> = arrayValue().map { it.stringValue() }
