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
        val root = Json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)) as? JsonObject
            ?: throw LibraryError.OperationFailed
        val version = root["version"] as? JsonPrimitive ?: throw LibraryError.OperationFailed
        if (version.isString || BigDecimal(version.content).intValueExact() != 1) throw LibraryError.OperationFailed
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
        val seconds = primitive.content.toDouble()
        if (!seconds.isFinite()) throw LibraryError.OperationFailed
        val whole = floor(seconds)
        if (whole < Instant.MIN.epochSecond.toDouble() || whole > Instant.MAX.epochSecond.toDouble()) {
            throw LibraryError.OperationFailed
        }
        return Instant.ofEpochSecond(whole.toLong(), ((seconds - whole) * 1_000_000_000).roundToLong())
    }

    @OptIn(ExperimentalSerializationApi::class)
    fun number(instant: Instant): JsonPrimitive {
        val seconds = instant.epochSecond.toDouble() + instant.nano / 1_000_000_000.0
        return JsonUnquotedLiteral(BigDecimal.valueOf(seconds).stripTrailingZeros().toPlainString())
    }

    fun objectOf(fields: Map<String, JsonElement>): JsonObject = JsonObject(fields.toSortedMap { a, b ->
        Utf8Order.compare(a.encodeToByteArray(throwOnInvalidSequence = true), b.encodeToByteArray(throwOnInvalidSequence = true))
    })

    fun encode(payload: String, contents: JsonElement): ByteArray =
        objectOf(mapOf(payload to contents, "version" to JsonPrimitive(1))).toString()
            .encodeToByteArray(throwOnInvalidSequence = true)
}
