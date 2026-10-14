package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.`import`.ImportFormat
import ch.lkmc.monkeyspaw.core.domain.`import`.ImportMapper
import ch.lkmc.monkeyspaw.core.domain.`import`.ImportSkipReason
import ch.lkmc.monkeyspaw.core.domain.`import`.ImportWarning
import java.math.BigInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class ImportConformanceTest {
    @Test fun everyImportExpectationAndRefusalIsExecuted() {
        ImportFixtures.consume(Corpus.load())
    }
}

internal object ImportFixtures {
    fun consume(corpus: Corpus): Set<String> {
        val fixtures = corpus.cases(Category.IMPORT)
        var expectations = 0
        var converted = 0
        var copied = 0
        var refusals = 0
        val consumed = mutableSetOf<String>()
        for (fixture in fixtures) {
            val label = fixture.envelopeFile.relativePath
            val source = fixture.source(fixture.envelope["source"].stringValue())
            val count = (fixture.envelope["repeat"]?.integerValue() ?: BigInteger.ONE).intValueExact()
            val bytes = source.utf8().repeat(count).toByteArray(Charsets.UTF_8)
            val filename = source.path.fileName.toString()
            val expected = fixture.expected
            consumed.add(fixture.envelopeFile.relativePath)
            consumed.add(source.relativePath)
            expectations += expected.size
            if ("refusal" in expected) {
                assertEquals(setOf("refusal"), expected.keys, "$label expectations")
                val error = assertFailsWith<ImportSkipReason>(label) { ImportMapper.map(bytes, filename) }
                val actual = buildJsonObject {
                    when (error) {
                        is ImportSkipReason.InvalidPrompt -> {
                            put("code", "invalidPrompt")
                            put("issues", JsonArray(error.issues.map { JsonPrimitive(it.rawValue) }))
                        }
                        ImportSkipReason.FileTooLarge, ImportSkipReason.ConvertedTooLarge -> {
                            put("code", if (error == ImportSkipReason.FileTooLarge) "fileTooLarge" else "convertedTooLarge")
                            put("issues", JsonArray(emptyList()))
                        }
                        else -> error("Unexpected import refusal in $label")
                    }
                }
                assertEquals(expected["refusal"], actual, "$label refusal")
                refusals++
                continue
            }
            assertEquals(setOf("source", "body", "mappings", "preservedKeys", "dropped", "warnings"), expected.keys,
                "$label expectations")
            val mapped = ImportMapper.map(bytes, filename)
            assertUtf8Equal(expected["source"].stringValue(), mapped.document.source, "$label source")
            assertUtf8Equal(expected["body"].stringValue(), mapped.document.body, "$label body")
            assertEquals(expected["mappings"], JsonArray(mapped.report.mappings.map { buildJsonObject {
                put("sourceKey", it.sourceKey)
                put("fieldName", it.fieldName)
                put("kind", it.kind.rawValue)
                put("defaultSource", it.defaultSource?.let(::JsonPrimitive) ?: JsonNull)
            } }), "$label mappings")
            assertEquals(expected["preservedKeys"].strings(), mapped.report.preservedKeys, "$label preserved keys")
            assertEquals(expected["dropped"].strings(), mapped.report.dropped.map { it.rawValue }, "$label presentation loss")
            assertEquals(expected["warnings"], JsonArray(mapped.report.warnings.map(::warningJson)), "$label warnings")
            if (ImportFormat.filename(filename) == ImportFormat.MARKDOWN) {
                assertBytesEqual(bytes, mapped.document.source.toByteArray(Charsets.UTF_8), "$label native copy")
                copied++
            } else converted++
        }
        assertEquals(fixtures.flatMap { it.files }.map { it.relativePath }.toSet(), consumed)
        println("import: ${fixtures.size} cases / ${consumed.size} files; $expectations expectations; " +
            "$converted conversions / $copied native copies / $refusals refusals; pending 0.")
        return consumed
    }

    private fun warningJson(warning: ImportWarning) = buildJsonObject {
        val code: String
        val key: String
        when (warning) {
            is ImportWarning.UnsupportedInput -> { code = "unsupportedInput"; key = warning.key }
            is ImportWarning.InvalidName -> { code = "invalidName"; key = warning.key }
            is ImportWarning.ReservedName -> { code = "reservedName"; key = warning.name }
            is ImportWarning.FieldCollision -> { code = "fieldCollision"; key = warning.name }
            is ImportWarning.InvalidOptions -> { code = "invalidOptions"; key = warning.key }
            is ImportWarning.InvalidDefault -> { code = "invalidDefault"; key = warning.key }
            is ImportWarning.InvalidDescription -> { code = "invalidDescription"; key = warning.key }
            is ImportWarning.Validation -> { code = "validation"; key = warning.issue.rawValue }
            is ImportWarning.UnsupportedTemplate -> {
                put("code", "unsupportedTemplate")
                put("format", warning.format.rawValue)
                put("byteOffset", warning.byteOffset)
                return@buildJsonObject
            }
        }
        put("code", code)
        put("key", key)
    }
}
