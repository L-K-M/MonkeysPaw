package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssue
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonNull

/** Semantic path consumption runs only after K2's structural gate. */
internal object PathFixtures {
    fun consume(corpus: Corpus): Set<String> {
        val files = linkedSetOf<String>()
        for (fixture in corpus.cases(Category.PATHS)) {
            check(fixture)
            for (file in fixture.files) corpusRequire(files.add(file.relativePath), "Duplicate path fixture file")
        }
        return files
    }

    fun check(fixture: FixtureCase) {
        corpusRequire(fixture.category == Category.PATHS, "Expected a paths fixture")
        val scope = when (fixture.envelope["scope"].stringValue()) {
            "user" -> SyncPathValidator.Scope.USER
            "group" -> SyncPathValidator.Scope.GROUP
            else -> throw CorpusException("Unknown path scope")
        }
        val input = fixture.source().utf8()
        val expected = fixture.expected
        val label = fixture.envelopeFile.relativePath
        if ("issue" in expected) {
            val issue = expected["issue"].objectValue()
            val actual = assertFailsWith<SyncPathIssue>(label) { SyncPathValidator.validate(input, scope) }
            assertEquals(issue["code"].stringValue(), actual.code.wireCode, label)
            val segment = if (issue["segment"] == JsonNull) null else issue["segment"].integerValue().intValueExact()
            assertEquals(segment, actual.segmentIndex, label)
            return
        }
        val actual = SyncPathValidator.validate(input, scope)
        assertUtf8Equal(expected["path"].stringValue(), actual.path, label)
        assertUtf8Equal(expected["path_key"].stringValue(), actual.pathKey, label)
    }
}
