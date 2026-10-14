package ch.lkmc.monkeyspaw.core.domain.llm

import java.util.UUID
import kotlin.test.*

internal class AssistantModelPickerTest {
    private val suggestions = listOf(ModelDescriptor("suggestion", "Display name"))

    @Test fun manualIDsSurviveFailedUnsupportedCancelledAndEmptyTests() {
        val draft = ProviderDraft(modelID = "unlisted-model")
        val picker = AssistantModelPickerState(draft)
        assertTrue(picker.receive(ConnectionTestResult.Ok(suggestions), picker.beginTest()))
        for (result in listOf(ConnectionTestResult.Network, ConnectionTestResult.UnsupportedListing,
            ConnectionTestResult.Authentication, ConnectionTestResult.Timeout, ConnectionTestResult.InvalidResponse,
            ConnectionTestResult.Cancelled)) {
            assertTrue(picker.receive(result, picker.beginTest()))
            assertEquals(suggestions, picker.availableModels)
            assertEquals("unlisted-model", picker.manualModelID)
            assertEquals(result, picker.lastResult)
            assertFalse(picker.isTesting)
        }
        assertTrue(picker.receive(ConnectionTestResult.Ok(emptyList()), picker.beginTest()))
        assertEquals(emptyList(), picker.availableModels)
        assertEquals("unlisted-model", picker.manualModelID)
        picker.update(draft.copy(modelID = "another-unlisted-model"))
        assertEquals("another-unlisted-model", picker.manualModelID)
    }

    @Test fun everyDraftEditClearsSuggestionsAndRejectsLateReplies() {
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("key"))
        val edits = listOf(draft.copy(id = ProviderProfileID()), draft.copy(displayName = "Renamed"),
            draft.copy(kind = ProviderKind.OPENAI_COMPATIBLE), draft.copy(baseURL = "https://another.example/custom"),
            draft.copy(modelID = "typed-id"), draft.copy(key = ProviderKeyEdit.typed("new-key")),
            draft.copy(key = ProviderKeyEdit.Clear), draft.copy(key = ProviderKeyEdit.Keep))
        for (edit in edits) {
            val picker = AssistantModelPickerState(draft)
            picker.receive(ConnectionTestResult.Ok(suggestions), picker.beginTest())
            val pending = picker.beginTest()
            picker.update(edit)
            assertFalse(picker.receive(ConnectionTestResult.Ok(suggestions), pending))
            assertEquals(emptyList(), picker.availableModels)
            assertNull(picker.lastResult)
            assertFalse(picker.isTesting)
            assertEquals(edit.modelID, picker.manualModelID)
        }
    }

    @Test fun byteDistinctUnicodeTextAndKeyEditsInvalidateReplies() {
        val draft = ProviderDraft(displayName = "é", baseURL = "https://example.com/é", modelID = "é",
            key = ProviderKeyEdit.Replace(SecretValue("é")))
        for (edit in listOf(draft.copy(displayName = "e\u0301"), draft.copy(baseURL = "https://example.com/e\u0301"),
            draft.copy(modelID = "e\u0301"), draft.copy(key = ProviderKeyEdit.Replace(SecretValue("e\u0301"))))) {
            val picker = AssistantModelPickerState(draft)
            val pending = picker.beginTest()
            picker.update(edit)
            assertFalse(picker.receive(ConnectionTestResult.Ok(suggestions), pending))
        }
    }

    @Test fun switchingAwayAndBackCannotReviveOldGeneration() {
        val draft = ProviderDraft()
        val picker = AssistantModelPickerState(draft)
        val old = picker.beginTest()
        picker.update(ProviderDraft())
        picker.update(draft)
        val current = picker.beginTest()
        assertFalse(picker.receive(ConnectionTestResult.Ok(listOf(ModelDescriptor("old"))), old))
        assertTrue(picker.isTesting)
        assertTrue(picker.receive(ConnectionTestResult.Ok(suggestions), current))
        assertEquals(suggestions, picker.availableModels)
    }

    @Test fun newerTestRejectsOldAndRepeatedDeliveries() {
        val picker = AssistantModelPickerState(ProviderDraft())
        val first = picker.beginTest()
        val second = picker.beginTest()
        assertFalse(picker.receive(ConnectionTestResult.Ok(emptyList()), first))
        assertTrue(picker.receive(ConnectionTestResult.Ok(suggestions), second))
        assertFalse(picker.receive(ConnectionTestResult.Ok(emptyList()), second))
        assertEquals(suggestions, picker.availableModels)
    }

    @Test fun unchangedDraftAndEquivalentKeyKeepPendingTestAndSuggestions() {
        val draft = ProviderDraft(key = ProviderKeyEdit.Replace(SecretValue("same-key")))
        val picker = AssistantModelPickerState(draft)
        picker.receive(ConnectionTestResult.Ok(suggestions), picker.beginTest())
        val pending = picker.beginTest()
        picker.update(draft.copy(key = ProviderKeyEdit.Replace(SecretValue("same-key"))))
        assertTrue(picker.isTesting)
        assertEquals(suggestions, picker.availableModels)
        assertTrue(picker.receive(ConnectionTestResult.Network, pending))
    }

    @Test fun cancellationRetainsSuggestionsAndManualIDButInvalidatesGeneration() {
        val picker = AssistantModelPickerState(ProviderDraft(modelID = "manual"))
        picker.receive(ConnectionTestResult.Ok(suggestions), picker.beginTest())
        val pending = picker.beginTest()
        picker.cancelTest()
        assertFalse(picker.receive(ConnectionTestResult.Ok(emptyList()), pending))
        assertEquals(ConnectionTestResult.Cancelled, picker.lastResult)
        assertEquals(suggestions, picker.availableModels)
        assertEquals("manual", picker.manualModelID)
        picker.cancelTest()
        assertEquals(ConnectionTestResult.Cancelled, picker.lastResult)
    }

    @Test fun diagnosticsAndSnapshotsDoNotLeakOrAllowMutation() {
        val sentinel = UUID.randomUUID().toString()
        val picker = AssistantModelPickerState(ProviderDraft(displayName = sentinel, baseURL = sentinel,
            modelID = sentinel, key = ProviderKeyEdit.Replace(SecretValue(sentinel))))
        val input = mutableListOf(ModelDescriptor(sentinel, sentinel))
        val result = ConnectionTestResult.Ok(input)
        val request = picker.beginTest()
        picker.receive(result, request)
        input.clear()
        assertEquals(1, picker.availableModels.size)
        assertFailsWith<UnsupportedOperationException> { (picker.availableModels as MutableList).clear() }
        for (value in listOf(picker, result, request)) assertFalse(sentinel in value.toString())
    }
}
