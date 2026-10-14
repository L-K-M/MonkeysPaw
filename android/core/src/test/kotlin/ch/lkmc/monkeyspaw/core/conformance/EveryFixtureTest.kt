package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Rule
import org.junit.rules.TemporaryFolder

/** Structural inventory is the baseline; only successful semantic checks return consumed files. */
internal object EveryFixtures {
    fun consume(corpus: Corpus): Set<String> {
        val content = PromptFixtures.consume(corpus)
        val dto = DtoRegistry.consumeAll(corpus)
        val byCategory = PromptFixtures.categories.associateWith { category ->
            content.filter { it.startsWith(category.directory + "/") }.toSet()
        } + mapOf(
            Category.PATHS to PathFixtures.consume(corpus),
            Category.RANKING to RankingFixtures.consume(corpus),
            Category.CANONICAL to CanonicalFixtures.consume(corpus),
            Category.IMPORT to ImportFixtures.consume(corpus),
            Category.DTO to dto.files,
            Category.LLM to LlmFixtureConsumer.consume(corpus.cases(Category.LLM)).files,
        )
        corpusRequire(byCategory.keys == Category.entries.toSet(), "Missing semantic category adapter")
        val consumed = linkedSetOf<String>()
        for ((category, files) in byCategory) {
            val cases = corpus.cases(category)
            corpusRequire(cases.isNotEmpty(), "Empty semantic category")
            assertEquals(cases.flatMap { it.files }.map { it.relativePath }.toSet(), files,
                "Semantic consumption gap in ${category.directory}")
            for (file in files) corpusRequire(consumed.add(file), "Duplicate semantic consumption: $file")
            println("Full gate ${category.directory}: ${cases.size} cases / ${files.size} files.")
        }
        assertEquals(corpus.enumeratedFiles, consumed, "Full semantic consumption must equal the visible inventory")
        println("Full semantic conformance: ${corpus.cases.size} cases / ${consumed.size} files / ${byCategory.size} categories; " +
            "DTOs ${DtoRegistry.entries.size} contracts, ${dto.validCases} valid / ${dto.invalidCases} invalid; pending 0.")
        return consumed
    }
}

class EveryFixtureTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `every visible fixture is consumed semantically exactly once`() {
        val corpus = Corpus.load()
        assertEquals(corpus.enumeratedFiles, EveryFixtures.consume(corpus))
    }

    @Test
    fun `orphan files and unsupported categories or schemas fail the full gate`() = withCopy { root, schemas ->
        val directory = Corpus.load(root, schemas).cases(Category.CANONICAL).first().envelopeFile.path.parent
        val extra = directory.resolve("orphan.md")
        Files.writeString(extra, "orphan")
        assertFailsWith<CorpusException> { EveryFixtures.consume(Corpus.load(root, schemas)) }
        Files.delete(extra)

        val category = root.resolve("unsupported")
        Files.createDirectory(category)
        assertFailsWith<CorpusException> { EveryFixtures.consume(Corpus.load(root, schemas)) }
        Files.delete(category)

        val fixture = Corpus.load(root, schemas).cases(Category.FORMAT).first()
        val original = fixture.envelopeFile.bytes()
        val changed = JsonObject(fixture.envelope.toMutableMap().apply { put("schema", JsonPrimitive(2)) })
        Files.writeString(fixture.envelopeFile.path, changed.toString())
        assertFailsWith<CorpusException> { EveryFixtures.consume(Corpus.load(root, schemas)) }
        Files.write(fixture.envelopeFile.path, original)
    }

    @Test
    fun `a wrong golden in any category fails semantic consumption`() = withCopy { root, schemas ->
        val corpus = Corpus.load(root, schemas)
        for (category in Category.entries) {
            val fixture = corpus.cases(category).first { candidate -> when (category) {
                Category.RENDER -> "text" in candidate.expected["result"].objectValue()
                Category.RANKING -> candidate.expected["results"].arrayValue().isNotEmpty()
                Category.IMPORT -> "source" in candidate.expected
                Category.CANONICAL -> "bytes" in candidate.expected
                Category.PATHS -> "path" in candidate.expected
                Category.DTO -> candidate.expected["valid"].booleanValue()
                Category.LLM -> candidate.envelope["kind"].stringValue() == "decode" &&
                    "artifact" in candidate.expected["result"].objectValue()
                else -> true
            } }
            val expected = fixture.expected.toMutableMap()
            when (category) {
                Category.FORMAT -> expected["body"] = JsonPrimitive("wrong")
                Category.GRAMMAR -> expected["names"] = JsonArray(listOf(JsonPrimitive("wrong")))
                Category.RENDER -> expected["result"] = JsonObject(mapOf("text" to JsonPrimitive("wrong")))
                Category.VALIDATION -> expected["private"] = JsonPrimitive(!fixture.expected["private"].booleanValue())
                Category.RANKING -> expected["results"] = JsonArray(emptyList())
                Category.IMPORT -> expected["source"] = JsonPrimitive("wrong")
                Category.PATHS -> expected["path"] = JsonPrimitive("wrong")
                Category.CANONICAL -> expected["bytes"] = JsonPrimitive("wrong")
                Category.DTO -> {
                    expected.clear()
                    expected["valid"] = JsonPrimitive(false)
                }
                Category.LLM -> {
                    val result = fixture.expected["result"].objectValue()
                    val artifact = result["artifact"].objectValue()
                    val altered = JsonObject(artifact + ("title" to JsonPrimitive(artifact["title"].stringValue() + " wrong")))
                    expected["result"] = JsonObject(result + ("artifact" to altered))
                }
            }
            val original = fixture.envelopeFile.bytes()
            val envelope = JsonObject(fixture.envelope.toMutableMap().apply { put("expected", JsonObject(expected)) })
            Files.writeString(fixture.envelopeFile.path, envelope.toString())
            val mutated = Corpus.load(root, schemas) // Every mutation is structurally valid.
            assertFailsWith<AssertionError>(category.directory) { EveryFixtures.consume(mutated) }
            Files.write(fixture.envelopeFile.path, original)
        }
    }

    private fun withCopy(block: (Path, Path) -> Unit) {
        val corpus = Corpus.load()
        val root = temporary.newFolder("fixtures").toPath()
        Files.walk(corpus.fixtureRoot).use { paths -> paths.forEach { source ->
            val target = root.resolve(corpus.fixtureRoot.relativize(source))
            if (Files.isDirectory(source)) Files.createDirectories(target) else Files.copy(source, target)
        } }
        block(root, corpus.schemaRoot)
    }
}
