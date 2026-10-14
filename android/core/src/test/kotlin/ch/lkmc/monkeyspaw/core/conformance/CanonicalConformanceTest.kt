package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class CanonicalConformanceTest {
    @Test fun everyCanonicalExpectationAndComparisonIsExecuted() {
        CanonicalFixtures.consume(Corpus.load())
    }
}

internal object CanonicalFixtures {
    fun consume(corpus: Corpus): Set<String> {
        val fixtures = corpus.cases(Category.CANONICAL)
        var expectations = 0
        var comparisons = 0
        val consumed = mutableSetOf<String>()
        for (fixture in fixtures) {
            val label = fixture.envelopeFile.relativePath
            val scope = when (fixture.envelope["scope"].stringValue()) {
                "group" -> CanonicalForm.Scope.GROUP
                "user" -> CanonicalForm.Scope.USER
                else -> error("Unknown scope in $label")
            }
            val source = fixture.source(fixture.envelope["source"].stringValue())
            val bytes = source.bytes()
            val filename = source.path.fileName.toString()
            val expected = fixture.expected
            consumed.add(fixture.envelopeFile.relativePath)
            consumed.add(source.relativePath)
            expectations += expected.size
            if ("error" in expected) {
                assertEquals(setOf("error"), expected.keys, "$label expectations")
                val error = assertFailsWith<PromptWriteError>(label) { canonical(bytes, scope, filename) }
                val actual = buildJsonObject {
                    when (error) {
                        PromptWriteError.InvalidPrompt -> put("code", "invalid_prompt")
                        is PromptWriteError.UnsupportedFormat -> { put("code", "unsupported_format"); put("version", error.version.decimalValue) }
                        PromptWriteError.SourceTooLarge -> put("code", "source_too_large")
                        PromptWriteError.SerializationFailed -> error("Unexpected serialization failure in $label")
                    }
                }
                assertEquals(expected["error"], actual, "$label refusal")
                continue
            }
            assertEquals(setOf("bytes", "body", "canonicalHash", "favorite", "warnings"), expected.keys, "$label expectations")
            val actual = canonical(bytes, scope, filename)
            assertBytesEqual(expected["bytes"].stringValue().toByteArray(Charsets.UTF_8), actual.bytes, "$label bytes")
            assertEquals(expected["canonicalHash"].stringValue(), actual.canonicalHash, "$label hash")
            assertEquals(if (expected["favorite"] == JsonNull) null else expected["favorite"].booleanValue(), actual.favorite, "$label favorite")
            assertEquals(expected["warnings"], JsonArray(actual.warnings.map { buildJsonObject {
                put("code", it.code.rawValue); put("severity", it.severity.rawValue)
            } }), "$label warnings")
            assertUtf8Equal(expected["body"].stringValue(), PromptCodec.parseFile(bytes, filename).body, "$label input body")
            assertUtf8Equal(expected["body"].stringValue(), PromptCodec.parseFile(actual.bytes, filename).body, "$label stored body")
            if (scope == CanonicalForm.Scope.GROUP) {
                val repeated = CanonicalForm.group(actual.bytes, filename)
                assertBytesEqual(actual.bytes, repeated.bytes, "$label idempotence")
                assertEquals(actual.canonicalHash, repeated.canonicalHash, "$label repeated hash")
                assertNull(repeated.favorite, label)
                assertFalse(repeated.warnings.any { it.code == PromptIssueCode.GROUP_PRIVATE_REMOVED }, label)
            } else {
                assertBytesEqual(bytes, actual.bytes, "$label verbatim")
                assertNull(actual.favorite, label)
            }
            fixture.envelope["comparison"]?.objectValue()?.let { comparison ->
                val candidate = fixture.sources.getValue(comparison["source"].stringValue())
                consumed.add(candidate.relativePath)
                val equivalent = comparison["equivalent"].booleanValue()
                assertEquals(equivalent, CanonicalForm.equivalentForAdoption(bytes, candidate.bytes(), scope, filename), "$label adoption")
                assertEquals(equivalent, CanonicalForm.equivalentForAdoption(candidate.bytes(), bytes, scope, filename), "$label symmetric adoption")
                comparisons++
            }
        }
        assertEquals(fixtures.flatMap { it.files }.map { it.relativePath }.toSet(), consumed)
        println("canonical: ${fixtures.size} cases / ${consumed.size} files; $expectations expectations; " +
            "$comparisons symmetric comparisons; pending 0.")
        return consumed
    }

    private fun canonical(bytes: ByteArray, scope: CanonicalForm.Scope, filename: String): CanonicalForm =
        when (scope) {
            CanonicalForm.Scope.GROUP -> CanonicalForm.group(bytes, filename)
            CanonicalForm.Scope.USER -> CanonicalForm.user(bytes, filename)
        }
}
