package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantAcceptanceSessionTest {
    @Test fun pureTokenIsRetiredByBufferChangeAndCannotCompleteAnotherAcceptance() = runTest {
        val h = AssistantHarness(this, source = "Original")
        h.configure()
        h.session.improve()
        runCurrent()
        val first = assertNotNull(h.session.accept())
        assertNull(h.session.accept())
        h.edit("Newer buffer")
        assertFalse(h.session.state.value.isAccepting)
        val outcome = AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Cancelled)
        assertFalse(h.session.completeAcceptance(first.id, outcome))
        h.session.showDiff()
        runCurrent()
        val second = assertNotNull(h.session.accept())
        assertFalse(h.session.completeAcceptance(first.id, outcome))
        assertTrue(h.session.completeAcceptance(second.id, outcome))
        assertFalse(h.session.completeAcceptance(second.id, outcome))
        h.session.deactivate()
    }

    @Test fun committedOutcomeConsumesIssuedTokenAndReleasesRetainedWriteIdentity() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.session.write("Brief")
        runCurrent()
        val acceptance = assertNotNull(h.session.accept())
        val library = ServiceHarness()
        val result = library.library.create(acceptance.candidate.content.document, "Generated.md")
        val outcome = AssistantAcceptanceOutcome.saved(result)
        assertFalse(h.session.completeAcceptance(UUID.randomUUID(), outcome))
        assertTrue(h.session.completeAcceptance(acceptance.id, outcome))
        assertFalse(h.session.completeAcceptance(acceptance.id, outcome))
        assertEquals(AssistantPhase.SAVED, h.session.state.value.phase)
        assertEquals(result.entry.stamp, h.session.state.value.acceptanceOutcome?.committed?.entry?.stamp)
        h.session.showDiff()
        runCurrent()
        assertNotEquals(result.entry.document.frontMatter.id, h.session.state.value.candidate?.content?.document?.frontMatter?.id)
        h.session.deactivate()
    }

    @Test fun pendingAcceptanceBlocksProviderAndDiffIntentsAndRetirementDoesNotProbeDiscardedGraph() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        var unavailable = false
        val session = AssistantSession(h.service, backgroundScope, {
            check(!unavailable)
            h.context
        }, h.monotonic)
        session.write("Brief")
        runCurrent()
        assertNotNull(session.accept())
        session.write("Duplicate")
        session.review()
        session.improve()
        session.retryWithFeedback("Duplicate")
        session.showDiff()
        runCurrent()
        assertEquals(1, h.client.calls.size)
        unavailable = true
        session.deactivate()
        assertEquals(AssistantPhase.IDLE, session.state.value.phase)
        assertFalse(session.state.value.isAccepting)
        h.session.deactivate()
    }
}
