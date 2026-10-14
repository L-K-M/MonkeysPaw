package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class LlmOutputDecoderTest {
    @Test fun parserCountsEmptyContainersAndScalarsIndependentlyOfRecovery() {
        for (depth in listOf(Limits.llmJSONNestingCap, Limits.llmJSONNestingCap + 1)) {
            val inputs = listOf(
                "{\"x\":" + "[".repeat(depth - 1) + "]".repeat(depth - 1) + "}",
                "{\"x\":" + "[".repeat(depth - 1) + "0" + "]".repeat(depth - 1) + "}",
                "{\"x\":".repeat(depth - 1) + "{}" + "}".repeat(depth - 1),
            )
            for (input in inputs) {
                val bytes = input.toByteArray(Charsets.UTF_8)
                if (depth == Limits.llmJSONNestingCap) {
                    LlmJsonParser(bytes).parse()
                    assertContentEquals(bytes, LlmJsonRecovery.objectIn(input))
                } else {
                    assertFailsWith<AssistantError.InvalidOutput> { LlmJsonParser(bytes).parse() }
                    assertFailsWith<AssistantError.InvalidOutput> { LlmJsonRecovery.objectIn(input) }
                }
            }
        }
    }

    @Test fun jvmLoneSurrogatesNeverBecomeRepairedOutputOrSource() {
        for (value in listOf("\uD800", "\uDC00")) {
            assertFailsWith<AssistantError.InvalidOutput> { LlmOutputDecoder.artifact(value) }
            assertFailsWith<AssistantError.InvalidOutput> { LlmOutputDecoder.review("{}", value) }
        }
    }

    @Test fun longRepeatedQuotesMatchFirstExactByteRange() {
        val quote = "a".repeat(50_000) + "b"
        val source = "😀" + "a".repeat(150_000) + "b" + quote
        val output = """{"summary":"","findings":[{"criterion":"clarity","severity":"low","quote":"$quote","problem":"","suggestion":""}]}"""
        assertEquals(LlmReview.QuoteMatch.Matched(100_004, 150_005),
            LlmOutputDecoder.review(output, source).findings.single().quoteMatch)
    }

    @Test fun schemaBytesAreFreshDefensiveValues() {
        val expected = LlmArtifact.jsonSchema
        LlmArtifact.jsonSchema.fill(0)
        assertContentEquals(expected, LlmArtifact.jsonSchema)
    }

    @Test fun rawAndEscapedBomSegmentsMatchSwiftReferenceDecoding() {
        val wire = """{"title":"a\n﻿b","description":"","tags":[],"fields":[],"body":"","notes":""}"""
        assertEquals("a\nb", LlmOutputDecoder.artifact(wire).title)
        val escaped = """{"title":"\uFEFFb","description":"","tags":[],"fields":[],"body":"","notes":""}"""
        assertEquals("\uFEFFb", LlmOutputDecoder.artifact(escaped).title)
    }

    @Test fun bomPrefixedNumberFragmentsMatchSwiftArrayPreambleRecovery() {
        val wire = """{"title":"later","description":"","tags":[],"fields":[],"body":"","notes":""}"""
        for (token in listOf("1", "true", "false")) {
            assertEquals("later", LlmOutputDecoder.artifact("[{\"ignored\":\uFEFF$token}]" + wire).title)
        }
    }
}
