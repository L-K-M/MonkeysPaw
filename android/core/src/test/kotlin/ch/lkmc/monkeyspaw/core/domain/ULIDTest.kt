package ch.lkmc.monkeyspaw.core.domain

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ULIDTest {
    @Test fun standardAlphabetAsciiCaseAndOverflowBound() {
        assertEquals("01ARZ3NDEKTSV4RRFFQ69G5FAV", ULID.parse("01arz3ndektsv4rrffq69g5fav")?.rawValue)
        assertNotNull(ULID.parse("00000000000000000000000000"))
        assertNotNull(ULID.parse("7ZZZZZZZZZZZZZZZZZZZZZZZZZ"))
        for (invalid in listOf("8ZZZZZZZZZZZZZZZZZZZZZZZZZ", "01ARZ3NDEKTSV4RRFFQ69G5FAI",
            "01ARZ3NDEKTSV4RRFFQ69G5FAL", "01ARZ3NDEKTSV4RRFFQ69G5FAO", "01ARZ3NDEKTSV4RRFFQ69G5FAU",
            "01ARZ3NDEKTSV4RRFFQ69G5FA", "001ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAé",
            "01ARZ3NDEKTSV4RRFFQ69G5FAı")) assertNull(ULID.parse(invalid), invalid)
    }

    @Test fun generationUsesSuppliedMillisecondsAndAllEntropyBits() {
        assertEquals("00000000000000000000000000", ULID.generate(Instant.EPOCH, ByteArray(10)).rawValue)
        assertEquals("00000000Z9ZZZZZZZZZZZZZZZZ", ULID.generate(Instant.ofEpochSecond(1, 1_900_000), ByteArray(10) { -1 }).rawValue)
        assertEquals("0000000000000G40R40M30E209", ULID.generate(Instant.EPOCH, ByteArray(10) { it.toByte() }).rawValue)
        assertEquals("7ZZZZZZZZZZZZZZZZZZZZZZZZZ", ULID.generate(Instant.ofEpochMilli(281_474_976_710_655), ByteArray(10) { -1 }).rawValue)
    }

    @Test fun invalidTimestampPrecedesEntropyLengthAndNoStateIsRead() {
        for (instant in listOf(Instant.EPOCH.minusNanos(1), Instant.MIN, Instant.MAX,
            Instant.ofEpochMilli(281_474_976_710_656))) {
            assertEquals(ULIDGenerationError.InvalidTimestamp,
                assertFailsWith<ULIDGenerationError> { ULID.generate(instant, ByteArray(0)) })
        }
        for (count in listOf(0, 9, 11)) {
            assertEquals(ULIDGenerationError.InvalidEntropyLength,
                assertFailsWith<ULIDGenerationError> { ULID.generate(Instant.EPOCH, ByteArray(count)) })
        }
        val instant = Instant.ofEpochMilli(123456)
        val entropy = ByteArray(10) { 0x95.toByte() }
        assertEquals(ULID.generate(instant, entropy), ULID.generate(instant, entropy))
    }
}
