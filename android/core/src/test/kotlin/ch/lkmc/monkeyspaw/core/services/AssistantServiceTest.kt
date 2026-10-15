package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantServiceTest {
    @Test fun timerClockFailureCompletesWithSanitizedFailureInsteadOfEscapingScope() = runTest {
        val h = AssistantHarness(this)
        val operation = AssistantOperation<Unit>()
        operation.start(h.worker, h.worker, { throw IllegalStateException("Clock unavailable") }) { awaitCancellation() }
        val awaiting = async { runCatching { operation.await() } }
        try {
            runCurrent()
            assertTrue(awaiting.isCompleted, "Clock failure left the operation pending")
            assertEquals(AssistantFailure.Assistant(AssistantError.Transport(HttpTransportError.NetworkFailure)),
                awaiting.await().exceptionOrNull())
        } finally { operation.cancel() }
    }

    @Test fun readOnlySourceTextCannotBypassActionOrPreparationGates() = runTest {
        val h = AssistantHarness(this, source = "Original")
        h.configure()
        for (reason in SourceReadOnlyReason.entries) {
            val source = if (reason == SourceReadOnlyReason.FUTURE_FORMAT) "---\nformat: 2\n---\nFuture" else "Original"
            val context = h.context.copy(editor = h.context.editor?.copy(source = source, readOnlyReason = reason))
            val reads = h.provider.secrets.reads.size
            for (command in listOf(AssistantCommand.Review, AssistantCommand.Improve("Clarify"))) {
                assertEquals(AssistantFailure.ReadOnly(reason), assertFailsWith<AssistantFailure> {
                    h.service.perform(command, context).await()
                })
                assertEquals(AssistantFailure.ReadOnly(reason), assertFailsWith<AssistantFailure> {
                    h.service.prepare(assistantArtifact(), command, context).await()
                })
            }
            assertEquals(reads, h.provider.secrets.reads.size)
            assertTrue(h.client.calls.isEmpty())
        }
        h.session.deactivate()
    }

    @Test fun rawModelErrorsAndCapFailuresAreReturnedAsConnectionResults() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val draft = ProviderDraft(checkNotNull(h.service.selectedProfile))
        h.client.onPage = { throw AssistantError.Transport(HttpTransportError.DeadlineExceeded) }
        assertEquals(ConnectionTestResult.Timeout, h.service.testConnection(draft).await())
        h.client.onPage = { throw CancellationException("Transport stopped").apply { initCause(HttpTransportError.DeadlineExceeded) } }
        assertEquals(ConnectionTestResult.Timeout, h.service.testConnection(draft).await())
        h.client.onPage = null
        h.client.pages.add(AssistantModelPage(List(Limits.modelListEntryCap + 1) { ModelDescriptor("model-$it") }))
        assertEquals(ConnectionTestResult.InvalidResponse, h.service.testConnection(draft).await())
        h.session.deactivate()
    }

    @Test fun cancellingAwaiterPropagatesCancellationAndCancelsOperationBeforeLateReply() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val reply = h.client.hold()
        val operation = h.service.perform(AssistantCommand.Write("Brief"), h.context)
        var caught: CancellationException? = null
        val awaiting = backgroundScope.launch {
            try { operation.await(); fail("Cancelled await returned") }
            catch (error: CancellationException) { caught = error; throw error }
        }
        runCurrent()
        awaiting.cancel()
        runCurrent()
        assertTrue(awaiting.isCancelled)
        assertNotNull(caught)
        val cancelled = AssistantFailure.Assistant(AssistantError.Transport(HttpTransportError.Cancelled))
        assertEquals(cancelled, assertFailsWith<AssistantFailure> { operation.await() })
        reply.complete(assistantResponse())
        runCurrent()
        assertEquals(cancelled, assertFailsWith<AssistantFailure> { operation.await() })
        h.session.deactivate()
    }

    @Test fun currentBufferIsSentAndPreparedWithoutReadingDiskOrRenderedValues() = runTest {
        for (kind in ProviderKind.entries) {
            val h = AssistantHarness(this, kind, "Disk template")
            h.configure()
            h.edit("Unsaved {{topic}} and {{clipboard}}")
            val source = checkNotNull(h.context.editor).source
            val command = AssistantCommand.Improve("Make it shorter")
            val result = h.service.perform(command, h.context).await()
            val action = h.client.calls.single().request.action as AssistantAction.Improve
            assertEquals(source, action.source)
            assertTrue(action.selectedFindings.isEmpty())
            val writes = h.provider.files.attemptedWrites.size
            val candidate = h.service.prepare((result.response.output as AssistantOutput.Artifact).value, command, h.context).await()
            assertEquals(h.context, candidate.context)
            assertNotNull(candidate.content.document.frontMatter.id)
            assertContentEquals(PromptCodec.write(candidate.content.document).encodeToByteArray(), candidate.content.canonicalBytes)
            assertFalse(candidate.content.document.source.contains("Changed the prompt."))
            assertEquals(writes, h.provider.files.attemptedWrites.size)
            h.session.deactivate()
        }
    }

    @Test fun reviewAndImproveRefusePrivateInvalidFutureReadOnlyBusyConflictAndMissingBeforeSecretRead() = runTest {
        for (kind in ProviderKind.entries) {
            val h = AssistantHarness(this, kind, "Original")
            h.configure()
            val baseline = h.context
            val original = checkNotNull(baseline.editor)
            val cases = listOf(
                original.copy(source = "---\nprivate: true\n---\nSensitive") to AssistantFailure.Assistant(AssistantError.PrivatePrompt),
                original.copy(source = "---\nformat: 2\n---\nFuture") to AssistantFailure.ReadOnly(SourceReadOnlyReason.FUTURE_FORMAT),
                original.copy(source = null, readOnlyReason = SourceReadOnlyReason.INVALID_UTF8) to AssistantFailure.ReadOnly(SourceReadOnlyReason.INVALID_UTF8),
                original.copy(source = null, readOnlyReason = SourceReadOnlyReason.SOURCE_TOO_LARGE) to AssistantFailure.ReadOnly(SourceReadOnlyReason.SOURCE_TOO_LARGE),
                original.copy(availability = AssistantEditorAvailability.BUSY) to AssistantFailure.EditorBusy,
                original.copy(availability = AssistantEditorAvailability.CONFLICTED) to AssistantFailure.EditorConflict,
                null to AssistantFailure.NoEditor,
            )
            for (command in listOf(AssistantCommand.Review, AssistantCommand.Improve("Clarify"))) {
                for ((editor, expected) in cases) {
                    val reads = h.provider.secrets.reads.size
                    val failure = assertFailsWith<AssistantFailure> { h.service.perform(command, baseline.copy(editor = editor)).await() }
                    assertEquals(expected, failure)
                    assertEquals(reads, h.provider.secrets.reads.size)
                }
                val invalid = assertFailsWith<AssistantFailure.Invalid> {
                    h.service.perform(command, baseline.copy(editor = original.copy(source = "Broken {{field"))).await()
                }
                assertTrue(invalid.issues.any { it.code == PromptIssueCode.UNBALANCED_OPENER })
            }
            assertTrue(h.client.calls.isEmpty())
            h.session.deactivate()
        }
    }

    @Test fun writeSendsBriefOnlyWhilePrivateFutureOrInvalidPromptIsOpenButStillChecksAvailability() = runTest {
        val h = AssistantHarness(this, source = "Original")
        h.configure()
        for (source in listOf("---\nprivate: true\n---\nSecret", "---\nformat: 2\n---\nFuture", "Broken {{field")) {
            h.edit(source)
            h.service.perform(AssistantCommand.Write("Independent brief"), h.context).await()
            assertEquals(AssistantAction.Write("Independent brief"), h.client.calls.last().request.action)
        }
        val original = checkNotNull(h.context.editor)
        for ((availability, failure) in listOf(AssistantEditorAvailability.BUSY to AssistantFailure.EditorBusy,
            AssistantEditorAvailability.CONFLICTED to AssistantFailure.EditorConflict)) {
            val reads = h.provider.secrets.reads.size
            assertEquals(failure, assertFailsWith<AssistantFailure> {
                h.service.perform(AssistantCommand.Write("Brief"), h.context.copy(editor = original.copy(availability = availability))).await()
            })
            assertEquals(reads, h.provider.secrets.reads.size)
        }
        assertEquals(AssistantFailure.Assistant(AssistantError.AccessDenied), assertFailsWith<AssistantFailure> {
            h.service.perform(AssistantCommand.Write("Brief"), h.context.copy(access = AssistantAccessState.UNAVAILABLE)).await()
        })
        assertEquals(3, h.client.calls.size)
        h.session.deactivate()
    }

    @Test fun intentBudgetIncludesQueuedWorkAndCredentialResolution() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.provider.secrets.beforeRead = { delay(8_000) }
        val start = h.monotonic.nowNanos()
        h.service.perform(AssistantCommand.Write("Brief"), h.context).await()
        assertEquals(start + Limits.llmBudgetNanos, h.client.calls.single().deadline)
        assertEquals(8_000, testScheduler.currentTime)
        val held = AssistantHeldDispatcher()
        val reads = h.provider.secrets.reads.size
        val queued = h.makeService(held).perform(AssistantCommand.Write("Brief"), h.context)
        advanceTimeBy(Limits.llmBudgetNanos / 1_000_000 + 1)
        runCurrent()
        assertEquals(AssistantFailure.Assistant(AssistantError.Transport(HttpTransportError.DeadlineExceeded)),
            assertFailsWith<AssistantFailure> { queued.await() })
        held.releaseAll()
        runCurrent()
        assertEquals(reads, h.provider.secrets.reads.size)
        assertEquals(1, h.client.calls.size)
        h.session.deactivate()
    }

    @Test fun timeoutAndCancellationCompleteBeforeUncooperativeSecretResolutionReturns() = runTest {
        for (timeout in listOf(false, true)) {
            val h = AssistantHarness(this)
            h.configure()
            val gate = CompletableDeferred<Unit>()
            h.provider.secrets.beforeRead = { withContext(NonCancellable) { gate.await() } }
            val operation = h.service.perform(AssistantCommand.Write("Brief"), h.context)
            runCurrent()
            if (timeout) { advanceTimeBy(300_001); runCurrent() } else operation.cancel()
            val expected = if (timeout) HttpTransportError.DeadlineExceeded else HttpTransportError.Cancelled
            assertEquals(AssistantFailure.Assistant(AssistantError.Transport(expected)), assertFailsWith<AssistantFailure> { operation.await() })
            gate.complete(Unit)
            runCurrent()
            assertTrue(h.client.calls.isEmpty())
            h.session.deactivate()
        }
    }

    @Test fun nativeBlockingReadAndNetworkStayOnInjectedWorkerAndCancelDoesNotJoinIt() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor { work -> Thread(work, "assistant-io") }
        val dispatcher = executor.asCoroutineDispatcher()
        val secrets = object : SecretStore by h.provider.secrets {
            override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? {
                assertEquals(dispatcher, currentCoroutineContext()[ContinuationInterceptor])
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return h.provider.secrets.read(account, source)
            }
        }
        try {
            val providers = ProviderSettingsService(h.provider.store, secrets, dispatcher)
            val service = AssistantService(providers, h.client, h.client, dispatcher,
                Clock { java.time.Instant.EPOCH }, Entropy { ByteArray(it) }, h.monotonic, Dispatchers.Default)
            val operation = service.perform(AssistantCommand.Write("Brief"), h.context)
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            operation.cancel()
            assertEquals(AssistantFailure.Assistant(AssistantError.Transport(HttpTransportError.Cancelled)),
                assertFailsWith<AssistantFailure> { operation.await() })
            release.countDown()
            withContext(dispatcher) { Unit }
            assertTrue(h.client.calls.isEmpty())
            h.client.onCall = { assertEquals(dispatcher, currentCoroutineContext()[ContinuationInterceptor]) }
            service.perform(AssistantCommand.Write("Brief"), h.context).await()
        } finally {
            release.countDown()
            dispatcher.close()
            h.session.deactivate()
        }
    }

    @Test fun missingConfigurationSettingsFailuresAndStaleProfileRemainTyped() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.provider.secrets.readError = SecretStoreError.ReadFailed
        assertEquals(AssistantFailure.Settings(ProviderSettingsError.Secret(SecretStoreError.ReadFailed)), assertFailsWith<AssistantFailure> {
            h.service.perform(AssistantCommand.Write("Brief"), h.context).await()
        })
        h.provider.secrets.readError = null
        val old = h.context
        h.provider.service.selectProfile(null)
        assertEquals(AssistantFailure.StaleContext, assertFailsWith<AssistantFailure> {
            h.service.perform(AssistantCommand.Write("Brief"), old).await()
        })
        assertEquals(AssistantFailure.Assistant(AssistantError.NotConfigured), assertFailsWith<AssistantFailure> {
            h.service.perform(AssistantCommand.Write("Brief"), old.copy(profile = null)).await()
        })
        h.session.deactivate()
    }

    @Test fun preparationPreservesLoadedIdentityWhenBufferOmitsItAndPrivateCopiesGetFreshIdentity() = runTest {
        val h = AssistantHarness(this, source = "---\nx-owner: custom\n---\nOriginal")
        h.configure()
        val id = checkNotNull(ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        h.context = h.context.copy(editor = h.context.editor?.copy(loadedID = id))
        val command = AssistantCommand.Improve("Clarify")
        val candidate = h.service.prepare(assistantArtifact(), command, h.context).await()
        assertEquals(id, candidate.content.document.frontMatter.id)
        val copy = h.service.prepare(assistantArtifact(), command, h.context.copy(access = AssistantAccessState.GROUP_VIEWER)).await()
        assertNotEquals(id, copy.content.document.frontMatter.id)
        assertTrue(copy.content.document.source.contains("x-owner: custom"))
        assertEquals(AssistantMutationAccess.PRIVATE_COPY, copy.mutationAccess)
        val retained = h.service.prepare(assistantArtifact(), command,
            h.context.copy(access = AssistantAccessState.GROUP_VIEWER), copy.content.document.frontMatter.id).await()
        assertEquals(copy.content.document.frontMatter.id, retained.content.document.frontMatter.id)
        h.session.deactivate()
    }

    @Test fun modelTestSharesDeadlineAcrossPagesCollapsesDuplicatesAndNeverWrites() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        val writes = h.provider.files.attemptedWrites.size
        val secrets = h.provider.secrets.writes.size
        h.client.pages.add(AssistantModelPage(listOf(ModelDescriptor("z"), ModelDescriptor("a", "Zulu")), true, lastID = "cursor"))
        h.client.pages.add(AssistantModelPage(listOf(ModelDescriptor("a", "Alpha"), ModelDescriptor("z", "Name"))))
        h.client.onPage = { delay(1_000) }
        val result = h.service.testConnection(ProviderDraft(checkNotNull(h.service.selectedProfile))).await() as ConnectionTestResult.Ok
        assertEquals(listOf(ModelDescriptor("a", "Alpha"), ModelDescriptor("z", "Name")), result.models)
        assertEquals(listOf(null, "cursor"), h.client.pageCalls.map { it.first })
        assertEquals(listOf(Limits.modelListTimeoutNanos, Limits.modelListTimeoutNanos), h.client.pageCalls.map { it.second })
        assertEquals(writes, h.provider.files.attemptedWrites.size)
        assertEquals(secrets, h.provider.secrets.writes.size)
        h.session.deactivate()
    }

    @Test fun malformedPaginationAndCancelledTestsNeverPublishPartialModels() = runTest {
        val h = AssistantHarness(this)
        h.configure()
        h.client.pages.add(AssistantModelPage(listOf(ModelDescriptor("a")), true, lastID = "cursor"))
        h.client.pages.add(AssistantModelPage(listOf(ModelDescriptor("b")), true, lastID = "cursor"))
        val draft = ProviderDraft(checkNotNull(h.service.selectedProfile))
        assertEquals(ConnectionTestResult.InvalidResponse, h.service.testConnection(draft).await())
        val cancelled = h.service.testConnection(draft)
        cancelled.cancel()
        assertEquals(ConnectionTestResult.Cancelled, cancelled.await())
        h.session.deactivate()
    }
}
