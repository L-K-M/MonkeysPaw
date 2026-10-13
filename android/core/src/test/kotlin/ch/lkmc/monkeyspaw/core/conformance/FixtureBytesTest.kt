package ch.lkmc.monkeyspaw.core.conformance

import java.math.BigInteger
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class FixtureBytesTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `bytes and UTF-8 helpers retain BOM newline whitespace and normalization differences`() {
        val text = "\uFEFFe\u0301\r\n \t\n"
        val bytes = text.toByteArray(Charsets.UTF_8)
        val path = temporary.newFile().toPath()
        Files.write(path, bytes)
        val file = FixtureFile("raw.md", path)
        assertBytesEqual(bytes, file.bytes())
        assertUtf8Equal(text, file.utf8())
        val golden = parseFixtureJson("""{"text":"\uFEFFe\u0301\r\n \t\n"}""".toByteArray()).objectValue()["text"].stringValue()
        assertUtf8Equal(text, golden)
        assertFailsWith<AssertionError> { assertUtf8Equal("é", "e\u0301") }
        assertFailsWith<AssertionError> { assertBytesEqual(bytes, bytes + byteArrayOf(10)) }
    }

    @Test
    fun `UTF-8 decoding rejects replacement and invalid scalar encodings`() {
        listOf(byteArrayOf(0xff.toByte()), byteArrayOf(0xc0.toByte(), 0x80.toByte()),
            byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()), byteArrayOf(0xe2.toByte(), 0x82.toByte())).forEach { bytes ->
            assertFailsWith<CorpusException> { strictUtf8(bytes) }
            assertFailsWith<CorpusException> { parseFixtureJson(bytes) }
        }
    }

    @Test
    fun `JSON numeric tokens remain exact beyond doubles and Int64 bounds`() {
        val json = parseFixtureJson("""{"large":9007199254740993,"max":9223372036854775807,"overflow":9223372036854775808,"decimal":1.0000000000000001}""".toByteArray()).objectValue()
        assertEquals(BigInteger("9007199254740993"), json["large"].integerValue())
        assertEquals(BigInteger.valueOf(Long.MAX_VALUE), json["max"].integerValue())
        assertEquals(BigInteger("9223372036854775808"), json["overflow"].integerValue())
        assertEquals("1.0000000000000001", json["decimal"].numberValue().toPlainString())
        assertFailsWith<CorpusException> { json["decimal"].integerValue() }
        listOf(JsonPrimitive(true), JsonPrimitive("1"), JsonNull).forEach { value ->
            assertFailsWith<CorpusException> { value.numberValue() }
        }
        assertFailsWith<CorpusException> { JsonPrimitive(1).booleanValue() }
    }

    @Test
    fun `JSON keys follow Swift collapse behavior and malformed JSON fails`() {
        val duplicate = parseFixtureJson("""{"schema":2,"schema":1}""".toByteArray()).objectValue()
        assertEquals(BigInteger.ONE, duplicate["schema"].integerValue())
        listOf("{", "{} {}", "{\"schema\":01}", "{\"schema\":NaN}", "{\"schema\":1,}").forEach { json ->
            assertFailsWith<CorpusException>(json) { parseFixtureJson(json.toByteArray()) }
        }
    }
}
