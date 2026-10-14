package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class DtoConformanceTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `every contract consumes every valid and invalid case with canonical bytes`() {
        val corpus = Corpus.load()
        val coverage = DtoRegistry.consumeAll(corpus)
        assertEquals(coverage.cases * 2, coverage.files.size)
        assertEquals(corpus.cases(Category.DTO).flatMap { it.files }.map { it.relativePath }.toSet(),
            coverage.files)
        println("Typed DTO conformance: ${coverage.cases} cases (${coverage.validCases} valid, ${coverage.invalidCases} invalid), " +
            "${coverage.files.size} files, ${DtoRegistry.entries.size} contracts; pending 0.")
    }

    @Test
    fun `case order does not affect complete corpus accounting`() {
        val corpus = Corpus.load()
        val coverage = DtoRegistry.consumeAll(corpus, corpus.cases(Category.DTO).reversed())
        assertEquals(corpus.cases(Category.DTO).flatMap { it.files }.map { it.relativePath }.toSet(),
            coverage.files)
    }

    @Test
    fun `missing accepted rejected or individual case cannot pass coverage`() {
        val corpus = Corpus.load()
        val cases = corpus.cases(Category.DTO)
        for (valid in listOf(true, false)) {
            val incomplete = cases.filterNot {
                it.envelope["dto"].stringValue() == "HealthResponse" && it.expected["valid"].booleanValue() == valid
            }
            assertFailsWith<CorpusException> { DtoRegistry.consumeAll(corpus, incomplete) }
        }
        val incomplete = cases.filterNot { it.envelope["dto"].stringValue() == "Prompt" }
        assertFailsWith<CorpusException> { DtoRegistry.consumeAll(corpus, incomplete) }
        val omitted = cases.first { it.envelope["dto"].stringValue() == "LoginRequest" && it.expected["valid"].booleanValue() }
        assertFailsWith<CorpusException> { DtoRegistry.consumeAll(corpus, cases - omitted) }
        assertFailsWith<CorpusException> { DtoRegistry.consumeAll(corpus, cases + omitted) }
    }

    @Test
    fun `wrong golden bytes and wrong validity cannot pass`() {
        val corpus = Corpus.load()
        val validator = SchemaValidator.load(corpus.schemas)
        val fixture = corpus.cases(Category.DTO).first {
            it.envelope["dto"].stringValue() == "LoginRequest" && it.expected["valid"].booleanValue()
        }
        val source = temporary.newFile("noncanonical.json").toPath()
        Files.write(source, fixture.source().bytes() + '\n'.code.toByte())
        val altered = fixture.copy(sources = mapOf(fixture.sources.keys.single() to FixtureFile("mutation/body.json", source)))
        assertFailsWith<AssertionError> { DtoRegistry.checkCase(altered, validator) }
        val expected = JsonObject(mapOf("valid" to JsonPrimitive(false)))
        val envelope = JsonObject(fixture.envelope.toMutableMap().apply { put("expected", expected) })
        assertFailsWith<AssertionError> { DtoRegistry.checkCase(fixture.copy(envelope = envelope), validator) }
    }

    @Test
    fun `unknown registrations never act as decoding adapters`() {
        val corpus = Corpus.load()
        val validator = SchemaValidator.load(corpus.schemas)
        val fixture = corpus.cases(Category.DTO).first { it.envelope["dto"].stringValue() == "Prompt" }
        val envelope = JsonObject(fixture.envelope.toMutableMap().apply { put("dto", JsonPrimitive("UnknownDTO")) })
        assertFailsWith<CorpusException> { DtoRegistry.checkCase(fixture.copy(envelope = envelope), validator) }
        assertFailsWith<CorpusException> { DtoRegistry.consumeAll(corpus, listOf(fixture.copy(envelope = envelope))) }
    }

    @Test
    fun `wrong HTTP status or Retry-After golden cannot pass`() {
        val corpus = Corpus.load()
        val validator = SchemaValidator.load(corpus.schemas)
        for ((name, key, wrong) in listOf(Triple("ErrorResponse", "http_status", JsonPrimitive(200)),
            Triple("RetryAfter", "header_value", JsonPrimitive("wrong")))) {
            val fixture = corpus.cases(Category.DTO).first {
                it.envelope["dto"].stringValue() == name && it.expected["valid"].booleanValue()
            }
            val expected = JsonObject(fixture.expected.toMutableMap().apply { put(key, wrong) })
            val envelope = JsonObject(fixture.envelope.toMutableMap().apply { put("expected", expected) })
            assertFailsWith<AssertionError> { DtoRegistry.checkCase(fixture.copy(envelope = envelope), validator) }
        }
    }
}
