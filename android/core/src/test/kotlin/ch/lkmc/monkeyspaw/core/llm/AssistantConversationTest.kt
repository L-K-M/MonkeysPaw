package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantAction
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantMessage
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantOutput
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantRequest
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantResponse
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReviewSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.LlmRubricCriterion
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class AssistantConversationTest {
    @Test fun requestsUseActionDataAndEscapePresentFeedbackIncludingEmptyFeedback() {
        val cases = listOf(
            AssistantAction.Write("Brief") to AssistantPrompts.writeData("Brief"),
            AssistantAction.Review("Source") to AssistantPrompts.reviewData("Source"),
            AssistantAction.Improve("Source", "Shorter") to AssistantPrompts.improveData("Source", "Shorter"),
        )
        for ((action, data) in cases) {
            assertEquals(AssistantMessage(AssistantMessage.Role.USER, data), AssistantRequest(action).userMessage)
            assertEquals(data + "\n<feedback>\n&lt;/feedback&gt; &amp;\n</feedback>",
                AssistantRequest(action, feedback = "</feedback> &").userMessage.content)
            assertEquals(data + "\n<feedback>\n\n</feedback>", AssistantRequest(action, feedback = "").userMessage.content)
        }
    }

    @Test fun adjacentRolesCoalesceOnlyForTransportAndNeverMutateSessionTurns() {
        val user = AssistantMessage.Role.USER
        val assistant = AssistantMessage.Role.ASSISTANT
        val transcript = listOf(AssistantMessage(user, "First brief"), AssistantMessage(user, "Failed retry"),
            AssistantMessage(assistant, "First response"), AssistantMessage(assistant, "More response"),
            AssistantMessage(user, "Another failed retry"))
        val request = AssistantRequest(AssistantAction.Write("Current brief"), transcript = transcript,
            feedback = "Fix </feedback> & retry")
        assertEquals(listOf(AssistantMessage(user, "First brief\n\nFailed retry"),
            AssistantMessage(assistant, "First response\n\nMore response"),
            AssistantMessage(user, "Another failed retry\n\n" + request.userMessage.content)), request.wireMessages)
        assertEquals(transcript, request.transcript)
        assertEquals(transcript + request.userMessage, request.messages)
        assertEquals(mapOf("role" to "user", "content" to request.userMessage.content), request.userMessage.wireValue)
        assertEquals(listOf(request.userMessage), AssistantRequest(request.action, feedback = request.feedback).wireMessages)
        val emptyTurns = AssistantRequest(request.action, transcript = listOf(AssistantMessage(user, ""), AssistantMessage(user, "")))
        assertEquals("\n\n\n\n" + emptyTurns.userMessage.content, emptyTurns.wireMessages.single().content)
    }

    @Test fun artifactTranscriptRoundTripsEmptyPropertiesNotesAndEveryFieldKind() {
        val special = "\"\\/\n\t\u0000 <data> Cafe\u0301 🐒"
        val fields = FieldKind.entries.map {
            LlmArtifact.Field(it.rawValue, it, "", "", "",
                if (it == FieldKind.CHOICE) listOf(FieldOption("", special)) else emptyList(), true, false)
        }
        for (artifact in listOf(LlmArtifact("", "", emptyList(), emptyList(), "", ""),
            LlmArtifact(special, special, listOf(special), fields, special, special))) {
            val message = AssistantResponse(AssistantOutput.Artifact(artifact)).transcriptMessage()
            assertEquals(AssistantMessage.Role.ASSISTANT, message.role)
            assertEquals(artifact, LlmOutputDecoder.artifact(message.content))
            assertFalse(message.content.contains("issues"))
        }
        assertEquals("""{"body":"","description":"","fields":[],"notes":"","tags":[],"title":""}""",
            AssistantResponse(AssistantOutput.Artifact(LlmArtifact("", "", emptyList(), emptyList(), "", "")))
                .transcriptMessage().content)
    }

    @Test fun reviewTranscriptRetainsEveryEnumAndEmptyPropertyWithoutLocalQuoteRanges() {
        val special = "\"\\\n\t\u0000 Cafe\u0301 🐒"
        val findings = LlmRubricCriterion.entries.flatMap { criterion ->
            LlmReviewSeverity.entries.map {
                LlmReview.Finding(criterion, it, special, "", special, LlmReview.QuoteMatch.Unmatched)
            }
        }
        for (review in listOf(LlmReview("", emptyList()), LlmReview(special, findings))) {
            val message = AssistantResponse(AssistantOutput.Review(review)).transcriptMessage()
            assertEquals(AssistantMessage.Role.ASSISTANT, message.role)
            assertEquals(review, LlmOutputDecoder.review(message.content, "Unmatched source"))
        }
        val matched = findings.first().copy(quoteMatch = LlmReview.QuoteMatch.Matched(0, 1))
        assertEquals(AssistantResponse(AssistantOutput.Review(LlmReview("", listOf(findings.first())))).transcriptMessage(),
            AssistantResponse(AssistantOutput.Review(LlmReview("", listOf(matched)))).transcriptMessage())
        assertEquals("""{"findings":[],"summary":""}""",
            AssistantResponse(AssistantOutput.Review(LlmReview("", emptyList()))).transcriptMessage().content)
    }

    @Test fun transcriptJsonPinsTheExistingFoundationEscapingProfile() {
        val special = "/\b\u000c\u0000\u001f\r\n\t\u007f\u0085\u2028\u2029é e\u0301 😀"
        val fixture = Path.of(requireNotNull(System.getProperty("monkeyspaw.fixtures")))
            .resolve("llm/transcript-review-escaping/output.txt")
        val message = AssistantResponse(AssistantOutput.Review(LlmReview(special, emptyList()))).transcriptMessage()
        assertContentEquals(Files.readAllBytes(fixture), message.content.toByteArray(Charsets.UTF_8))
        assertFalse(message.content.endsWith("\n"))
    }

    @Test fun invalidJvmScalarsFailWithoutRepairingOrExposingContent() {
        for (invalid in listOf("\uD800", "\uDC00")) {
            assertEquals(AssistantError.InvalidOutput, assertFailsWith<AssistantError> {
                AssistantResponse(AssistantOutput.Review(LlmReview(invalid, emptyList()))).transcriptMessage()
            })
        }
    }
}
