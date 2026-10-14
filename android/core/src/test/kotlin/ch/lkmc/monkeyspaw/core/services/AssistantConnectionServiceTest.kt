package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class AssistantConnectionServiceTest {
    private val kinds = ProviderKind.entries
    private fun model(id: String, name: String? = null) = ModelDescriptor(id, name)

    @Test fun bothClientsFollowPagesAndDeduplicateNamesInUTF8Order() = runTest {
        for (kind in kinds) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page(listOf(model("z", "Z"), model("a", "é"), model("m")), true, last = "a"),
                ConnectionHarness.page(listOf(model("a", "e\u0301"), model("m", "Middle"), model("é"),
                    model("e\u0301"), model("\uE000"), model("\uD800\uDC00")), true, last = "m"),
                ConnectionHarness.page(listOf(model("a"), model("m", "Later"), model("z", ""))))
            assertEquals(ConnectionTestResult.Ok(listOf(model("a", "e\u0301"), model("e\u0301"), model("m", "Later"),
                model("z", ""), model("é"), model("\uE000"), model("\uD800\uDC00"))), h.run(h.draft(kind)))
            assertEquals(3, h.requests.size)
            assertTrue(h.requests.all { it.deadlineNanos == h.requests.first().deadlineNanos })
            assertEquals(listOf("", "?after_id=a", "?after_id=m"), h.requests.map { it.url.substringAfter("models") })
            assertTrue(h.requests.all { it.method == HttpMethod.GET && it.body == null })
            assertTrue(h.requests.all { it.responseByteCap == Limits.responseCap })
            h.assertNoWrites()
        }
    }

    @Test fun nameDedupDoesNotDependOnPageOrderAndPrefersAnyNameToNull() = runTest {
        for (kind in kinds) for (names in listOf(listOf(null, "é", "e\u0301"), listOf("e\u0301", "é", null))) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(*names.mapIndexed { i, name -> ConnectionHarness.page(listOf(model("same", name)),
                more = i < names.lastIndex, last = "cursor-$i") }.toTypedArray())
            assertEquals(ConnectionTestResult.Ok(listOf(model("same", "e\u0301"))), h.run(h.draft(kind)))
        }
    }

    @Test fun emptyListsSucceedWithEmptyStagedNameAndManualModel() = runTest {
        for (kind in kinds) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page())
            assertEquals(ConnectionTestResult.Ok(emptyList()), h.run(h.draft(kind).copy(displayName = "", modelID = "")))
            h.assertNoWrites()
        }
        val h = ConnectionHarness(testScheduler)
        h.enqueue(ConnectionHarness.page())
        assertEquals(ConnectionTestResult.Ok(emptyList()), h.run(h.draft().copy(key = ProviderKeyEdit.Clear)))
        assertFalse(h.requests.single().headers.keys.any { it.equals("authorization", true) })
    }

    @Test fun everyStatusIsDistinctBodyFreeAndNeverRetried() = runTest {
        val cases = listOf(401 to ConnectionTestResult.Authentication, 403 to ConnectionTestResult.Authentication,
            404 to ConnectionTestResult.NotFound, 429 to ConnectionTestResult.RateLimited(17.0),
            405 to ConnectionTestResult.UnsupportedListing, 501 to ConnectionTestResult.UnsupportedListing,
            529 to ConnectionTestResult.ProviderFailure(529), 500 to ConnectionTestResult.ProviderFailure(500),
            400 to ConnectionTestResult.ProviderFailure(400), 204 to ConnectionTestResult.ProviderFailure(204),
            201 to ConnectionTestResult.ProviderFailure(201), 418 to ConnectionTestResult.ProviderFailure(418))
        val sentinel = UUID.randomUUID().toString()
        for (kind in kinds) for ((status, expected) in cases) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(HttpResponse(status, mapOf("retry-after" to "17"), sentinel.encodeToByteArray()))
            val result = h.run(h.draft(kind).copy(key = ProviderKeyEdit.Replace(SecretValue(sentinel))))
            assertEquals(expected, result)
            assertFalse(sentinel in result.toString())
            assertEquals(1, h.requests.size)
            h.assertNoWrites()
        }
    }

    @Test fun retryAfterKeepsOnlyTheParsedDelay() = runTest {
        val cases = listOf(null to null, "garbage" to null, "-1" to null, "17" to 17.0,
            "Wed, 14 Oct 2026 00:00:19 GMT" to 19.0, "Wed, 21 Oct 2015 07:28:00 GMT" to 0.0)
        for (kind in kinds) for ((header, delay) in cases) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(HttpResponse(429, header?.let { mapOf("Retry-After" to it) } ?: emptyMap(), byteArrayOf()))
            assertEquals(ConnectionTestResult.RateLimited(delay), h.run(h.draft(kind)))
        }
    }

    @Test fun transportAndUnexpectedDiagnosticsAreSanitized() = runTest {
        val cases = listOf(HttpTransportError.NetworkFailure to ConnectionTestResult.Network,
            HttpTransportError.RedirectRefused to ConnectionTestResult.Network,
            HttpTransportError.DeadlineExceeded to ConnectionTestResult.Timeout,
            HttpTransportError.Cancelled to ConnectionTestResult.Cancelled,
            HttpTransportError.InvalidResponse to ConnectionTestResult.InvalidResponse,
            HttpTransportError.ResponseTooLarge to ConnectionTestResult.InvalidResponse,
            HttpTransportError.InvalidRequest to ConnectionTestResult.InvalidResponse)
        for (kind in kinds) for ((failure, expected) in cases) {
            val h = ConnectionHarness(testScheduler)
            h.replies.add { throw failure }
            assertEquals(expected, h.run(h.draft(kind)))
            assertEquals(1, h.requests.size)
            h.assertNoWrites()
        }
        val h = ConnectionHarness(testScheduler)
        val sentinel = UUID.randomUUID().toString()
        h.replies.add { throw IllegalArgumentException(sentinel) }
        val result = h.run()
        assertEquals(ConnectionTestResult.Network, result)
        assertFalse(sentinel in result.toString())
    }

    @Test fun malformedSuccessfulListsAndKnownFieldsAreInvalid() = runTest {
        val bodies = listOf("", "not-json", "{\"data\":[{\"id\":\"ok\"},{}]}",
            "{\"data\":[],\"has_more\":\"yes\"}", "{\"data\":[{\"id\":\"\"}]}",
            "{\"data\":[{\"id\":\"bad\\nID\"}]}", "{\"data\":[{\"id\":\"id\",\"display_name\":3}]}",
            "{\"data\":[],\"first_id\":42}", "{\"data\":[],\"last_id\":\"\"}")
        for (kind in kinds) for (body in bodies) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(HttpResponse(200, body = body.encodeToByteArray()))
            assertEquals(ConnectionTestResult.InvalidResponse, h.run(h.draft(kind)))
            assertEquals(1, h.requests.size)
        }
    }

    @Test fun failedLaterPagesNeverPublishPartialModels() = runTest {
        for (kind in kinds) for ((status, expected) in listOf(401 to ConnectionTestResult.Authentication,
            429 to ConnectionTestResult.RateLimited(null), 405 to ConnectionTestResult.UnsupportedListing,
            200 to ConnectionTestResult.InvalidResponse)) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page(listOf(model("partial")), true, last = "partial"),
                HttpResponse(status, body = "invalid".encodeToByteArray()))
            assertEquals(expected, h.run(h.draft(kind)))
            assertEquals(2, h.requests.size)
            h.assertNoWrites()
        }
    }

    @Test fun missingRepeatedAndEmptyMoreCursorsStopPagination() = runTest {
        for (kind in kinds) {
            for (page in listOf(ConnectionHarness.page(emptyList(), true, last = "a"),
                ConnectionHarness.page(listOf(model("a")), true),
                ConnectionHarness.page(listOf(model("a")), true, last = ""))) {
                val h = ConnectionHarness(testScheduler)
                h.enqueue(page)
                assertEquals(ConnectionTestResult.InvalidResponse, h.run(h.draft(kind)))
                assertEquals(1, h.requests.size)
            }
            val h = ConnectionHarness(testScheduler)
            h.enqueue(*listOf("a", "b", "a").map { ConnectionHarness.page(listOf(model(it)), true, last = it) }.toTypedArray())
            assertEquals(ConnectionTestResult.InvalidResponse, h.run(h.draft(kind)))
            assertEquals(3, h.requests.size)
        }
    }

    @Test fun byteDistinctCursorsAreNotConfusedAndAnEmptyFinalPageIsValid() = runTest {
        for (kind in kinds) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page(listOf(model("a")), true, last = "é"),
                ConnectionHarness.page(listOf(model("b")), true, last = "e\u0301"), ConnectionHarness.page())
            assertEquals(ConnectionTestResult.Ok(listOf(model("a"), model("b"))), h.run(h.draft(kind)))
            assertEquals(listOf("", "?after_id=%C3%A9", "?after_id=e%CC%81"), h.requests.map { it.url.substringAfter("models") })
        }
    }

    @Test fun exactlyOneHundredPagesSucceedsButMoreNeverIssuesPageOneHundredOne() = runTest {
        for (kind in kinds) for (more in listOf(false, true)) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(*(0 until Limits.modelListPageCap).map { i -> ConnectionHarness.page(listOf(model("model-$i")),
                i < Limits.modelListPageCap - 1 || more, last = "cursor-$i") }.toTypedArray())
            val result = h.run(h.draft(kind))
            if (more) assertEquals(ConnectionTestResult.InvalidResponse, result)
            else assertEquals(Limits.modelListPageCap, assertIs<ConnectionTestResult.Ok>(result).models.size)
            assertEquals(Limits.modelListPageCap, h.requests.size)
            h.assertNoWrites()
        }
    }

    @Test fun tenThousandTotalEntriesIncludesDuplicatesAndCountsAcrossPages() = runTest {
        for (kind in kinds) for (extra in 0..1) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page(List(6_000) { model("same") }, true, last = "first"),
                ConnectionHarness.page(List(4_000 + extra) { model("same") }))
            assertEquals(if (extra == 0) ConnectionTestResult.Ok(listOf(model("same"))) else ConnectionTestResult.InvalidResponse,
                h.run(h.draft(kind)))
            assertEquals(2, h.requests.size)
            h.assertNoWrites()
        }
    }

    @Test fun aggregateModelAndNameBytesUseUTF8AndAcceptExactlyTwoMiB() = runTest {
        for (kind in kinds) for (extra in 0..1) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page(listOf(model("a", "é".repeat(Limits.modelListByteCap / 4))), true, first = "a", last = "a"),
                ConnectionHarness.page(listOf(model("b", "x".repeat(Limits.modelListByteCap / 2 - 4 + extra)))))
            val result = h.run(h.draft(kind))
            if (extra == 0) assertEquals(listOf("a", "b"), assertIs<ConnectionTestResult.Ok>(result).models.map { it.id })
            else assertEquals(ConnectionTestResult.InvalidResponse, result)
            assertEquals(2, h.requests.size)
        }
    }

    @Test fun totalBytesIncludeBothPaginationIDsEvenOnTheFinalPage() = runTest {
        for (kind in kinds) for (extra in 0..1) {
            val h = ConnectionHarness(testScheduler)
            h.enqueue(ConnectionHarness.page(listOf(model("a")), true, first = "x".repeat(Limits.modelListByteCap / 2), last = "a"),
                ConnectionHarness.page(listOf(model("b")), first = "x".repeat(Limits.modelListByteCap / 2 - 4 + extra), last = "b"))
            val result = h.run(h.draft(kind))
            if (extra == 0) assertEquals(listOf("a", "b"), assertIs<ConnectionTestResult.Ok>(result).models.map { it.id })
            else assertEquals(ConnectionTestResult.InvalidResponse, result)
            assertEquals(2, h.requests.size)
        }
    }

    @Test fun intentDeadlineIsSharedAcrossPagesAndSurvivesNanoTimeWrap() = runTest {
        for (kind in kinds) {
            val h = ConnectionHarness(testScheduler, origin = Long.MAX_VALUE - Limits.modelListTimeoutNanos / 2)
            val deadline = h.clock.nowNanos() + Limits.modelListTimeoutNanos
            repeat(2) { i -> h.replies.add { h.clockShift += 8_000_000_000L
                ConnectionHarness.page(listOf(model("model-$i")), true, last = "cursor-$i") } }
            assertEquals(ConnectionTestResult.Timeout, h.run(h.draft(kind)))
            assertEquals(2, h.requests.size)
            assertTrue(h.requests.all { it.deadlineNanos == deadline })
            h.assertNoWrites()
        }
    }

    @Test fun credentialResolutionConsumesTheOriginalIntentBudget() = runTest {
        for (kind in kinds) {
            val h = ConnectionHarness(testScheduler)
            val draft = h.draft(kind)
            h.provider.service.save(draft)
            h.provider.secrets.beforeRead = { h.clockShift += Limits.modelListTimeoutNanos }
            assertEquals(ConnectionTestResult.Timeout, h.run(draft.copy(key = ProviderKeyEdit.Keep)))
            assertEquals(emptyList(), h.requests)
        }
    }

    @Test fun queuedIOExpiresWithoutReadingCredentialsOrSendingHTTP() = runTest {
        val io = ConnectionQueuedDispatcher()
        val h = ConnectionHarness(testScheduler, io = io)
        val (test, results) = h.start()
        runCurrent()
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals<List<ConnectionTestResult>>(listOf(ConnectionTestResult.Timeout), results)
        io.drain()
        test.cancel()
        runCurrent()
        assertEquals<List<ConnectionTestResult>>(listOf(ConnectionTestResult.Timeout), results)
        assertEquals(emptyList(), h.requests)
        assertEquals(emptyList(), h.provider.secrets.reads)
        h.assertNoWrites()
    }

    @Test fun cancellationBeforeQueuedIOCompletesExactlyOnce() = runTest {
        val io = ConnectionQueuedDispatcher()
        val h = ConnectionHarness(testScheduler, io = io)
        val (test, results) = h.start()
        test.cancel()
        test.cancel()
        runCurrent()
        io.drain()
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals<List<ConnectionTestResult>>(listOf(ConnectionTestResult.Cancelled), results)
        assertEquals(emptyList(), h.requests)
        assertEquals(emptyList(), h.provider.secrets.reads)
        h.assertNoWrites()
    }

    @Test fun cancellationAndTimeoutCancelEitherPageWithoutPartialResults() = runTest {
        for (kind in kinds) for (page in 1..2) for (timeout in listOf(false, true)) {
            val h = ConnectionHarness(testScheduler)
            var cancelled = 0
            if (page == 2) h.enqueue(ConnectionHarness.page(listOf(model("partial")), true, last = "partial"))
            h.replies.add { try { awaitCancellation() } finally { cancelled++ } }
            val (test, results) = h.start(h.draft(kind))
            runCurrent()
            assertEquals(page, h.requests.size)
            assertEquals(emptyList(), results)
            if (timeout) advanceTimeBy(15_000) else test.cancel()
            runCurrent()
            assertEquals(listOf(if (timeout) ConnectionTestResult.Timeout else ConnectionTestResult.Cancelled), results)
            assertEquals(1, cancelled)
            test.cancel()
            runCurrent()
            assertEquals(1, results.size)
            h.assertNoWrites()
        }
    }

    @Test fun completionAlreadyQueuedWinsLaterCancellationAndRunsOnItsExecutor() = runTest {
        val completion = ConnectionQueuedDispatcher()
        val h = ConnectionHarness(testScheduler, completion = completion)
        h.enqueue(ConnectionHarness.page())
        val results = mutableListOf<ConnectionTestResult>()
        val test = h.service.testConnection(h.draft()) {
            assertTrue(completion.isRunning)
            results.add(it)
        }
        runCurrent()
        assertEquals(emptyList(), results)
        test.cancel()
        completion.drain()
        assertEquals<List<ConnectionTestResult>>(listOf(ConnectionTestResult.Ok(emptyList())), results)
        test.cancel()
        completion.drain()
        assertEquals(1, results.size)
    }

    @Test fun editOrSwitchAwayAndBackRejectsAlreadyQueuedSuccess() = runTest {
        for (switch in listOf(false, true)) {
            val completion = ConnectionQueuedDispatcher()
            val h = ConnectionHarness(testScheduler, completion = completion)
            val draft = h.draft()
            val picker = AssistantModelPickerState(draft)
            val old = picker.beginTest()
            h.enqueue(ConnectionHarness.page(listOf(model("old"))))
            h.service.testConnection(draft) { assertFalse(picker.receive(it, old)) }
            runCurrent()
            picker.update(if (switch) h.draft() else draft.copy(modelID = "edited"))
            if (switch) picker.update(draft)
            val fresh = picker.beginTest()
            completion.drain()
            assertTrue(picker.isTesting)
            assertTrue(picker.receive(ConnectionTestResult.Ok(emptyList()), fresh))
            assertEquals(emptyList(), picker.availableModels)
        }
    }

    @Test fun ignoredNetworkCancellationCannotDeliverALateOrRepeatedReply() = runTest {
        for (kind in kinds) {
            val h = ConnectionHarness(testScheduler)
            var held: Continuation<HttpResponse>? = null
            h.replies.add { suspendCoroutine { held = it } }
            val (test, results) = h.start(h.draft(kind))
            runCurrent()
            test.cancel()
            runCurrent()
            assertEquals<List<ConnectionTestResult>>(listOf(ConnectionTestResult.Cancelled), results)
            assertNotNull(held).resume(ConnectionHarness.page(listOf(model("late"))))
            runCurrent()
            test.cancel()
            advanceTimeBy(15_000)
            runCurrent()
            assertEquals<List<ConnectionTestResult>>(listOf(ConnectionTestResult.Cancelled), results)
            h.assertNoWrites()
        }
    }

    @Test fun cancelAndDeadlineCompleteWhileNonCancellableSecretReadAndMutexWaitRemainBlocked() = runTest {
        for (timeout in listOf(false, true)) {
            val h = ConnectionHarness(testScheduler)
            val draft = h.draft()
            h.provider.service.save(draft)
            val release = CompletableDeferred<Unit>()
            var returned = false
            h.provider.secrets.beforeRead = { withContext(NonCancellable) { release.await(); returned = true } }
            val first = h.start(draft.copy(key = ProviderKeyEdit.Keep))
            runCurrent()
            val queued = h.start(draft.copy(key = ProviderKeyEdit.Keep))
            runCurrent()
            if (timeout) advanceTimeBy(15_000) else { first.first.cancel(); queued.first.cancel() }
            runCurrent()
            val expected = if (timeout) ConnectionTestResult.Timeout else ConnectionTestResult.Cancelled
            assertEquals(listOf(expected), first.second)
            assertEquals(listOf(expected), queued.second)
            assertFalse(returned)
            assertEquals(emptyList(), h.requests)
            assertEquals(2, h.provider.secrets.reads.size) // Save's undo read, then the first Test only.
            release.complete(Unit)
            runCurrent()
            assertTrue(returned)
            assertEquals(listOf(expected), first.second)
            assertEquals(listOf(expected), queued.second)
            assertEquals(emptyList(), h.requests)
            assertFalse(h.provider.service.snapshot.isReadOnly)
        }
    }

    @Test fun cancelAndVirtualDeadlineDoNotWaitForANativeStyleBlockingRead() = runTest {
        for (timeout in listOf(false, true)) {
            val executor = Executors.newSingleThreadExecutor()
            val io = executor.asCoroutineDispatcher()
            val release = CountDownLatch(1)
            try {
                val h = ConnectionHarness(testScheduler, io = io)
                val draft = h.draft()
                h.provider.service.save(draft)
                val entered = CountDownLatch(1)
                h.provider.secrets.beforeRead = { entered.countDown(); release.await() }
                val (test, results) = h.start(draft.copy(key = ProviderKeyEdit.Keep))
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                if (timeout) advanceTimeBy(15_000) else test.cancel()
                runCurrent()
                assertEquals(listOf(if (timeout) ConnectionTestResult.Timeout else ConnectionTestResult.Cancelled), results)
                assertEquals(1L, release.count)
                release.countDown()
                io.close()
                assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
                runCurrent()
                test.cancel()
                runCurrent()
                assertEquals(1, results.size)
                assertEquals(emptyList(), h.requests)
            } finally {
                release.countDown()
                io.close()
            }
        }
    }

    @Test fun draftAccountAndTypedClearOrReplacementNeverWriteSettingsSecretsOrCache() = runTest {
        for (kind in kinds) for (edit in listOf(ProviderKeyEdit.Keep, ProviderKeyEdit.Clear, ProviderKeyEdit.typed("typed-only-key"))) {
            val h = ConnectionHarness(testScheduler)
            val selected = h.draft(kind).copy(key = ProviderKeyEdit.typed("selected-profile-key"))
            val other = h.draft(kind).copy(key = ProviderKeyEdit.typed("other-profile-key"))
            h.provider.service.save(selected)
            h.provider.service.save(other)
            h.provider.files.memory.put("opaque-cache-must-stay", "provider-state.json")
            val snapshot = h.provider.service.snapshot
            val metadata = h.provider.files.memory.read("provider-settings.json")
            val persisted = h.provider.secrets.persisted.toMap()
            val fileWrites = h.provider.files.attemptedWrites.size
            val secretWrites = h.provider.secrets.writes.size
            h.enqueue(ConnectionHarness.page())
            val result = h.run(other.copy(key = edit))
            if (kind == ProviderKind.ANTHROPIC && edit == ProviderKeyEdit.Clear) {
                assertEquals(ConnectionTestResult.Authentication, result)
                assertEquals(emptyList(), h.requests)
            } else {
                assertEquals(ConnectionTestResult.Ok(emptyList()), result)
                val header = if (kind == ProviderKind.ANTHROPIC) "x-api-key" else "authorization"
                val key = if (edit == ProviderKeyEdit.Keep) "other-profile-key" else if (edit == ProviderKeyEdit.Clear) null else "typed-only-key"
                assertEquals(key?.let { if (kind == ProviderKind.ANTHROPIC) it else "Bearer $it" },
                    h.requests.single().headers.entries.firstOrNull { it.key.equals(header, true) }?.value)
            }
            assertEquals(snapshot, h.provider.service.snapshot)
            assertContentEquals(metadata, h.provider.files.memory.read("provider-settings.json"))
            assertEquals("opaque-cache-must-stay", h.provider.files.memory.text("provider-state.json"))
            assertEquals(fileWrites, h.provider.files.attemptedWrites.size)
            assertEquals(secretWrites, h.provider.secrets.writes.size)
            assertEquals(persisted, h.provider.secrets.persisted)
            assertEquals(emptyList(), h.provider.secrets.deletions)
        }
    }

    @Test fun localSettingsAndCredentialErrorsPreventOutboundWork() = runTest {
        val corrupt = ConnectionHarness(testScheduler)
        corrupt.provider.files.memory.put("corrupt", "provider-settings.json")
        assertEquals(ConnectionTestResult.Settings(ProviderSettingsError.CorruptFile), corrupt.run())
        assertEquals(emptyList(), corrupt.requests)
        corrupt.assertNoWrites()
        val h = ConnectionHarness(testScheduler)
        val draft = h.draft()
        h.provider.service.save(draft)
        h.provider.secrets.readError = SecretStoreError.Locked
        assertEquals(ConnectionTestResult.Settings(ProviderSettingsError.Secret(SecretStoreError.Locked)),
            h.run(draft.copy(key = ProviderKeyEdit.Keep)))
        h.provider.secrets.readError = null
        assertEquals(ConnectionTestResult.Settings(ProviderSettingsError.KeyRequiredForChangedDestination),
            h.run(draft.copy(baseURL = "https://another.example", key = ProviderKeyEdit.Keep)))
        assertEquals(ConnectionTestResult.Settings(ProviderSettingsError.QueryOrFragmentInURL),
            h.run(draft.copy(baseURL = "https://example.com?key=secret")))
        assertEquals(ConnectionTestResult.Settings(ProviderSettingsError.InvalidKey),
            h.run(draft.copy(key = ProviderKeyEdit.Replace(SecretValue("invalid\nkey")))))
        assertEquals(emptyList(), h.requests)
    }
}
