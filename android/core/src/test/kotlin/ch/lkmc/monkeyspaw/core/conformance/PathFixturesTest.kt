package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class PathFixturesTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `every portable path fixture is consumed semantically with structural accounting`() {
        val corpus = Corpus.load()
        val cases = corpus.cases(Category.PATHS)
        assertTrue(cases.isNotEmpty())
        val files = PathFixtures.consume(corpus)
        assertEquals(cases.flatMap { it.files }.map { it.relativePath }.toSet(), files)
        assertEquals(cases.size * 2, files.size)
        println("Consumed ${cases.size} sync path fixtures (${files.size} files).")
    }

    @Test
    fun `canonical equivalent but byte different golden paths and keys fail`() {
        val fixture = Corpus.load().cases(Category.PATHS).single { it.name == "unicode-nfd" }
        for ((member, value) in mapOf("path" to "Cafe\u0301/E\u0301.md", "path_key" to "cafe\u0301/e\u0301.md")) {
            assertFails { PathFixtures.check(withExpected(fixture, JsonObject(fixture.expected + (member to JsonPrimitive(value))))) }
        }
    }

    @Test
    fun `wrong first failure or nullable segment cannot pass`() {
        val fixture = Corpus.load().cases(Category.PATHS).single { it.name == "nul" }
        val issue = fixture.expected["issue"].objectValue()
        for ((member, value) in mapOf("code" to JsonPrimitive("path.backslash"), "segment" to JsonPrimitive(1))) {
            val expected = JsonObject(mapOf("issue" to JsonObject(issue + (member to value))))
            assertFails { PathFixtures.check(withExpected(fixture, expected)) }
        }
    }

    @Test
    fun `source bytes are never trimmed or stripped of a leading BOM`() {
        val fixture = Corpus.load().cases(Category.PATHS).single { it.name == "basic" }
        for (suffix in listOf("\n", "\r\n", " ")) {
            assertFails { PathFixtures.check(withSource(fixture, fixture.source().utf8() + suffix)) }
        }
        assertFails { PathFixtures.check(withSource(fixture, "\uFEFF" + fixture.source().utf8())) }
        val trailing = Corpus.load().cases(Category.PATHS).single { it.name == "trailing-space-file" }
        assertFails { PathFixtures.check(withSource(trailing, trailing.source().utf8().removeSuffix(" "))) }
    }

    private fun withExpected(fixture: FixtureCase, expected: JsonObject): FixtureCase =
        fixture.copy(envelope = JsonObject(fixture.envelope + ("expected" to expected)))

    private fun withSource(fixture: FixtureCase, text: String): FixtureCase {
        val file = temporary.newFile().toPath()
        Files.writeString(file, text)
        return fixture.copy(sources = mapOf("path.txt" to FixtureFile("path.txt", file)))
    }
}
