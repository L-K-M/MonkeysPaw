package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class ArtifactDiffTest {
    @Test fun ordinaryBytesReconstructBothExactVersionsWithoutAnAssistantCandidate() {
        val original = "\uFEFF---\r\n# exact header\r\ntitle: 'Café'\r\n---\r\n😀 {{old}}\r\n".encodeToByteArray()
        val candidate = "---\ntitle: Cafe\u0301\n---\n😀 {{new}}".encodeToByteArray()
        val diff = ArtifactDiff.compare(original, candidate)
        assertContentEquals(original, project(diff, LineDiffLine.Kind.ADDED))
        assertContentEquals(candidate, project(diff, LineDiffLine.Kind.REMOVED))
        assertEquals(listOf(PlaceholderChange.Renamed("old", "new")), diff.placeholderWarnings)
        val row = diff.body.first()
        row.bytes.fill(0)
        assertContentEquals(original, project(diff, LineDiffLine.Kind.ADDED))
    }

    @Test fun ordinaryBytesRejectInvalidUtf8FutureFormatAndInvalidDocuments() {
        val valid = "body".encodeToByteArray()
        for (invalid in listOf(byteArrayOf(-1), "---\nformat: 999\n---\nfuture".encodeToByteArray(),
            "---\nfavorite: nope\n---\ninvalid".encodeToByteArray())) {
            assertFailsWith<Exception> { ArtifactDiff.compare(invalid, valid) }
            assertFailsWith<Exception> { ArtifactDiff.compare(valid, invalid) }
        }
    }

    @Test fun separateSectionsReconstructTheCanonicalMergedFile() {
        val original = PromptCodec.parse("---\n# discarded comment\ntitle: Before\nprivate: false\nmodel: {nested: [1, false]}\n---\n😀 {{old}}\r\n", "Original.md")
        val candidate = ready(ArtifactMerge.improve(artifact("😀 {{new}}\n"), original))
        val diff = ArtifactDiff.compare(original, candidate)
        assertContentEquals(PromptCodec.write(original).toByteArray(), project(diff, LineDiffLine.Kind.ADDED))
        assertContentEquals(candidate.canonicalBytes, project(diff, LineDiffLine.Kind.REMOVED))
        assertEquals(listOf(PlaceholderChange.Renamed("old", "new")), diff.placeholderWarnings)
        assertTrue(diff.frontMatter.all { it.placeholderWarnings.isEmpty() })
        repeat(10) { assertEquals(diff, ArtifactDiff.compare(original, candidate)) }
        assertFailsWith<UnsupportedOperationException> { (diff.body as MutableList).clear() }
        assertFailsWith<UnsupportedOperationException> { (diff.placeholderWarnings as MutableList).clear() }
        assertFailsWith<UnsupportedOperationException> { (diff.body.first().placeholderWarnings as MutableList).clear() }
    }

    @Test fun writeUsesEmptyBaselineAndWholeGrammarExcludesFalseWarnings() {
        val candidate = ready(ArtifactMerge.write(artifact("😀 \\{{fake}} {{ invalid\n{{phantom}}}}\n{{real}} {{ real }}\n"),
            ULID.parse("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!!))
        val diff = ArtifactDiff.compare(null, candidate)
        assertTrue((diff.frontMatter + diff.body).all { it.kind == LineDiffLine.Kind.ADDED })
        assertEquals(listOf(PlaceholderChange.Added("real")), diff.placeholderWarnings)
        assertEquals(listOf(PlaceholderChange.Added("real")), diff.body.last().placeholderWarnings)
        assertTrue(diff.body.dropLast(1).all { it.placeholderWarnings.isEmpty() })
        assertContentEquals(candidate.canonicalBytes, project(diff, LineDiffLine.Kind.REMOVED))
    }

    private fun artifact(body: String) = LlmArtifact("After", "", emptyList(), emptyList(), body, "Not persisted")
    private fun ready(result: ArtifactMergeResult) = (result as ArtifactMergeResult.Ready).candidate
    private fun project(diff: ArtifactDiff, excluding: LineDiffLine.Kind) =
        (diff.frontMatter + diff.body).filter { it.kind != excluding }.flatMap { it.bytes.asIterable() }.toByteArray()
}
