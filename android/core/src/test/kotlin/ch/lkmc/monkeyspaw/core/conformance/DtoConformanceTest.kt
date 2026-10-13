package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class DtoConformanceTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `completed families consume every valid and invalid case with canonical bytes`() {
        val corpus = Corpus.load()
        val coverage = DtoRegistry.consumeCompleted(corpus)
        assertEquals(DtoRegistry.pendingNames, coverage.pendingCases.keys)
        assertEquals(coverage.completedCases * 2, coverage.completedFiles.size)
        assertEquals(coverage.pendingCases.values.sumOf { it.size } * 2, coverage.pendingFiles.size)
        assertEquals(corpus.cases(Category.DTO).flatMap { it.files }.map { it.relativePath }.toSet(),
            coverage.completedFiles + coverage.pendingFiles)
        assertFalse(DtoRegistry.isComplete)
        assertFailsWith<CorpusException> { DtoRegistry.consumeAll(corpus) }
        println("Typed K9 conformance: ${coverage.completedCases} cases (${coverage.validCases} valid, ${coverage.invalidCases} invalid), " +
            "${coverage.completedFiles.size} files, ${DtoRegistry.completedNames.size} contracts.")
        println("Pending K10: ${coverage.pendingCases.values.sumOf { it.size }} cases, ${coverage.pendingFiles.size} files, " +
            "${coverage.pendingCases.size} contracts. DTO registry is INCOMPLETE.")
        for ((name, cases) in coverage.pendingCases.toSortedMap()) println("Pending K10: $name (${cases.size} cases)")
    }

    @Test
    fun `missing accepted rejected or pending family cannot pass coverage`() {
        val corpus = Corpus.load()
        val cases = corpus.cases(Category.DTO)
        for (valid in listOf(true, false)) {
            val incomplete = cases.filterNot {
                it.envelope["dto"].stringValue() == "HealthResponse" && it.expected["valid"].booleanValue() == valid
            }
            assertFailsWith<CorpusException> { DtoRegistry.consumeCompleted(corpus, incomplete) }
        }
        val incomplete = cases.filterNot { it.envelope["dto"].stringValue() == "Prompt" }
        assertFailsWith<CorpusException> { DtoRegistry.consumeCompleted(corpus, incomplete) }
        val omitted = cases.first { it.envelope["dto"].stringValue() == "LoginRequest" && it.expected["valid"].booleanValue() }
        assertFailsWith<CorpusException> { DtoRegistry.consumeCompleted(corpus, cases - omitted) }
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
    fun `pending and unknown registrations never act as decoding adapters`() {
        val corpus = Corpus.load()
        val validator = SchemaValidator.load(corpus.schemas)
        val fixture = corpus.cases(Category.DTO).first { it.envelope["dto"].stringValue() == "Prompt" }
        assertTrue(DtoRegistry.entries["Prompt"] == DtoRegistration.PendingK10)
        assertFailsWith<CorpusException> { DtoRegistry.checkCase(fixture, validator) }
        val envelope = JsonObject(fixture.envelope.toMutableMap().apply { put("dto", JsonPrimitive("UnknownDTO")) })
        assertFailsWith<CorpusException> { DtoRegistry.checkCase(fixture.copy(envelope = envelope), validator) }
        assertFailsWith<CorpusException> { DtoRegistry.consumeCompleted(corpus, listOf(fixture.copy(envelope = envelope))) }
    }
}
