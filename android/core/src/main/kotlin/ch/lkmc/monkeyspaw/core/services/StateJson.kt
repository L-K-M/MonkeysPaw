package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import kotlinx.serialization.json.*
import kotlinx.serialization.ExperimentalSerializationApi
import java.math.BigDecimal
import java.time.Instant
import kotlin.math.floor
import kotlin.math.roundToLong

/** Private version-1 state only; parsing failures never retain JSON or decoder error bodies. */
internal object StateJson {
    fun read(bytes: ByteArray): JsonObject {
        val root = try {
            Json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)) as? JsonObject
        } catch (_: Exception) { throw LibraryError.OperationFailed }
            ?: throw LibraryError.OperationFailed
        val version = root["version"] as? JsonPrimitive ?: throw LibraryError.OperationFailed
        if (version.isString || version.content.toBigDecimalOrNull()?.compareTo(BigDecimal.ONE) != 0) {
            throw LibraryError.OperationFailed
        }
        return root
    }

    fun fields(element: JsonElement?): JsonObject = element as? JsonObject ?: throw LibraryError.OperationFailed

    fun text(element: JsonElement): String {
        val primitive = element as? JsonPrimitive ?: throw LibraryError.OperationFailed
        if (!primitive.isString) throw LibraryError.OperationFailed
        return primitive.content
    }

    fun instant(element: JsonElement): Instant {
        val primitive = element as? JsonPrimitive ?: throw LibraryError.OperationFailed
        if (primitive.isString) throw LibraryError.OperationFailed
        val seconds = primitive.content.toDoubleOrNull() ?: throw LibraryError.OperationFailed
        if (!seconds.isFinite()) throw LibraryError.OperationFailed
        val floored = floor(seconds)
        val whole = floored.toLong()
        val nanos = ((seconds - floored) * 1_000_000_000).roundToLong()
        // Double rounds MAX's epoch second upward; compare the exact integer bounds.
        if (whole < Instant.MIN.epochSecond || whole > Instant.MAX.epochSecond ||
            whole == Instant.MAX.epochSecond && nanos >= 1_000_000_000) {
            throw LibraryError.OperationFailed
        }
        return Instant.ofEpochSecond(whole, nanos)
    }

    @OptIn(ExperimentalSerializationApi::class)
    fun number(instant: Instant): JsonPrimitive {
        val seconds = instant.epochSecond.toDouble() + instant.nano / 1_000_000_000.0
        return JsonUnquotedLiteral(BigDecimal.valueOf(seconds).stripTrailingZeros().toPlainString())
    }

    fun objectOf(fields: Map<String, JsonElement>): JsonObject = JsonObject(fields.toSortedMap { a, b ->
        Utf8Order.compare(a.encodeToByteArray(throwOnInvalidSequence = true), b.encodeToByteArray(throwOnInvalidSequence = true))
    })

    fun encode(payload: String, contents: JsonElement): ByteArray {
        require(payload != "version") { "State payload cannot replace the version marker." }
        return objectOf(mapOf(payload to contents, "version" to JsonPrimitive(1))).toString()
            .encodeToByteArray(throwOnInvalidSequence = true)
    }
}
