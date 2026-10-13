package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.syncapi.WireJson
import ch.lkmc.monkeyspaw.core.syncapi.WireValue
import ch.lkmc.monkeyspaw.core.syncapi.wireLong
import ch.lkmc.monkeyspaw.core.syncapi.wireString
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class SchemaValidatorTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun json(source: String): WireValue = WireJson.parse(source.toByteArray())
    private val validator = SchemaValidator()

    @Test
    fun `pathless schema ids fail with UnsupportedSchema`() {
        val file = temporary.newFile("HealthResponse.json").toPath()
        for (id in listOf("urn:example:HealthResponse.json", "mailto:health@example.test")) {
            Files.writeString(file, """{"${'$'}schema":"https://json-schema.org/draft/2020-12/schema","${'$'}id":"$id","title":"HealthResponse","type":"object"}""")
            assertFailsWith<UnsupportedSchema> { SchemaValidator.load(mapOf("HealthResponse" to file)) }
        }
    }

    @Test
    fun `every emitted schema agrees with every dto fixture offline`() {
        val corpus = Corpus.load()
        val validator = SchemaValidator.load(corpus.schemas)
        assertEquals(corpus.schemas.keys, validator.names)
        val valid = mutableSetOf<String>()
        val invalid = mutableSetOf<String>()
        val cases = corpus.cases(Category.DTO)
        for (fixture in cases) {
            val name = fixture.envelope["dto"].stringValue()
            val expected = fixture.expected["valid"].booleanValue()
            assertEquals(expected, validator.validate(fixture.source().bytes(), name), fixture.name)
            (if (expected) valid else invalid).add(name)
        }
        // Every emitted schema requires at least one valid and one invalid DTO fixture.
        assertEquals(validator.names, valid)
        assertEquals(validator.names, invalid)
        println("Schema-only conformance: ${cases.size} cases, ${validator.names.size} local schemas; typed K10 coverage remains pending.")
    }

    @Test
    fun `literal types integral numbers and decimal bounds remain exact`() {
        val integer = json("""{"type":"integer","minimum":-9223372036854775808,"maximum":9223372036854775807}""")
        val number = json("""{"type":"number","minimum":-9223372036854775808,"maximum":9223372036854775807}""")
        for (source in listOf("0", "1", "-2", "1.0", "1e0", "9007199254740993", "9223372036854775807", "-9223372036854775808")) {
            assertTrue(validator.validate(json(source), integer), source)
            assertTrue(validator.validate(json(source), number), source)
        }
        for (source in listOf("true", "false", "null", "\"1\"", "[]", "{}", "9223372036854775808", "-9223372036854775809")) {
            assertEquals(false, validator.validate(json(source), integer), source)
            assertEquals(false, validator.validate(json(source), number), source)
        }
        for (source in listOf("-1.5", "0.5", "2.5")) {
            assertEquals(false, validator.validate(json(source), integer), source)
            assertEquals(true, validator.validate(json(source), number), source)
        }
        val bounded = json("""{"type":"number","minimum":0.5,"maximum":2.5}""")
        for ((source, expected) in listOf("0.4" to false, "0.5" to true, "2.5" to true, "2.6" to false)) {
            assertEquals(expected, validator.validate(json(source), bounded), source)
        }
        val unique = json("""{"type":"array","uniqueItems":true}""")
        assertEquals(false, validator.validate(json("[1,1.0]"), unique))
        assertEquals(true, validator.validate(json("[1,true]"), unique))
    }

    @Test
    fun `unsupported keywords extensions and malformed type or required fail loudly`() {
        for (source in listOf("""{"unknown":1}""", """{"type":["string","null"]}""", """{"type":null}""",
            """{"type":true}""", """{"type":"unknown"}""", """{"required":"name"}""", """{"required":null}""",
            """{"required":[1]}""", """{"required":["name",null]}""", """{"x-syncapi-rules":["unknown"]}""",
            """{"x-syncapi-format":"unknown"}""", """{"x-unknown":true}""")) {
            val schema = json(source)
            assertFailsWith<UnsupportedSchema> { validator.audit(schema) }
            assertFailsWith<UnsupportedSchema> { validator.validate(json("{}"), schema) }
        }
        assertFailsWith<UnsupportedSchema> { validator.audit(json("""{"items":{"x-unknown":true}}""")) }
        assertFailsWith<UnsupportedSchema> { validator.audit(json("""{"${'$'}ref":"Missing.json"}""")) }
    }

    @Test
    fun `UTF-8 extension independently rejects multibyte strings below the scalar cap`() {
        val schema = json("""{"type":"string","maxLength":72,"x-max-utf8-bytes":72}""")
        val atLimit = wireString("é".repeat(36))
        val overflow = wireString("é".repeat(37))
        assertEquals(true, validator.validate(atLimit, schema))
        assertEquals(true, validator.validate(overflow, schema, SchemaValidator.Mode.SCHEMA))
        assertEquals(false, validator.validate(overflow, schema))
        val scalars = json("""{"type":"string","maxLength":1}""")
        assertEquals(true, validator.validate(wireString("😀"), scalars))
        assertEquals(false, validator.validate(wireString("😀😀"), scalars))
    }

    @Test
    fun `timestamp extension checks exact milliseconds and Gregorian calendar independently`() {
        val schema = json("""{"type":"string","x-syncapi-format":"utc-milliseconds"}""")
        for (text in listOf("0001-01-01T00:00:00.000Z", "1582-10-10T00:00:00.000Z",
            "2000-02-29T12:34:56.789Z", "9999-12-31T23:59:59.999Z")) {
            assertEquals(true, validator.validate(wireString(text), schema))
        }
        for (text in listOf("0000-01-01T00:00:00.000Z", "10000-01-01T00:00:00.000Z", "1900-02-29T00:00:00.000Z",
            "2025-02-29T00:00:00.000Z", "2024-04-31T00:00:00.000Z", "2024-00-01T00:00:00.000Z",
            "2024-01-01T24:00:00.000Z", "2024-01-01T00:60:00.000Z", "2024-01-01T00:00:60.000Z",
            "2024-01-01T00:00:00Z", "2024-01-01T00:00:00.00Z", "2024-01-01T00:00:00.0000Z",
            "2024-01-01T00:00:00.000+00:00", "2024-01-01T00:00:00.000z", "2024-01-01T00:00:00.000Z\n")) {
            assertEquals(true, validator.validate(wireString(text), schema, SchemaValidator.Mode.SCHEMA))
            assertEquals(false, validator.validate(wireString(text), schema))
        }
    }

    @Test
    fun `group key extension rejects a valid spelling with the wrong identity`() {
        val schema = json("""{"type":"object","x-syncapi-rules":["group-scope-key"]}""")
        for ((source, expected) in listOf(
            """{"group_id":"one","key":"group:one"}""" to true,
            """{"group_id":"one","key":"group:two"}""" to false,
            """{"group_id":"one","key":"user:one"}""" to false,
            """{"key":"group:one"}""" to false,
        )) {
            assertEquals(true, validator.validate(json(source), schema, SchemaValidator.Mode.SCHEMA))
            assertEquals(expected, validator.validate(json(source), schema))
        }
    }

    @Test
    fun `sync page extension enforces head seq snapshot and delta relations`() {
        val schema = json("""{"type":"object","x-syncapi-rules":["sync-page"]}""")
        for ((source, expected) in listOf(
            """{"head":0,"mode":"snapshot","items":[]}""" to true,
            """{"head":3,"mode":"delta","items":[{"seq":1,"kind":"delete"}]}""" to true,
            """{"head":3,"mode":"snapshot","items":[{"seq":3,"kind":"upsert"}]}""" to true,
            """{"head":0,"mode":"snapshot","items":[{"seq":1,"kind":"upsert"}]}""" to false,
            """{"head":3,"mode":"delta","items":[{"seq":0,"kind":"delete"}]}""" to false,
            """{"head":3,"mode":"delta","items":[{"seq":4,"kind":"delete"}]}""" to false,
            """{"head":3,"mode":"snapshot","items":[{"seq":2,"kind":"upsert"}]}""" to false,
            """{"head":3,"mode":"snapshot","items":[{"seq":3,"kind":"delete"}]}""" to false,
        )) {
            assertEquals(true, validator.validate(json(source), schema, SchemaValidator.Mode.SCHEMA))
            assertEquals(expected, validator.validate(json(source), schema))
        }
    }

    @Test
    fun `pull budget extension enforces combined count identities and removed overlap`() {
        val schema = json("""{"type":"object","x-syncapi-rules":["pull-item-budget"]}""")
        fun scope(kind: String, key: String, count: Int) = WireValue.ObjectValue(mapOf(
            "kind" to wireString(kind), "key" to wireString(key), "items" to WireValue.ArrayValue(List(count) { wireLong(1) }),
        ))
        fun pull(scopes: List<WireValue>, removed: List<String> = emptyList()) = WireValue.ObjectValue(mapOf(
            "scopes" to WireValue.ArrayValue(scopes), "removed" to WireValue.ArrayValue(removed.map(::wireString)),
        ))
        val user = scope("user", "user:one", 100)
        val group = scope("group", "group:one", 100)
        val values = listOf(
            pull(listOf(user, group)) to true,
            pull(listOf(user, scope("group", "group:one", 101))) to false,
            pull(listOf(user, group, group)) to false,
            pull(listOf(group)) to false,
            pull(listOf(user, scope("user", "user:two", 0))) to false,
            pull(listOf(user, group), listOf("group:one")) to false,
            pull(listOf(user, group), listOf("group:other")) to true,
        )
        for ((value, expected) in values) {
            assertEquals(true, validator.validate(value, schema, SchemaValidator.Mode.SCHEMA))
            assertEquals(expected, validator.validate(value, schema))
        }
    }
}
