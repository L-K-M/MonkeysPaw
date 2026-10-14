package ch.lkmc.monkeyspaw.core.services

import kotlinx.serialization.json.*
import java.time.Instant
import kotlin.test.*

class StateJsonTest {
    @Test fun malformedStateAlwaysThrowsAContentFreeTypedError() {
        val inputs = listOf(
            byteArrayOf(-1),
            "private malformed state".encodeToByteArray(),
            "[]".encodeToByteArray(),
            "{\"version\":null}".encodeToByteArray(),
            "{\"version\":true}".encodeToByteArray(),
            "{\"version\":1.5}".encodeToByteArray(),
            "{\"version\":1e999}".encodeToByteArray(),
            "{\"version\":\"1\"}".encodeToByteArray(),
        )
        for (bytes in inputs) {
            val error = assertFailsWith<LibraryError.OperationFailed> { StateJson.read(bytes) }
            assertEquals("Local operation failed.", error.message)
            assertNull(error.cause)
            assertTrue(error.suppressed.isEmpty())
        }
        assertEquals(JsonPrimitive(1), StateJson.read("{\"version\":1}".encodeToByteArray())["version"])
        StateJson.read("{\"version\":1.0}".encodeToByteArray())
    }

    @Test fun timestampBoundsRejectRoundedOverflowWithoutRawExceptions() {
        for (value in listOf("31556889864403199.9", Math.nextDown(Instant.MIN.epochSecond.toDouble()).toString(),
            Long.MAX_VALUE.toString(), "1e999", "null", "true")) {
            val error = assertFailsWith<LibraryError.OperationFailed> {
                StateJson.instant(Json.parseToJsonElement(value))
            }
            assertNull(error.cause)
        }
        assertEquals(Instant.MIN, StateJson.instant(Json.parseToJsonElement(Instant.MIN.epochSecond.toString())))
        assertEquals(Instant.ofEpochSecond(1), StateJson.instant(Json.parseToJsonElement("0.9999999999999999")))
        assertEquals(Instant.ofEpochSecond(-1, 500_000_000), StateJson.instant(Json.parseToJsonElement("-0.5")))
    }

    @Test fun payloadCannotOverwriteTheVersionMarker() {
        assertFailsWith<IllegalArgumentException> { StateJson.encode("version", JsonPrimitive(5)) }
        assertEquals("{\"events\":[1],\"version\":1}", StateJson.encode("events", JsonArray(listOf(JsonPrimitive(1)))).decodeToString())
        assertEquals("{\"values\":{},\"version\":1}", StateJson.encode("values", JsonObject(emptyMap())).decodeToString())
    }
}
