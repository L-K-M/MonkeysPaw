package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import java.util.UUID
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantSessionTest {
    @Test fun footerSupportsEveryValidatedHostSpellingWithoutReparsingWithJavaURI() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val profile = checkNotNull(h.context.profile)
        for ((base, host) in listOf(
            "https://custom_host.example:8443/v1" to "custom_host.example",
            "https://[v1.fe80::a]:8443/v1" to "[v1.fe80::a]",
            "https://[::1]:8443/v1" to "[::1]",
        )) {
            h.context = h.context.copy(profile = ProviderProfile(profile.id, profile.displayName, profile.kind, base, profile.modelID))
            val session = AssistantSession(h.service, backgroundScope, { h.context }, h.monotonic)
            assertEquals(host, session.state.value.providerHost)
            session.deactivate()
        }
        h.session.deactivate()
    }

    @Test fun explicitWriteMovesThroughDraftToReadyWithUsageElapsedAndPreflightedIdentity() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val phases = mutableListOf<AssistantPhase>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            h.session.state.collect { if (phases.lastOrNull() != it.phase) phases.add(it.phase) }
        }
        assertFalse(h.session.canRetry)
        assertFalse(h.session.canShowDiff)
        assertEquals("api.openai.com", h.session.state.value.providerHost)
        assertEquals("manual-model", h.session.state.value.modelID)
        assertTrue(h.client.calls.isEmpty())
        val reply = h.client.hold()
        h.session.write("A reusable prompt")
        runCurrent()
        assertEquals(AssistantPhase.WORKING, h.session.state.value.phase)
        assertFalse(h.session.canRetry)
        advanceTimeBy(3_001)
        runCurrent()
        assertEquals(3.0, h.session.state.value.elapsedSeconds)
        reply.complete(assistantResponse())
        runCurrent()
        val ready = h.session.state.value
        assertEquals(listOf(AssistantPhase.IDLE, AssistantPhase.WORKING, AssistantPhase.DRAFT, AssistantPhase.READY), phases)
        assertEquals(AssistantTokenUsage(11, 7), ready.usage)
        assertEquals(3.001, ready.elapsedSeconds)
        assertNotNull(ready.candidate?.content?.document?.frontMatter?.id)
        assertTrue(h.session.isCandidateCurrent)
        assertTrue(h.session.canRetry)
        assertTrue(h.session.canShowDiff)
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(ready.elapsedSeconds, h.session.state.value.elapsedSeconds)
        h.session.deactivate()
    }

    @Test fun failedStartClearsPriorCandidateResultsTranscriptUsageAndTimeButKeepsInstruction() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.session.editInstruction("Keep this instruction")
        h.client.answer(assistantResponse("Use {{topic}} and {{bad name}}"))
        h.session.write("Brief")
        runCurrent()
        assertNotNull(h.session.state.value.candidate)
        assertTrue(h.session.state.value.issues.isNotEmpty())
        h.session.review()
        runCurrent()
        val failed = h.session.state.value
        assertEquals(AssistantPhase.FAILED, failed.phase)
        assertEquals(AssistantFailure.NoEditor, failed.failure)
        assertNull(failed.artifact)
        assertNull(failed.review)
        assertNull(failed.candidate)
        assertNull(failed.usage)
        assertTrue(failed.selectedFindings.isEmpty())
        assertTrue(failed.issues.isEmpty())
        assertTrue(failed.transcript.isEmpty())
        assertFalse(failed.isStale)
        assertEquals(0.0, failed.elapsedSeconds)
        assertEquals("Keep this instruction", failed.instruction)
        assertEquals("api.openai.com", failed.providerHost)
        h.session.showDiff()
        h.session.retryWithFeedback("Retry")
        runCurrent()
        assertEquals(1, h.client.calls.size)
        h.session.deactivate()
    }

    @Test fun failedStartStopsSupersededTimerAndDropsItsLateReply() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val reply = h.client.hold()
        h.session.write("Brief")
        runCurrent()
        advanceTimeBy(3_001)
        runCurrent()
        assertEquals(3.0, h.session.state.value.elapsedSeconds)
        h.session.improve()
        assertEquals(AssistantFailure.NoEditor, h.session.state.value.failure)
        assertEquals(0.0, h.session.state.value.elapsedSeconds)
        advanceTimeBy(7_000)
        reply.complete(assistantResponse())
        runCurrent()
        assertEquals(AssistantPhase.FAILED, h.session.state.value.phase)
        assertEquals(0.0, h.session.state.value.elapsedSeconds)
        assertTrue(h.session.state.value.transcript.isEmpty())
        assertNull(h.session.state.value.artifact)
        h.session.deactivate()
    }

    @Test fun invalidArtifactsRemainDraftAndWarningsKeepPlaceholderDiffAvailable() = runTest {
        val h = AssistantHarness(this, source = "Use {{old}}.")
        h.configure()
        h.client.answer(assistantResponse("Unclosed {{topic"))
        h.session.improve()
        runCurrent()
        assertEquals(AssistantPhase.DRAFT, h.session.state.value.phase)
        assertTrue(h.session.state.value.issues.any { it.severity == PromptIssueSeverity.ERROR })
        assertNull(h.session.state.value.candidate)
        assertFalse(h.session.isCandidateCurrent)
        h.client.answer(assistantResponse("Use {{new}}. {{bad name}}"))
        h.session.retryWithFeedback("Close the token")
        runCurrent()
        assertTrue(h.session.state.value.issues.any { it.severity == PromptIssueSeverity.WARNING })
        assertTrue(h.session.isCandidateCurrent)
        assertEquals(listOf(PlaceholderChange.Renamed("old", "new")), h.session.state.value.diff?.placeholderWarnings)
        h.session.deactivate()
    }

    @Test fun reviewFindingsAreBoundToExactSourceAndOnlySelectedFindingsGoToImprove() = runTest {
        val source = "Use sources.\n😀 Cafe\u0301\n{{bad name}}"
        val h = AssistantHarness(this, source = source)
        h.configure()
        val review = LlmOutputDecoder.review("""{"summary":"Review","findings":[{"severity":"high","criterion":"clarity","quote":"Cafe\u0301","problem":"Vague","suggestion":"Clarify"},{"severity":"low","criterion":"context","quote":"Café","problem":"Other","suggestion":"Explain"}]}""", source)
        h.client.answer(AssistantResponse(AssistantOutput.Review(review)))
        h.session.review()
        runCurrent()
        assertEquals(AssistantPhase.DRAFT, h.session.state.value.phase)
        assertNull(h.session.state.value.candidate)
        assertTrue(h.session.state.value.issues.any { it.code == PromptIssueCode.INVALID_PLACEHOLDER })
        val start = "Use sources.\n😀 ".encodeToByteArray().size
        assertEquals(LlmReview.QuoteMatch.Matched(start, start + "Cafe\u0301".encodeToByteArray().size), h.session.highlightFinding(0))
        assertNull(h.session.highlightFinding(1))
        h.session.toggleFinding(0)
        h.session.toggleFinding(0)
        h.session.toggleFinding(1)
        h.session.editInstruction("Be precise")
        h.session.improve()
        runCurrent()
        val request = h.client.calls.last().request.action as AssistantAction.Improve
        assertEquals(listOf(review.findings[1]), request.selectedFindings)
        assertEquals("Be precise", request.instruction)
        assertEquals(source, request.source)
        h.session.deactivate()
    }

    @Test fun bufferChangesRemoveReviewSelectionsAndHighlightsEvenWhenTextReturns() = runTest {
        val h = AssistantHarness(this, source = "Use sources.")
        h.configure()
        val finding = LlmReview.Finding(LlmRubricCriterion.CLARITY, LlmReviewSeverity.HIGH, "sources", "Vague", "Explain",
            LlmReview.QuoteMatch.Matched(4, 11))
        h.client.answer(AssistantResponse(AssistantOutput.Review(LlmReview("Review", listOf(finding)))))
        h.session.review()
        runCurrent()
        h.session.toggleFinding(0)
        assertEquals(setOf(0), h.session.state.value.selectedFindings)
        h.edit("Different", notify = false)
        h.edit("Use sources.", notify = false)
        assertNull(h.session.highlightFinding(0))
        assertTrue(h.session.state.value.selectedFindings.isEmpty())
        h.session.deactivate()
    }

    @Test fun retryRetainsConversationButSnapshotsCurrentBufferAndInstructionWithFreshBudget() = runTest {
        for (kind in ProviderKind.entries) {
            val h = AssistantHarness(this, kind, "Original template")
            h.configure()
            h.session.editInstruction("Clarify it")
            h.session.improve()
            runCurrent()
            val transcript = h.session.state.value.transcript
            val firstDeadline = h.client.calls.single().deadline
            advanceTimeBy(5_000)
            h.edit("Current unsaved {{topic}}")
            h.session.editInstruction("New instruction")
            h.session.retryWithFeedback("Use </feedback> the latest")
            runCurrent()
            val call = h.client.calls.last()
            assertEquals(transcript, call.request.transcript)
            assertEquals("Current unsaved {{topic}}", (call.request.action as AssistantAction.Improve).source)
            assertEquals("New instruction", call.request.action.instruction)
            assertEquals(firstDeadline + 5_000_000_000L, call.deadline)
            assertEquals("Use </feedback> the latest", call.request.feedback)
            assertEquals(h.context.editor, h.session.state.value.candidate?.context?.editor)
            assertEquals(4, h.session.state.value.transcript.size)
            h.session.deactivate()
        }
    }

    @Test fun retryRechecksPrivateBufferBeforeSendingAnyRetainedTranscript() = runTest {
        val h = AssistantHarness(this, source = "Original")
        h.configure()
        h.session.improve()
        runCurrent()
        h.edit("---\nprivate: true\n---\nSensitive")
        h.session.retryWithFeedback("Try again")
        runCurrent()
        assertEquals(AssistantFailure.Assistant(AssistantError.PrivatePrompt), h.session.state.value.failure)
        assertEquals(1, h.client.calls.size)
        assertNull(h.session.state.value.candidate)
        assertTrue(h.session.state.value.transcript.isEmpty())
        h.session.deactivate()
    }

    @Test fun writeFeedbackAndDiffRetainIdentityButANewWriteGetsFreshIdentity() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.session.write("Original brief")
        runCurrent()
        val first = h.session.state.value.candidate?.content?.document?.frontMatter?.id
        val transcript = h.session.state.value.transcript
        h.session.retryWithFeedback("Shorten it")
        runCurrent()
        assertEquals(first, h.session.state.value.candidate?.content?.document?.frontMatter?.id)
        assertEquals(transcript, h.client.calls.last().request.transcript)
        assertTrue(h.session.state.value.transcript.last().content.contains("Changed the prompt."))
        h.session.showDiff()
        runCurrent()
        assertEquals(first, h.session.state.value.candidate?.content?.document?.frontMatter?.id)
        assertEquals(2, h.client.calls.size)
        h.session.write("Another brief")
        runCurrent()
        assertNotEquals(first, h.session.state.value.candidate?.content?.document?.frontMatter?.id)
        h.session.deactivate()
    }

    @Test fun providerFailuresDoNotRetryAutomaticallyAndKeepUserTurns() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.client.fail(AssistantError.RateLimited(9.0))
        h.session.write("Brief")
        runCurrent()
        val original = h.session.state.value.transcript.single()
        assertEquals(AssistantFailure.Assistant(AssistantError.RateLimited(9.0)), h.session.state.value.failure)
        h.client.fail(AssistantError.Authentication)
        h.session.retryWithFeedback("Try again")
        runCurrent()
        assertEquals(original, h.session.state.value.transcript.first())
        assertEquals(2, h.session.state.value.transcript.size)
        assertEquals(2, h.client.calls.size)
        h.session.retryWithFeedback("Third try")
        runCurrent()
        assertEquals(4, h.session.state.value.transcript.size)
        assertEquals(AssistantPhase.READY, h.session.state.value.phase)
        h.session.deactivate()
    }

    @Test fun bufferEditDuringRequestKeepsArtifactAsStaleDraftUntilExplicitFreshDiff() = runTest {
        val h = AssistantHarness(this, source = "Original {{topic}}")
        h.configure()
        val reply = h.client.hold()
        h.session.improve()
        runCurrent()
        h.edit("Newer {{topic}}")
        reply.complete(assistantResponse())
        runCurrent()
        assertEquals(AssistantPhase.DRAFT, h.session.state.value.phase)
        assertNotNull(h.session.state.value.artifact)
        assertTrue(h.session.state.value.isStale)
        assertNull(h.session.state.value.candidate)
        h.session.showDiff()
        runCurrent()
        assertTrue(h.session.isCandidateCurrent)
        assertEquals("Newer {{topic}}", h.session.state.value.candidate?.context?.editor?.source)
        assertTrue(checkNotNull(h.session.state.value.diff).body.any { it.text.contains("Newer") })
        h.session.deactivate()
    }

    @Test fun awayAndBackBufferEditWithdrawsCandidateWithoutNotificationsAndShowDiffPreflightsLoadedID() = runTest {
        val h = AssistantHarness(this, source = "Original")
        h.configure()
        h.session.improve()
        runCurrent()
        assertTrue(h.session.isCandidateCurrent)
        val original = h.context.editor
        h.edit("Changed", notify = false)
        h.edit("Original", notify = false)
        assertEquals(original?.source, h.context.editor?.source)
        assertNotEquals(original?.revision, h.context.editor?.revision)
        assertFalse(h.session.isCandidateCurrent)
        h.session.contextChanged()
        assertNull(h.session.state.value.candidate)
        val loaded = ch.lkmc.monkeyspaw.core.domain.ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        h.context = h.context.copy(editor = h.context.editor?.copy(loadedID = loaded))
        h.session.showDiff()
        runCurrent()
        assertTrue(h.session.isCandidateCurrent)
        assertEquals(loaded, h.session.state.value.candidate?.content?.document?.frontMatter?.id)
        h.session.deactivate()
    }

    @Test fun freshDiffRevalidatesInvalidPrivateConflictedAndBusyBuffers() = runTest {
        for (source in listOf("Broken {{topic", "---\nprivate: true\n---\nSensitive")) {
            val h = AssistantHarness(this, source = "Original")
            h.configure()
            h.session.improve()
            runCurrent()
            h.edit(source)
            h.session.showDiff()
            runCurrent()
            assertNull(h.session.state.value.candidate)
            if (source.startsWith("Broken")) {
                assertEquals(AssistantPhase.DRAFT, h.session.state.value.phase)
                assertTrue(h.session.state.value.issues.any { it.severity == PromptIssueSeverity.ERROR })
            } else assertEquals(AssistantFailure.Assistant(AssistantError.PrivatePrompt), h.session.state.value.failure)
            h.session.deactivate()
        }
    }

    @Test fun guardAvailabilityPreservesReadyPreviewButBlocksEveryNewActionBeforeSecretRead() = runTest {
        for (intent in 0..4) {
            val h = AssistantHarness(this, source = "Original")
            h.configure()
            h.session.improve()
            runCurrent()
            h.context = h.context.copy(editor = h.context.editor?.copy(availability = AssistantEditorAvailability.BUSY))
            h.session.contextChanged()
            assertTrue(h.session.isCandidateCurrent)
            val reads = h.provider.secrets.reads.size
            when (intent) {
                0 -> h.session.write("Brief")
                1 -> h.session.review()
                2 -> h.session.improve()
                3 -> h.session.retryWithFeedback("Feedback")
                else -> h.session.showDiff()
            }
            runCurrent()
            assertEquals(AssistantFailure.EditorBusy, h.session.state.value.failure)
            assertNull(h.session.state.value.candidate)
            assertEquals(reads, h.provider.secrets.reads.size)
            assertEquals(1, h.client.calls.size)
            h.session.deactivate()
        }
    }

    @Test fun cancelCloseRejectDeactivateAndNewGenerationNeverReviveHeldReplies() = runTest {
        for (intent in 0..4) {
            val h = AssistantHarness(this)
            h.configure()
            val reply = h.client.hold()
            h.session.write("Old")
            runCurrent()
            when (intent) {
                0 -> h.session.cancel()
                1 -> h.session.close()
                2 -> h.session.reject()
                3 -> h.session.deactivate()
                else -> h.session.write("New")
            }
            reply.complete(assistantResponse("Old candidate"))
            runCurrent()
            if (intent == 4) assertEquals("Use {{topic}}.", h.session.state.value.artifact?.body)
            else {
                assertEquals(AssistantPhase.IDLE, h.session.state.value.phase)
                assertNull(h.session.state.value.artifact)
                assertTrue(h.session.state.value.transcript.isEmpty())
            }
            h.session.deactivate()
        }
    }

    @Test fun cancellationBeforeWorkerStartsDoesNotReadSecretsOrSend() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val reads = h.provider.secrets.reads.size
        h.session.write("Brief")
        h.session.cancel()
        runCurrent()
        assertEquals(reads, h.provider.secrets.reads.size)
        assertTrue(h.client.calls.isEmpty())
        assertEquals(AssistantPhase.IDLE, h.session.state.value.phase)
        h.session.deactivate()
    }

    @Test fun graphProfileCredentialSessionAndAccessTransitionsRetireConversationEvenAwayAndBack() = runTest {
        for (transition in 0..5) {
            val h = AssistantHarness(this, source = "Original")
            h.configure()
            val original = h.context
            val reply = h.client.hold()
            h.session.improve()
            runCurrent()
            when (transition) {
                0 -> h.context = original.copy(libraryID = UUID.randomUUID())
                1 -> h.context = original.copy(profile = original.profile?.let {
                    ProviderProfile(it.id, it.displayName, it.kind, it.baseURL, "changed-model", it.secretReference)
                })
                2 -> h.context = original.copy(credentialGeneration = 1)
                3 -> h.context = original.copy(editor = original.editor?.copy(session = 2))
                4 -> h.context = original.copy(access = AssistantAccessState.GROUP_VIEWER)
                else -> h.session.profileChanged()
            }
            h.session.contextChanged()
            h.context = original
            h.session.contextChanged()
            reply.complete(assistantResponse())
            runCurrent()
            assertEquals(AssistantPhase.IDLE, h.session.state.value.phase)
            assertNull(h.session.state.value.candidate)
            assertTrue(h.session.state.value.transcript.isEmpty())
            h.session.deactivate()
        }
    }

    @Test fun profileChangeDropsAlreadyQueuedReplyAndPendingPreparation() = runTest {
        for (preparing in listOf(false, true)) {
            val h = AssistantHarness(this)
            h.configure()
            val held = AssistantHeldDispatcher()
            val session = AssistantSession(h.makeService(held), backgroundScope, { h.context }, h.monotonic)
            session.write("Brief")
            held.release()
            runCurrent()
            // Credential resolution hops back to the held service worker.
            held.release()
            if (preparing) runCurrent()
            session.profileChanged()
            held.releaseAll()
            runCurrent()
            assertEquals(AssistantPhase.IDLE, session.state.value.phase)
            assertNull(session.state.value.candidate)
            session.deactivate()
            h.session.deactivate()
        }
    }

    @Test fun inlineDraftObserverCanCancelWithoutPreparingOrRevivingCandidate() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            h.session.state.collect { if (it.phase == AssistantPhase.DRAFT) h.session.close() }
        }
        h.session.write("Brief")
        runCurrent()
        assertEquals(AssistantPhase.IDLE, h.session.state.value.phase)
        assertNull(h.session.state.value.candidate)
        h.session.deactivate()
    }

    @Test fun diffFailureRetainsArtifactWithoutCandidateAndDiagnosticSurfacesRedactContent() = runTest {
        val old = (0..499).joinToString("\n") { "old $it" }
        val new = (0..499).joinToString("\n") { "new $it" }
        val h = AssistantHarness(this, source = old)
        h.configure()
        h.client.answer(assistantResponse(new))
        h.session.improve()
        runCurrent()
        assertEquals(AssistantFailure.Diff(LineDiffError.ComparisonTooComplex), h.session.state.value.failure)
        assertNotNull(h.session.state.value.artifact)
        assertNull(h.session.state.value.candidate)
        val sentinel = "sensitive-${UUID.randomUUID()}"
        h.edit(sentinel)
        h.client.answer(assistantResponse(sentinel))
        h.session.editInstruction(sentinel)
        h.session.improve()
        runCurrent()
        for (value in listOf(h.session, h.session.state.value, h.context, h.context.editor,
            h.session.state.value.candidate, AssistantCommand.Write(sentinel),
            AssistantFailure.Assistant(AssistantError.UnexpectedStop(sentinel)), h.service)) {
            assertFalse(value.toString().contains(sentinel))
        }
        val state = h.session.state.value
        assertFailsWith<UnsupportedOperationException> { (state.transcript as MutableList).clear() }
        val bytes = checkNotNull(h.context.editor?.sourceBytes)
        bytes.fill(0)
        assertEquals(sentinel, h.context.editor?.source)
        h.session.deactivate()
    }
}
