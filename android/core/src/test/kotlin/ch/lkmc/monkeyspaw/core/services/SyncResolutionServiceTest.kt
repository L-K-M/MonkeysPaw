@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.llm.LineDiffLine
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.nio.file.Path
import java.time.Instant
import java.util.Base64
import kotlin.test.*

private class ResolutionRemote(val group: Boolean) {
    val originals = linkedMapOf<String, Prompt>()
    val requests = mutableListOf<HttpRequest>()
    var role: Role? = Role.EDITOR
    var getFailure: HttpResponse? = null
    var putFailure: HttpResponse? = null
    var beforeGet: (suspend () -> Unit)? = null
    var beforePut: (() -> Unit)? = null
    var afterPut: (() -> Unit)? = null
    val putRequests get() = requests.filter { it.method == HttpMethod.PUT }
    val originalPuts get() = putRequests.filter { it.url.endsWith(SyncTestValues.personal.rawValue) }
    val transport = HttpTransport { request ->
        requests.add(request)
        val id = request.url.substringAfterLast('/').substringBefore('?')
        when {
            request.url.endsWith("/me") -> HttpResponse(200, body = MeResponse.codec.encode(MeResponse(
                User(SyncTestValues.user.rawValue, "user_1", null, AccountKind.MEMBER, "2026-10-14T12:00:00.000Z", null),
                if (group) role?.let { listOf(GroupMembership(SyncTestValues.group.rawValue, "Team", it)) }.orEmpty() else emptyList(), emptyList())))
            request.url.endsWith("/sync/pull") -> {
                fun scope(identity: ScopeIdentity, wire: PromptScope) = SyncScope(identity, Mode.SNAPSHOT, 10, "after", false,
                    originals.values.filter { it.scope == wire }.sortedBy { it.id }.map { prompt ->
                        FeedItem.Upsert(10, FeedPrompt(prompt.id, prompt.rev, prompt.path, prompt.content))
                    })
                val scopes = listOf(scope(ScopeIdentity.User(SyncTestValues.user.rawValue), PromptScope.User)) +
                    if (group) listOf(scope(ScopeIdentity.Group(SyncTestValues.group.rawValue, "Team", role ?: Role.VIEWER),
                        PromptScope.Group(SyncTestValues.group.rawValue))) else emptyList()
                HttpResponse(200, body = PullResponse.codec.encode(PullResponse(SyncTestValues.uuid.toString(), scopes, emptyList())))
            }
            request.method == HttpMethod.GET -> {
                beforeGet?.invoke()
                getFailure ?: originals[id]?.let { HttpResponse(200, body = Prompt.codec.encode(it)) }
                    ?: EngineHarness.errorResponse(404, FailureCode.NOT_FOUND)
            }
            request.method == HttpMethod.PUT -> {
                beforePut?.invoke()
                val put = PutPromptRequest.codec.decode(request.body!!)
                val old = originals[id]
                when {
                    putFailure != null -> putFailure!!
                    old != null && old.rev != put.baseRev -> HttpResponse(409, body = ErrorResponse.codec.encode(ErrorResponse.Conflict(
                        ConflictHead(old.rev, old.scope, old.path, old.content))))
                    else -> {
                        val rev = (old?.rev ?: 0) + 1
                        originals[id] = Prompt(id, rev, put.scope, put.path, put.content)
                        afterPut?.invoke()
                        HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(rev, 9)))
                    }
                }
            }
            request.method == HttpMethod.DELETE -> {
                val old = originals.remove(id)
                HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse((old?.rev ?: 0) + 1, 10)))
            }
            else -> error("Unexpected resolution request")
        }
    }
}

private class ResolutionRig(val root: Path, scheduler: TestCoroutineScheduler, scope: CoroutineScope,
                            val remote: ResolutionRemote = ResolutionRemote(false), seed: Boolean = true, copyRev: Long = 1) {
    val files = ResolutionDiskStore(root.resolve("library"))
    val data = ResolutionDiskStore(root.resolve("state"))
    val binding = SyncTestValues.binding(files.root.toString())
    val clock = Clock { Instant.parse("2026-10-14T12:00:00Z") }
    val library = LibraryService(files, data, clock, Entropy { ByteArray(it) { 3 } })
    val mutations = SyncLibraryMutations(library, files)
    val states = SyncStateStore(data, data)
    val accounts = SyncAccountStore(data, data)
    val journal = SyncApplyJournal(data, data, mutations, states, accounts)
    val pending = SyncPendingOperationStore(data, data)
    val access = GroupAccessService(library, states, accounts, files.root.toString())
    val graph = SyncEngineGraph(data, states, accounts, mutations, journal, pending)
    val monotonic = MonotonicClock { scheduler.currentTime * 1_000_000 }
    val server = SyncServerURL(binding.account.serverURL)
    val client = SyncHTTPClient(server, remote.transport, SyncCredential(server, SecretValue("A".repeat(43))), monotonic)
    private var entropy = 0
    val engine = SyncEngine(graph, scope, StandardTestDispatcher(scheduler), clock,
        { ULID.generate(clock.now(), ByteArray(10).also { it[8] = (entropy shr 8).toByte(); it[9] = (++entropy).toByte() }) }, monotonic)
    val service = SyncResolutionService(engine)
    val copyID = SyncTestValues.groupID
    val copyPath = "Conflicts/Personal/copy.md"
    val originalPath = if (remote.group) "Groups/Team/a.md" else "a.md"
    val originalScope = if (remote.group) SyncTestValues.groupScope else SyncTestValues.userScope
    val initialServer = EngineHarness.prompt(EngineHarness.source("Server Café\n{{old}}"), scope =
        if (remote.group) PromptScope.Group(SyncTestValues.group.rawValue) else PromptScope.User).content.encodeToByteArray()
    val copyBytes = SyncConflictMetadata.settingOrigin(SyncPromptOrigin.ConflictOf(SyncTestValues.personal),
        EngineHarness.source("Mine Cafe\u0301\r\n{{new}}", "favorite: true\nprivate: true\n", SyncTestValues.groupPrompt), "copy.md")
    val state get() = states.load(binding)!!
    val serverBytes get() = remote.originals.getValue(SyncTestValues.personal.rawValue).content.encodeToByteArray()

    init {
        if (seed) {
            files.write(initialServer, originalPath)
            files.write(copyBytes, copyPath)
            val groups = if (remote.group) mapOf(SyncTestValues.group to SyncGroupState("Team", "Team", Role.EDITOR)) else emptyMap()
            states.update(binding) { SyncState(binding, SyncTestValues.uuid,
                mapOf(SyncTestValues.userScope to "before") + if (remote.group) mapOf(originalScope to "before-group") else emptyMap(),
                groups, mapOf(SyncTestValues.personalID to SyncPromptState(originalScope, "a.md", 1, SyncHash.of(initialServer)),
                    copyID to SyncPromptState(SyncTestValues.userScope, copyPath, copyRev,
                        if (copyRev > 0) SyncHash.of(copyBytes) else null, SyncPromptOrigin.ConflictOf(SyncTestValues.personal)))) }
            accounts.updateBinding(binding.root) { SyncLibraryBinding(binding.root, binding.account,
                if (remote.group) mapOf(SyncTestValues.group to SyncManagedFolder(binding.account, "Team")) else emptyMap()) }
            remote.originals[SyncTestValues.personal.rawValue] = EngineHarness.prompt(initialServer, scope =
                if (remote.group) PromptScope.Group(SyncTestValues.group.rawValue) else PromptScope.User)
            if (copyRev > 0) remote.originals[copyID.storageKey] = EngineHarness.prompt(copyBytes, id = copyID.storageKey, path = copyPath)
        }
    }
    suspend fun start() = engine.start(binding, client, "Device")
    suspend fun preview(session: SyncResolutionSession = SyncResolutionSession()) = service.preview(copyID, session)
    fun head(body: String = "New head", rev: Long = 2) {
        val old = remote.originals.getValue(SyncTestValues.personal.rawValue)
        remote.originals[old.id] = EngineHarness.prompt(EngineHarness.source(body), rev, old.scope)
    }
}

class SyncResolutionServiceTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun rig(scheduler: TestCoroutineScheduler, scope: CoroutineScope, group: Boolean = false, rev: Long = 1) =
        ResolutionRig(temporary.newFolder().toPath(), scheduler, scope, ResolutionRemote(group), copyRev = rev)

    @Test fun previewPinsExactOriginalIdentityMarkerFreeCandidateAndBothDiffProjections() = runTest {
        for (group in listOf(false, true)) {
            val h = rig(testScheduler, backgroundScope, group); h.start()
            val preview = h.preview()
            assertTrue(preview.canKeepMine)
            assertTrue(preview.canKeepServer)
            val bytes = assertNotNull(preview.candidateBytes)
            val document = PromptCodec.parseFile(bytes, "a.md")
            assertEquals(SyncTestValues.personal, document.frontMatter.id)
            assertEquals("Mine Cafe\u0301\r\n{{new}}", document.body)
            assertNull(SyncConflictMetadata.origin(bytes, "a.md"))
            assertEquals(!group, document.frontMatter.favorite)
            assertEquals(!group, document.frontMatter.isPrivate)
            val diff = assertNotNull(preview.diff)
            fun project(excluding: LineDiffLine.Kind) = (diff.frontMatter + diff.body).filter { it.kind != excluding }
                .flatMap { it.bytes.asIterable() }.toByteArray()
            assertContentEquals(h.serverBytes, project(LineDiffLine.Kind.ADDED))
            assertContentEquals(bytes, project(LineDiffLine.Kind.REMOVED))
            bytes.fill(0); preview.serverBytes!!.fill(0)
            assertContentEquals(project(LineDiffLine.Kind.REMOVED), preview.candidateBytes)
            assertContentEquals(h.serverBytes, preview.serverBytes)
            h.engine.stop()
        }
    }

    @Test fun keepMinePublishesOnlyTheExactPreviewAndAcknowledgesBeforePrivateRetirement() = runTest {
        for (group in listOf(false, true)) {
            val h = rig(testScheduler, backgroundScope, group); h.start()
            val preview = h.preview()
            val candidate = assertNotNull(preview.candidateBytes)
            val cursors = h.state.cursors
            h.files.beforeTrash = { path ->
                assertEquals(h.copyPath, path)
                assertContentEquals(candidate, h.files.read(h.originalPath))
                assertNotNull(h.journal.pending)
            }
            val version = h.engine.scheduling.value.triggerVersion
            assertEquals(SyncResolutionResult.Resolved(SyncResolutionAction.KEEP_MINE), h.service.resolve(SyncResolutionAction.KEEP_MINE, preview))
            assertContentEquals(candidate, h.serverBytes)
            assertContentEquals(candidate, h.files.read(h.originalPath))
            assertContentEquals(candidate, PutPromptRequest.codec.decode(h.remote.originalPuts.single().body!!).content.encodeToByteArray())
            assertNull(h.files.stamp(h.copyPath))
            assertContentEquals(h.copyBytes, h.files.trashed[h.copyPath])
            assertEquals(2, h.state.prompts.getValue(SyncTestValues.personalID).rev)
            assertEquals(cursors, h.state.cursors)
            assertEquals(1, h.state.prompts.getValue(h.copyID).rev)
            assertTrue(h.engine.scheduling.value.triggerVersion > version)
            assertContentEquals(h.initialServer, h.library.history.read(h.library.history.revisions(SyncTestValues.personalID).single()))
            val retained = h.data.listFiles().single { it.relativePath.startsWith("sync/retained/resolution-") }
            val facts = WireObject(WireJson.parse(h.data.read(retained.relativePath)))
            assertContentEquals(candidate, Base64.getDecoder().decode(facts.string("candidateBytes")))
            assertEquals(1, facts.long("baseRev"))
            h.files.beforeTrash = null
            h.engine.runBackground()
            assertFalse(h.copyID.storageKey in h.remote.originals)
            assertEquals(1, h.remote.originalPuts.size)
            assertEquals(1, h.library.entries().size)
            h.engine.stop()
        }
    }

    @Test fun keepBothUsesHistoryPreservesIdentityAndPropagatesOnlyMarkerRemoval() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        h.service.resolve(SyncResolutionAction.KEEP_BOTH, h.preview())
        val bytes = h.files.read(h.copyPath)
        val document = PromptCodec.parseFile(bytes, "copy.md")
        assertEquals(h.copyID.storageKey, document.frontMatter.id?.rawValue)
        assertEquals("Mine Cafe\u0301\r\n{{new}}", document.body)
        assertNull(SyncConflictMetadata.origin(document))
        assertEquals(SyncHash.of(h.copyBytes), h.state.prompts.getValue(h.copyID).canonicalHash)
        assertNull(h.state.prompts.getValue(h.copyID).origin)
        assertContentEquals(h.copyBytes, h.library.history.read(h.library.history.revisions(h.copyID).single()))
        assertTrue(h.remote.putRequests.isEmpty())
        h.engine.runBackground()
        assertContentEquals(bytes, h.remote.originals.getValue(h.copyID.storageKey).content.encodeToByteArray())
        assertTrue(h.remote.originalPuts.isEmpty())
        h.engine.stop()
    }

    @Test fun keepMineConsumesInstalledGroupInputWithoutChangingPersonalFavourite() = runTest {
        val h = rig(testScheduler, backgroundScope, group = true); h.start()
        val raw = EngineHarness.source("Server Café\n{{old}}", "favorite: true\n")
        h.files.write(raw, h.originalPath)
        h.states.update(h.binding) { state -> state.copy(prompts = state.prompts +
            (SyncTestValues.personalID to state.prompts.getValue(SyncTestValues.personalID).copy(favoriteInput = SyncFavoriteInput(true)))) }
        val preview = h.preview()
        h.service.resolve(SyncResolutionAction.KEEP_MINE, preview)
        assertFalse(h.library.load(h.originalPath).favorite)
        assertNull(h.state.prompts.getValue(SyncTestValues.personalID).favoriteInput)
        assertContentEquals(preview.candidateBytes, h.files.read(h.originalPath))
        h.engine.stop()
    }

    @Test fun keepServerDeletesOnlyTheCheckedCopyAndPersonalSyncSendsItsDelete() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        h.service.resolve(SyncResolutionAction.KEEP_SERVER, h.preview())
        assertContentEquals(h.initialServer, h.files.read(h.originalPath))
        assertNull(h.files.stamp(h.copyPath))
        assertContentEquals(h.copyBytes, h.files.trashed[h.copyPath])
        h.engine.runBackground()
        assertTrue(h.remote.putRequests.isEmpty())
        assertFalse(h.copyID.storageKey in h.remote.originals)
        assertEquals(1, h.remote.requests.count { it.method == HttpMethod.DELETE && it.url.contains(h.copyID.storageKey) })
        h.engine.stop()
    }

    @Test fun deletingRevZeroCopyRetiresItsRecordWithoutAPhantomPersonalDelete() = runTest {
        for (action in listOf(SyncResolutionAction.KEEP_SERVER, SyncResolutionAction.KEEP_MINE)) {
            val h = rig(testScheduler, backgroundScope, rev = 0); h.start()
            h.service.resolve(action, h.preview())
            assertNull(h.state.prompts[h.copyID])
            h.engine.runBackground()
            assertTrue(h.remote.requests.none { it.method == HttpMethod.DELETE })
            h.engine.stop()
        }
    }

    @Test fun rescuedCopyOffersKeepBothWithoutFetchingAnInventedOriginal() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        h.files.write(SyncConflictMetadata.settingOrigin(SyncPromptOrigin.Rescued, h.copyBytes, "copy.md"), h.copyPath)
        val preview = h.preview()
        assertNull(preview.originalID); assertNull(preview.serverBytes)
        assertFalse(preview.canKeepMine); assertFalse(preview.canKeepServer)
        assertTrue(h.remote.requests.isEmpty())
        h.service.resolve(SyncResolutionAction.KEEP_BOTH, preview)
        assertNull(SyncConflictMetadata.origin(h.files.read(h.copyPath), "copy.md"))
        h.engine.stop()
    }

    @Test fun changedHeadRefreshesEitherDiscardingActionWithoutSendingOrDeleting() = runTest {
        for (action in listOf(SyncResolutionAction.KEEP_SERVER, SyncResolutionAction.KEEP_MINE)) {
            val h = rig(testScheduler, backgroundScope); h.start()
            val preview = h.preview(); h.head()
            val result = assertIs<SyncResolutionResult.Refreshed>(h.service.resolve(action, preview))
            assertContentEquals(h.serverBytes, result.preview.serverBytes)
            assertContentEquals(preview.candidateBytes, result.preview.candidateBytes)
            assertTrue(h.remote.putRequests.isEmpty())
            assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
            assertFailsWith<SyncResolutionFailure.StaleSession> { h.service.resolve(action, preview) }
            h.engine.stop()
        }
    }

    @Test fun racingCASRefreshesWithoutRetiringEitherVersion() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.remote.beforePut = { h.head("Racing writer") }
        val result = assertIs<SyncResolutionResult.Refreshed>(h.service.resolve(SyncResolutionAction.KEEP_MINE, preview))
        assertContentEquals(h.serverBytes, result.preview.serverBytes)
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        assertContentEquals(h.initialServer, h.files.read(h.originalPath))
        assertEquals(2, h.library.entries().size)
        h.engine.stop()
    }

    @Test fun unavailableOriginalRefreshKeepsPrivateVersionAndExplainsRefusal() = runTest {
        for (failure in listOf(EngineHarness.errorResponse(403, FailureCode.FORBIDDEN), EngineHarness.errorResponse(404, FailureCode.NOT_FOUND),
            HttpResponse(410, body = ErrorResponse.codec.encode(ErrorResponse.Deleted)))) {
            val h = rig(testScheduler, backgroundScope); h.start()
            val preview = h.preview(); h.remote.getFailure = failure
            val refreshed = assertIs<SyncResolutionResult.Refreshed>(h.service.resolve(SyncResolutionAction.KEEP_MINE, preview)).preview
            assertFalse(refreshed.canKeepMine); assertFalse(refreshed.canKeepServer)
            assertNotNull(refreshed.mineRefusal)
            assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
            assertTrue(h.remote.putRequests.isEmpty())
            h.service.resolve(SyncResolutionAction.KEEP_BOTH, refreshed)
            h.engine.stop()
        }
    }

    @Test fun deniedGoneAndNotFoundPUTNeverDeleteThePrivateCopy() = runTest {
        for (failure in listOf(EngineHarness.errorResponse(403, FailureCode.FORBIDDEN), EngineHarness.errorResponse(404, FailureCode.NOT_FOUND),
            HttpResponse(410, body = ErrorResponse.codec.encode(ErrorResponse.Deleted)))) {
            val h = rig(testScheduler, backgroundScope, group = true); h.start()
            val preview = h.preview(); h.remote.putFailure = failure
            assertFailsWith<SyncHTTPClientError> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
            assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
            assertContentEquals(h.initialServer, h.files.read(h.originalPath))
            assertEquals(2, h.library.entries().size)
            assertTrue(h.data.listFiles().any { it.relativePath.startsWith("sync/retained/resolution-") })
            h.engine.stop()
        }
    }

    @Test fun authoritativeRoleChangeRefusesOldMineAndFreshPreviewAllowsKeepBoth() = runTest {
        for (role in listOf(Role.VIEWER, null)) {
            val h = rig(testScheduler, backgroundScope, group = true); h.start()
            val preview = h.preview(); h.remote.role = role
            assertFailsWith<SyncResolutionFailure.StaleAccess> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
            val fresh = h.preview()
            assertEquals(SyncResolutionFailure.AccessDenied, fresh.mineRefusal)
            assertTrue(h.remote.putRequests.isEmpty())
            h.service.resolve(SyncResolutionAction.KEEP_BOTH, fresh)
            h.engine.stop()
        }
    }

    @Test fun changedCopyIncarnationRenameOrDuplicateCannotUseAnOldPreview() = runTest {
        for (change in 0..3) {
            val h = rig(testScheduler, backgroundScope); h.start()
            val preview = h.preview()
            when (change) {
                0 -> h.files.write(h.copyBytes + "new edit".encodeToByteArray(), h.copyPath)
                1 -> h.files.write(h.copyBytes, h.copyPath)
                2 -> h.files.move(h.copyPath, "elsewhere.md")
                3 -> h.files.write(h.copyBytes, "duplicate.md")
            }
            assertFailsWith<SyncResolutionFailure> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
            assertTrue(h.remote.putRequests.isEmpty())
            if (change == 2) {
                val renamed = h.preview()
                assertEquals("elsewhere.md", renamed.copyPath)
                h.service.resolve(SyncResolutionAction.KEEP_SERVER, renamed)
                assertNull(h.files.stamp("elsewhere.md"))
            }
            h.engine.stop()
        }
    }

    @Test fun changedOriginalCannotBeSilentlyReplacedByAPrivateCandidate() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        val newer = EngineHarness.source("Unseen local original edit")
        h.files.write(newer, h.originalPath)
        assertFailsWith<SyncResolutionFailure.StaleCopy> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        assertContentEquals(newer, h.files.read(h.originalPath))
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        assertTrue(h.remote.putRequests.isEmpty())
        h.engine.stop()
    }

    @Test fun committedAccessChangeOrInterveningDowngradeRefusesBeforeHTTP() = runTest {
        for (restore in listOf(false, true)) {
            val h = rig(testScheduler, backgroundScope, group = true); h.start()
            val preview = h.preview(); val count = h.remote.requests.size
            h.states.update(h.binding) { it.copy(groups = mapOf(SyncTestValues.group to SyncGroupState("Team", "Team", Role.VIEWER))) }
            if (restore) h.states.update(h.binding) { it.copy(groups = mapOf(SyncTestValues.group to SyncGroupState("Team", "Team", Role.EDITOR))) }
            assertFailsWith<SyncResolutionFailure.StaleAccess> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
            assertEquals(count, h.remote.requests.size)
            assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
            h.engine.stop()
        }
    }

    @Test fun stoppedOrReconstructedGraphRefusesItsPredecessorsPreview() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.engine.stop(); h.engine.drain(); h.start()
        assertFailsWith<SyncResolutionFailure.StaleSession> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        h.engine.stop()
        val predecessor = ResolutionRig(h.root, testScheduler, backgroundScope, h.remote, seed = false); predecessor.start()
        val old = predecessor.preview()
        predecessor.engine.stop(); predecessor.engine.drain()
        val replacement = ResolutionRig(h.root, testScheduler, backgroundScope, h.remote, seed = false); replacement.start()
        assertFailsWith<SyncResolutionFailure.StaleSession> { replacement.service.resolve(SyncResolutionAction.KEEP_MINE, old) }
        replacement.engine.stop()
    }

    @Test fun cancelBeforeAndDuringGETCannotSendOrRetireTheCopy() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val session = SyncResolutionSession()
        val preview = h.preview(session)
        session.cancel()
        val count = h.remote.requests.size
        assertFailsWith<SyncResolutionFailure.StaleSession> { h.service.resolve(SyncResolutionAction.KEEP_BOTH, preview) }
        assertEquals(count, h.remote.requests.size)
        val other = SyncResolutionSession(); val fresh = h.preview(other)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.remote.beforeGet = { entered.complete(Unit); release.await() }
        val work = async { runCatching { h.service.resolve(SyncResolutionAction.KEEP_MINE, fresh) } }
        entered.await(); other.cancel(); release.complete(Unit)
        assertTrue(work.await().isFailure)
        assertTrue(h.remote.putRequests.isEmpty())
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        h.engine.stop()
    }

    @Test fun stopAndDrainRevokesAnInFlightDecisionAndOtherWorkCannotEnter() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.remote.beforeGet = { entered.complete(Unit); release.await() }
        val work = async { runCatching { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) } }
        entered.await()
        assertFailsWith<SyncResolutionFailure.Busy> { h.preview() }
        assertEquals(SyncStopResult.BUSY, h.engine.stop())
        release.complete(Unit); work.await(); h.engine.drain()
        assertTrue(h.remote.putRequests.isEmpty())
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        assertEquals(SyncStopResult.STOPPED, h.engine.retire())
    }

    @Test fun repeatedTapCannotPerformASecondCASOrDeletion() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.service.resolve(SyncResolutionAction.KEEP_MINE, preview)
        assertFailsWith<SyncResolutionFailure.StaleSession> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        assertEquals(1, h.remote.originalPuts.size)
        assertEquals(1, h.library.history.revisions(SyncTestValues.personalID).size)
        h.engine.stop()
    }

    @Test fun lateAcknowledgementAfterCancellationOrNewCopyEditPreservesPrivateBytes() = runTest {
        for (cancel in listOf(false, true)) {
            val h = rig(testScheduler, backgroundScope); h.start()
            val session = SyncResolutionSession(); val preview = h.preview(session)
            val newer = h.copyBytes + "new edit".encodeToByteArray()
            h.remote.afterPut = { if (cancel) session.cancel() else h.files.write(newer, h.copyPath) }
            assertFailsWith<Exception> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
            assertContentEquals(preview.candidateBytes, h.serverBytes)
            assertContentEquals(if (cancel) h.copyBytes else newer, h.files.read(h.copyPath))
            assertContentEquals(h.initialServer, h.files.read(h.originalPath))
            assertEquals(2, h.library.entries().size)
            h.engine.stop()
        }
    }

    @Test fun restartAfterLostRemoteReplyConvergesWithoutAnotherPUTOrAnotherCopy() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.remote.afterPut = { throw HttpTransportError.NetworkFailure }
        assertFailsWith<SyncHTTPClientError.Transport> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        h.engine.stop(); h.engine.drain()
        h.remote.afterPut = null
        val restarted = ResolutionRig(h.root, testScheduler, backgroundScope, h.remote, seed = false); restarted.start()
        restarted.engine.runBackground()
        assertContentEquals(preview.candidateBytes, restarted.files.read(restarted.originalPath))
        assertContentEquals(h.copyBytes, restarted.files.read(h.copyPath))
        val fresh = restarted.preview()
        restarted.service.resolve(SyncResolutionAction.KEEP_MINE, fresh)
        assertEquals(1, h.remote.originalPuts.size)
        assertEquals(1, restarted.library.entries().size)
        assertNull(restarted.files.stamp(h.copyPath))
        restarted.engine.stop()
    }

    @Test fun failedJournalReplayCompletesOriginalBeforeCopyRetirementWithStableBytes() = runTest {
        for (action in SyncResolutionAction.entries) {
            val h = rig(testScheduler, backgroundScope); h.start()
            val preview = h.preview()
            var failed = false
            h.files.onOperation = { event -> if (!failed && (event.startsWith("published:") || event.startsWith("trashed:"))) {
                failed = true; throw StoreError.IOFailure
            } }
            assertFailsWith<Exception> { h.service.resolve(action, preview) }
            assertNotNull(h.journal.pending)
            h.engine.stop(); h.engine.drain()
            h.files.onOperation = null
            val restarted = ResolutionRig(h.root, testScheduler, backgroundScope, h.remote, seed = false)
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            if (action == SyncResolutionAction.KEEP_BOTH) {
                assertNull(SyncConflictMetadata.origin(restarted.files.read(h.copyPath), "copy.md"))
                assertEquals(h.copyID.storageKey, PromptCodec.parseFile(restarted.files.read(h.copyPath), "copy.md").frontMatter.id?.rawValue)
            } else assertNull(restarted.files.stamp(h.copyPath))
            if (action == SyncResolutionAction.KEEP_MINE) {
                assertContentEquals(preview.candidateBytes, restarted.files.read(h.originalPath))
                assertEquals(2, restarted.state.prompts.getValue(SyncTestValues.personalID).rev)
            }
            assertEquals(if (action == SyncResolutionAction.KEEP_BOTH) 2 else 1, restarted.library.entries().size)
        }
    }

    @Test fun failedAttemptRetentionPreventsHTTP() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.data.beforeWrite = { if (it.startsWith("sync/retained/resolution-")) throw StoreError.IOFailure }
        assertFailsWith<Exception> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        assertTrue(h.remote.putRequests.isEmpty())
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        h.data.beforeWrite = null
        h.engine.stop()
    }

    @Test fun historyFailureRetainsTheExactMarkedCopyBeforeAnyMarkerPublication() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.data.beforeWrite = { if (it.startsWith("history/")) throw StoreError.IOFailure }
        assertFailsWith<StoreError.IOFailure> { h.service.resolve(SyncResolutionAction.KEEP_BOTH, preview) }
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        assertNull(h.journal.pending)
        h.data.beforeWrite = null
        h.service.resolve(SyncResolutionAction.KEEP_BOTH, preview)
        assertEquals(1, h.library.history.revisions(h.copyID).size)
        h.engine.stop()
    }

    @Test fun cancellationOfALoadRejectsItsLatePreview() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val session = SyncResolutionSession()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.remote.beforeGet = { entered.complete(Unit); release.await() }
        val load = async { runCatching { h.preview(session) } }
        entered.await(); session.cancel(); release.complete(Unit)
        assertTrue(load.await().isFailure)
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        assertTrue(h.remote.putRequests.isEmpty())
        h.engine.stop()
    }

    @Test fun repeatedTapDuringHTTPIsBusyAndLeavesOnlyOneMutation() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.remote.beforeGet = { entered.complete(Unit); release.await() }
        val first = async { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        entered.await()
        assertFailsWith<SyncResolutionFailure.Busy> { h.service.resolve(SyncResolutionAction.KEEP_SERVER, preview) }
        h.engine.runBackground()
        assertTrue(h.remote.requests.none { it.url.endsWith("/sync/pull") })
        release.complete(Unit); first.await()
        assertEquals(1, h.remote.originalPuts.size)
        assertNull(h.files.stamp(h.copyPath))
        h.engine.stop()
    }

    @Test fun committedAccessChangeWhileGETIsPendingCannotAuthorizeTheCAS() = runTest {
        val h = rig(testScheduler, backgroundScope, group = true); h.start()
        val preview = h.preview()
        h.remote.beforeGet = {
            h.states.update(h.binding) { it.copy(groups = mapOf(SyncTestValues.group to SyncGroupState("Team", "Team", Role.VIEWER))) }
        }
        assertFailsWith<SyncResolutionFailure.StaleAccess> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        assertTrue(h.remote.putRequests.isEmpty())
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        h.engine.stop()
    }

    @Test fun privateCopyHoldsAndMalformedMarkersRefuseBeforeFetchingTheOriginal() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        h.accounts.updateBinding(h.binding.root) { owned -> owned!!.copy(holds = listOf(
            SyncHeldPrompt(h.copyID, h.copyPath, h.binding.account, SyncHash.of(h.copyBytes)))) }
        assertFailsWith<SyncResolutionFailure.AccessDenied> { h.preview() }
        assertTrue(h.remote.requests.isEmpty())
        h.accounts.updateBinding(h.binding.root) { it!!.copy(holds = emptyList()) }
        val malformed = h.copyBytes.decodeToString().replace(SyncTestValues.personal.rawValue, "not-an-id").encodeToByteArray()
        h.files.write(malformed, h.copyPath)
        assertFailsWith<Exception> { h.preview() }
        assertTrue(h.remote.requests.isEmpty())
        assertContentEquals(malformed, h.files.read(h.copyPath))
        h.engine.stop()
    }

    @Test fun alreadyCommittedMineCanFinishWithoutAPullOrAnotherWrite() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.remote.afterPut = { throw HttpTransportError.NetworkFailure }
        assertFailsWith<SyncHTTPClientError.Transport> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
        h.remote.afterPut = null
        val fresh = h.preview()
        h.service.resolve(SyncResolutionAction.KEEP_MINE, fresh)
        assertEquals(1, h.remote.originalPuts.size)
        assertNull(h.files.stamp(h.copyPath))
        assertContentEquals(preview.candidateBytes, h.files.read(h.originalPath))
        h.engine.stop()
    }

    @Test fun unauthorizedResolutionReportsSignInAndPreservesPrivateBytes() = runTest {
        val h = rig(testScheduler, backgroundScope); h.start()
        val preview = h.preview()
        h.remote.putFailure = EngineHarness.errorResponse(401, FailureCode.UNAUTHORIZED)
        val error = try { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview); fail("Unauthorized request succeeded") }
            catch (error: Exception) { error }
        assertEquals(SyncResolutionFailure.NeedsSignIn, SyncResolutionService.failure(error))
        assertTrue(h.engine.reports.value.needsSignIn)
        assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        h.engine.stop()
    }

    @Test fun graphCancellationRefusesLateCASWhileAnotherGraphChildIsStillDraining() = runTest {
        val lifetime = SupervisorJob()
        val graphScope = CoroutineScope(lifetime + StandardTestDispatcher(testScheduler))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val child = graphScope.launch { withContext(NonCancellable) { entered.complete(Unit); release.await() } }
        entered.await()
        val h = rig(testScheduler, graphScope); h.start()
        val preview = h.preview()
        h.remote.beforeGet = { lifetime.cancel() }
        try {
            assertFailsWith<CancellationException> { h.service.resolve(SyncResolutionAction.KEEP_MINE, preview) }
            assertTrue(h.remote.putRequests.isEmpty())
            assertContentEquals(h.copyBytes, h.files.read(h.copyPath))
        } finally {
            release.complete(Unit); child.join(); h.engine.stop()
        }
    }
}
