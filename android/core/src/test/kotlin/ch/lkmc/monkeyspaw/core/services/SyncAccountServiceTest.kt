@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import kotlin.test.*

/** In-memory synthetic secrets only; this does not exercise AndroidKeyStore. */
internal class AccountSecrets : SecretStore {
    val values = linkedMapOf<SecretAccount, StoredSecret>()
    val reads = mutableListOf<Pair<SecretAccount, SecretReadSource>>()
    val writes = mutableListOf<SecretAccount>()
    val deletes = mutableListOf<SecretAccount>()
    var readError: SecretStoreError? = null
    var writeError: SecretStoreError? = null
    var deleteError: SecretStoreError? = null
    var beforeRead: (suspend () -> Unit)? = null
    var beforeWrite: (suspend () -> Unit)? = null
    var beforeDelete: ((SecretAccount) -> Unit)? = null
    override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? {
        reads.add(account to source)
        beforeRead?.invoke()
        readError?.let { throw it }
        return values[account]
    }
    override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
        writes.add(account)
        beforeWrite?.invoke()
        writeError?.let { throw it }
        values[account] = StoredSecret(value, SecretTier.KEYSTORE)
        return SecretTier.KEYSTORE
    }
    override suspend fun delete(account: SecretAccount) {
        deletes.add(account)
        beforeDelete?.invoke(account)
        deleteError?.let { throw it }
        values.remove(account)
    }
}

internal class AccountHarness(val scheduler: TestCoroutineScheduler, val scope: CoroutineScope,
                              val h: EngineHarness = EngineHarness(scheduler, scope)) {
    val secrets = AccountSecrets()
    var user = SyncTestValues.user
    var device = SyncTestValues.device
    var server = "https://example.test/paw"
    var token = "A".repeat(43)
    val password = SecretValue("Synthetic-password-123")
    var me: (() -> MeResponse)? = null
    var nextID = UUID(1, 1)
    var respond: (suspend (HttpRequest) -> HttpResponse?)? = null
    val service = reopen()
    val root get() = h.binding.root
    val binding get() = SyncLibraryIdentity(SyncAccountIdentity(SyncServerURL(server).baseURL, user), root)
    val requests get() = h.requests
    val logouts get() = requests.filter { it.url.endsWith("/auth/logout") }
    val puts get() = requests.filter { it.method == HttpMethod.PUT }

    init {
        h.respond = { request -> respond?.invoke(request) ?: when {
            request.url.endsWith("/auth/login") || request.url.endsWith("/auth/register") ->
                HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse(token, userDTO())))
            request.url.endsWith("/me") -> HttpResponse(200, body = MeResponse.codec.encode(me?.invoke() ?: MeResponse(userDTO(), emptyList(), listOf(deviceDTO()))))
            request.url.endsWith("/auth/logout") || request.url.contains("/me/devices/") -> HttpResponse(200, body = EmptyResponse.codec.encode(EmptyResponse))
            request.url.endsWith("/sync/pull") -> pull()
            else -> null
        } }
    }
    fun reopen(store: SecretStore = secrets): SyncAccountService = SyncAccountService(h.engine, h.accounts, store, h.transport, root,
        StandardTestDispatcher(scheduler), MonotonicClock { scheduler.currentTime * 1_000_000 }) {
        nextID.also { nextID = UUID(1, it.leastSignificantBits + 1) }
    }
    suspend fun login(service: SyncAccountService = this.service): SyncAccountSnapshot = service.login(server, "person", password, "Android")
    fun account(): SyncAccount = h.accounts.loadAccount()!!
    fun userDTO(id: ULID = user) = User(id.rawValue, "person", null, AccountKind.MEMBER, timestamp, null)
    fun deviceDTO(id: ULID = device, current: Boolean = true, revoked: Boolean = false) =
        Device(id.rawValue, "Android", timestamp, null, if (revoked) timestamp else null, current)
    fun pull(): HttpResponse {
        val items = h.remote.values.map { FeedItem.Upsert(it.rev, FeedPrompt(it.id, it.rev, it.path, it.content)) }
        val head = maxOf(1, h.sequence, items.maxOfOrNull { it.seq } ?: 0)
        return HttpResponse(200, body = PullResponse.codec.encode(PullResponse(SyncTestValues.uuid.toString(),
            listOf(SyncScope(ScopeIdentity.User(user.rawValue), Mode.SNAPSHOT, head, "opaque-$head", false, items)), emptyList())))
    }
    fun pendingCreate(): SyncPendingOperation {
        h.files.put(EngineHarness.source(), "pending.md")
        val file = h.rig.mutations.read("pending.md")!!
        val sent = SyncLocalScanner.canonical(file.bytes, file.path, SyncScopeKey.User(user)).bytes
        val intent = SyncConflictIntent(SyncTestValues.personal, SyncOperation.PUT, 0, SyncScopeKey.User(user),
            file.path, sent, file.bytes, 0)
        return SyncPendingOperation(binding, intent, file.path, file, null).also { h.pending.save(it) }
    }
    fun assertNoCredentials() {
        for (file in h.data.listFiles()) {
            val text = h.data.text(file.relativePath)
            assertFalse(text.contains(token))
            password.withValue { assertFalse(text.contains(it)) }
        }
    }
    companion object { const val timestamp = "2026-10-14T00:00:00.000Z" }
}

class SyncAccountServiceTest {
    @Test fun candidatePublishesBoundSecretInactiveMetadataAndOwnershipBeforeEnablement() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val publications = mutableListOf<SyncAccountActivation>()
        r.h.data.onWrite = { path -> if (path == "sync/account.json") {
            val current = r.h.accounts.cachedAccount
            if (current != null) assertNotNull(r.secrets.values[current.secretAccount])
        } }
        r.h.rig.dataOperations.onOperation = { op -> if (op == "file:sync/account.json") {
            val doc = WireObject(WireJson.parse(r.h.data.read("sync/account.json")))
            publications.add(SyncAccountActivation.entries.single { it.rawValue == doc.string("activation") })
            if (doc.string("activation") == "enabled") assertNotNull(r.h.accounts.binding(r.root))
        } }
        val result = r.login()
        assertTrue(result.enabled)
        assertEquals(SecretTier.KEYSTORE, result.tier)
        assertEquals(listOf(SyncAccountActivation.INACTIVE, SyncAccountActivation.INACTIVE, SyncAccountActivation.ENABLED), publications)
        assertEquals(2, r.requests.size)
        val account = result.account!!
        val envelope = r.secrets.values[account.secretAccount]!!.value.withValue { WireObject(WireJson.parse(it.encodeToByteArray())) }
        assertEquals(1, envelope.long("version"))
        assertEquals(account.identity.serverURL, envelope.string("server_url"))
        assertEquals(account.identity.userID.rawValue, envelope.string("user_id"))
        assertEquals(account.connectionID.toString(), envelope.string("connection_id"))
        assertTrue(r.h.data.isPrivate("sync/account.json"))
        r.assertNoCredentials()
    }

    @Test fun invalidURLOrCredentialsPerformNoPublication() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.server = "https://example.test/?token=invalid"
        assertFailsWith<SyncAccountServiceError> { r.login() }
        assertTrue(r.requests.isEmpty())
        r.server = "https://example.test/paw"
        assertFailsWith<SyncAccountServiceError> { r.service.login(r.server, "UPPER", r.password, "Android") }
        assertTrue(r.secrets.writes.isEmpty())
        assertNull(r.h.accounts.loadAccount())
    }

    @Test fun failedAuthenticationDoesNotCreateOrRevokeAnUnknownSession() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.respond = { EngineHarness.errorResponse(401, FailureCode.UNAUTHORIZED) }
        assertFailsWith<SyncAccountServiceError> { r.login() }
        assertEquals(1, r.requests.size)
        assertTrue(r.logouts.isEmpty())
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun failedMeRevokesCandidateWithoutAdoptingOrPublishingIt() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.respond = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
        val error = assertFailsWith<SyncAccountServiceError> { r.login() }
        assertEquals(SyncRemoteRevocation.REVOKED, error.cleanup.remote)
        assertEquals(1, r.logouts.size)
        assertTrue(r.secrets.writes.isEmpty())
        assertNull(r.h.states.snapshot.value)
        assertNull(r.h.accounts.binding(r.root))
    }

    @Test fun meRequiresMatchingActiveUserUniqueDevicesAndExactlyOneNonRevokedCurrentDevice() = runTest {
        val variants: List<(AccountHarness) -> MeResponse> = listOf(
            { MeResponse(it.userDTO(SyncTestValues.otherUser), emptyList(), listOf(it.deviceDTO())) },
            { MeResponse(it.userDTO().copy(disabledAt = AccountHarness.timestamp), emptyList(), listOf(it.deviceDTO())) },
            { MeResponse(it.userDTO(), emptyList(), emptyList()) },
            { MeResponse(it.userDTO(), emptyList(), listOf(it.deviceDTO(current = false))) },
            { MeResponse(it.userDTO(), emptyList(), listOf(it.deviceDTO(revoked = true))) },
            { MeResponse(it.userDTO(), emptyList(), listOf(it.deviceDTO(), it.deviceDTO(SyncTestValues.group))) },
            { MeResponse(it.userDTO(), emptyList(), listOf(it.deviceDTO(), it.deviceDTO(current = false))) },
        )
        for (variant in variants) {
            val r = AccountHarness(testScheduler, backgroundScope)
            r.me = { variant(r) }
            assertEquals(SyncAccountIssue.InvalidAccount, assertFailsWith<SyncAccountServiceError> { r.login() }.issue)
            assertEquals(1, r.logouts.size)
            assertTrue(r.secrets.writes.isEmpty())
        }
    }

    @Test fun connectionUUIDCannotOverwriteAnOrphanOrPendingCleanupReference() = runTest {
        for (orphan in listOf(true, false)) {
            val r = AccountHarness(testScheduler, backgroundScope)
            val id = r.nextID
            if (orphan) r.secrets.values[SecretAccount.device(id)] = StoredSecret(SecretValue("orphan synthetic"), SecretTier.KEYSTORE)
            else r.h.accounts.saveInactive(null, listOf(id))
            assertFailsWith<SyncAccountServiceError> { r.login() }
            assertTrue(r.secrets.writes.isEmpty())
            assertTrue(r.secrets.deletes.isEmpty())
            assertEquals(1, r.logouts.size)
        }
    }

    @Test fun secretWriteFailureCompensatesCandidateAndLeavesDurablyInactiveMetadata() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.secrets.writeError = SecretStoreError.WriteFailed
        val error = assertFailsWith<SyncAccountServiceError> { r.login() }
        assertEquals(SyncAccountIssue.Secret(SecretStoreError.WriteFailed), error.issue)
        assertEquals(SyncRemoteRevocation.REVOKED, error.cleanup.remote)
        assertTrue(error.cleanup.isComplete)
        assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
        assertFalse(r.service.snapshot.enabled)
        assertTrue(r.secrets.values.isEmpty())
        val reads = r.secrets.reads.size
        val requests = r.requests.size
        r.reopen().startup()
        assertEquals(reads, r.secrets.reads.size)
        assertEquals(requests, r.requests.size)
    }

    @Test fun everyConnectionPublicationFailureCompensatesAndBlocksAutomaticResume() = runTest {
        for (failed in 1..3) {
            val r = AccountHarness(testScheduler, backgroundScope)
            var count = 0
            r.h.data.fault = { op, path -> if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/account.json" && ++count == failed) StoreError.IOFailure else null }
            val error = assertFailsWith<SyncAccountServiceError> { r.login() }
            assertEquals(SyncRemoteRevocation.REVOKED, error.cleanup.remote)
            assertTrue(r.secrets.values.isEmpty())
            assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
            assertFalse(r.service.snapshot.enabled)
            val before = r.requests.size
            r.reopen().startup()
            assertEquals(before, r.requests.size)
        }
    }

    @Test fun uncertainCandidateAndEnablementFlushesAreRecoveredBeforeCompensation() = runTest {
        for (failed in 2..3) {
            val r = AccountHarness(testScheduler, backgroundScope)
            var count = 0
            r.h.rig.dataOperations.onOperation = { op -> if (op == "file:sync/account.json" && ++count == failed) throw StoreError.IOFailure }
            val error = assertFailsWith<SyncAccountServiceError> { r.login() }
            assertNull(error.cleanup.metadataIssue)
            assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
            assertTrue(r.secrets.values.isEmpty())
        }
    }

    @Test fun failedCompensationRetainsCleanupUUIDAcrossRestartAndSignOutRetriesIt() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val id = r.nextID
        r.h.rig.libraryOperations.putDirectory("Groups")
        r.secrets.deleteError = SecretStoreError.DeleteFailed
        r.respond = { if (it.url.endsWith("/auth/logout")) throw HttpTransportError.NetworkFailure else null }
        val error = assertFailsWith<SyncAccountServiceError> { r.login() }
        assertEquals(listOf(id), error.cleanup.secretFailures)
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, error.cleanup.remote)
        assertFalse(error.cleanup.isComplete)
        val restarted = r.h.rig.restart()
        assertEquals(listOf(id), restarted.accounts.loadConnection().cleanupConnections)
        assertNull(restarted.accounts.loadAccount())
        r.secrets.deleteError = null
        assertTrue(r.reopen().signOut().isComplete)
        assertTrue(r.secrets.values.isEmpty())
        assertTrue(r.h.accounts.loadConnection().cleanupConnections.isEmpty())
    }

    @Test fun reservedRootsLeaveLibraryBytesUntouchedAndRevokeTheCandidate() = runTest {
        for (name in listOf("Groups", "Conflicts", "groups", "CONFLICTS")) {
            val r = AccountHarness(testScheduler, backgroundScope)
            r.h.rig.libraryOperations.putDirectory(name)
            r.h.files.put(EngineHarness.source(id = null), "$name/a.md")
            val before = r.h.files.bytesSnapshot()
            val error = assertFailsWith<SyncAccountServiceError> { r.login() }
            assertIs<SyncAccountIssue.ReservedFolders>(error.issue)
            assertEquals(before, r.h.files.bytesSnapshot())
            assertEquals(1, r.logouts.size)
            assertTrue(r.secrets.values.isEmpty())
        }
    }

    @Test fun startupLoadsExactEnvelopeAndMakesNoAutomaticPullInBackground() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val account = r.login().account
        val restored = r.reopen().startup()
        assertEquals(account, restored.account)
        assertTrue(restored.enabled)
        assertEquals(SecretTier.KEYSTORE, restored.tier)
        assertEquals(0, r.h.pulls)
    }

    @Test fun alteredServerUserConnectionVersionAndRawTokenFailClosedBeforeHTTP() = runTest {
        for (field in listOf("server_url", "user_id", "connection_id", "version", "token", "raw", "corrupt")) {
            val r = AccountHarness(testScheduler, backgroundScope)
            val account = r.login().account!!
            val saved = r.secrets.values[account.secretAccount]!!.value
            val changed = saved.withValue { raw -> when (field) {
                "raw" -> SecretValue(r.token)
                "corrupt" -> SecretValue("{")
                else -> {
                    val fields = (WireJson.parse(raw.encodeToByteArray()) as WireValue.ObjectValue).fields.toMutableMap()
                    fields[field] = when (field) {
                        "version" -> wireLong(2)
                        "user_id" -> wireString(SyncTestValues.otherUser.rawValue)
                        "connection_id" -> wireString(UUID(1, 200).toString())
                        "server_url" -> wireString("https://elsewhere.test/paw")
                        else -> wireString("invalid")
                    }
                    SecretValue(WireJson.canonical(WireValue.ObjectValue(fields)).decodeToString())
                }
            } }
            r.secrets.values[account.secretAccount] = StoredSecret(changed, SecretTier.KEYSTORE)
            val before = r.requests.size
            val error = assertFailsWith<SyncAccountServiceError> { r.reopen().startup() }
            assertEquals(SyncAccountIssue.TokenBindingMismatch, error.issue)
            assertEquals(before, r.requests.size)
            assertFalse(r.h.engine.reports.value.enabled)
            assertTrue(r.h.engine.reports.value.needsSignIn)
        }
    }

    @Test fun missingLockedAndFailedSecretReadsRetainKnownMetadataWithoutEnabling() = runTest {
        for (fault in listOf(null, SecretStoreError.Locked, SecretStoreError.ReadFailed)) {
            val r = AccountHarness(testScheduler, backgroundScope)
            val account = r.login().account!!
            r.secrets.values.clear()
            r.secrets.readError = fault
            val reopened = r.reopen()
            assertFailsWith<SyncAccountServiceError> { reopened.startup() }
            assertEquals(account, reopened.snapshot.account)
            assertFalse(reopened.snapshot.enabled)
            assertNull(reopened.snapshot.tier)
        }
    }

    @Test fun startupMeMustMatchRecordedCurrentDeviceAndOwnedAccount() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.device = SyncTestValues.group
        assertEquals(SyncAccountIssue.TokenBindingMismatch, assertFailsWith<SyncAccountServiceError> { r.reopen().startup() }.issue)
        r.device = SyncTestValues.device
        r.h.accounts.updateBinding(r.root) { it!!.copy(owner = SyncAccountIdentity(r.server, SyncTestValues.otherUser)) }
        assertFailsWith<SyncAccountServiceError> { r.reopen().startup() }
        assertEquals(SyncTestValues.otherUser, r.h.accounts.binding(r.root)!!.owner.userID)
        assertTrue(r.puts.isEmpty())
    }

    @Test fun sameAccountReauthenticationPreservesQueuedEditsDatabaseAndCursors() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val first = r.login().account!!
        r.h.seed()
        r.h.files.put(EngineHarness.source("edited"), "a.md")
        val before = r.h.states.load(r.binding)
        val bytes = r.h.files.read("a.md")
        r.token = "B".repeat(42) + "A"
        val next = r.login().account!!
        assertNotEquals(first.connectionID, next.connectionID)
        assertEquals(before, r.h.states.load(r.binding))
        assertContentEquals(bytes, r.h.files.read("a.md"))
        assertTrue(r.puts.isEmpty())
        assertNull(r.secrets.values[first.secretAccount])
        assertTrue(r.h.accounts.binding(r.root)!!.holds.isEmpty())
    }

    @Test fun sameAccountPendingRequestRecoversBeforeActivationWithOnlyNewCredential() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.engine.stop(); r.h.engine.drain()
        r.pendingCreate()
        r.token = "B".repeat(42) + "A"
        r.respond = { req -> if (req.method == HttpMethod.GET && req.url.contains("/prompts/")) {
            assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
            assertTrue(req.headers["Authorization"] == "Bearer " + r.token)
            null
        } else null }
        r.login()
        assertTrue(r.puts.isEmpty())
        assertNull(r.h.pending.load(r.binding))
        r.h.engine.runBackground()
        assertEquals(1, r.puts.size)
        assertNull(r.h.pending.load(r.binding))
        assertTrue(r.requests.indexOfFirst { it.method == HttpMethod.GET && it.url.contains("/prompts/") } <
            r.requests.indexOfLast { it.url.endsWith("/sync/pull") })
        assertTrue(r.service.snapshot.enabled)
    }

    @Test fun differentAccountRetainsPendingFactsWithoutSendingAndHoldsAllPriorFiles() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.engine.stop(); r.h.engine.drain()
        r.pendingCreate()
        r.h.files.put(EngineHarness.source(id = null), "idless.md")
        r.h.files.put(EngineHarness.source(id = SyncTestValues.groupPrompt), "Groups/Team/g.md")
        r.h.accounts.updateBinding(r.root) { it!!.copy(managedFolders = mapOf(SyncTestValues.group to SyncManagedFolder(it.owner, "Team"))) }
        r.user = SyncTestValues.otherUser
        r.token = "B".repeat(42) + "A"
        r.login()
        assertTrue(r.puts.isEmpty())
        assertTrue(r.h.data.listFiles().any { it.relativePath.startsWith("sync/retained/push-") })
        assertNull(r.h.pending.load(r.binding))
        val owned = r.h.accounts.binding(r.root)!!
        assertEquals(r.user, owned.owner.userID)
        assertEquals(3, owned.holds.size)
        assertTrue(owned.holds.all { it.sourceAccount.userID == SyncTestValues.user && it.identity is PromptIdentity.Assigned })
        assertFalse(r.h.files.listFiles().any { it.relativePath.startsWith("Groups/Team/") })
        r.h.engine.runBackground()
        assertTrue(r.puts.isEmpty())
        assertEquals(3, r.service.heldPrompts().size)
        r.assertNoCredentials()
    }

    @Test fun differentServerNeverForwardsOldBearerAndHoldsPriorContent() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.files.put(EngineHarness.source(), "a.md")
        r.server = "https://second.test/other"
        r.token = "B".repeat(42) + "A"
        val before = r.requests.size
        r.login()
        r.h.engine.runBackground()
        for (request in r.requests.drop(before).filter { it.url.startsWith(r.server) }) {
            if (!request.url.endsWith("/auth/login")) assertTrue(request.headers["Authorization"] == "Bearer " + r.token)
        }
        assertTrue(r.puts.isEmpty())
        assertEquals(1, r.service.heldPrompts().size)
    }

    @Test fun signOutRetainsOwnershipForLaterDifferentUserIncludingIdlessFiles() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.files.put(EngineHarness.source(id = null), "idless.md")
        val files = r.h.files.bytesSnapshot()
        assertTrue(r.service.signOut().isComplete)
        assertEquals(files, r.h.files.bytesSnapshot())
        assertNotNull(r.h.accounts.binding(r.root))
        r.user = SyncTestValues.otherUser
        r.login()
        assertEquals(1, r.service.heldPrompts().size)
        assertIs<PromptIdentity.Assigned>(r.service.heldPrompts().single().identity)
        r.h.engine.runBackground()
        assertTrue(r.puts.isEmpty())
    }

    @Test fun renameEditAndReauthenticationNeverReleaseAHoldButSelectedConsentDoes() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.files.put(EngineHarness.source(), "a.md")
        r.h.files.put(EngineHarness.source(id = SyncTestValues.groupPrompt), "b.md")
        r.user = SyncTestValues.otherUser
        r.login()
        val selected = r.service.heldPrompts().single { it.path == "a.md" }.identity
        r.h.files.move("a.md", "renamed.md")
        r.h.files.put(EngineHarness.source("changed"), "renamed.md")
        r.login()
        r.h.engine.runBackground()
        assertTrue(r.puts.isEmpty())
        r.service.includeHeld(setOf(selected))
        r.h.engine.runBackground()
        assertEquals(1, r.puts.size)
        assertEquals("renamed.md", PutPromptRequest.codec.decode(r.puts.single().body!!).path)
        assertEquals(1, r.service.heldPrompts().size)
    }

    @Test fun invalidIncludeSelectionFailsWithoutReleasingAnyHold() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.files.put(EngineHarness.source(), "a.md")
        r.user = SyncTestValues.otherUser
        r.login()
        val holds = r.service.heldPrompts()
        assertFailsWith<SyncAccountServiceError> { r.service.includeHeld(setOf(SyncTestValues.groupID)) }
        assertEquals(holds, r.service.heldPrompts())
        assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
        assertFalse(r.service.snapshot.enabled)
    }

    @Test fun deviceListingUsesMeAndNonCurrentOrForeignRevocationKeepsTheConnection() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.me = { MeResponse(r.userDTO(), emptyList(), listOf(r.deviceDTO(), r.deviceDTO(SyncTestValues.group, false, true))) }
        assertEquals(2, r.service.devices().size)
        r.service.revokeDevice(SyncTestValues.group)
        assertTrue(r.service.snapshot.enabled)
        r.respond = { if (it.url.contains("/me/devices/")) EngineHarness.errorResponse(404, FailureCode.NOT_FOUND) else null }
        assertFailsWith<SyncAccountServiceError> { r.service.revokeDevice(SyncTestValues.otherUser) }
        assertTrue(r.service.snapshot.enabled)
        assertTrue(r.requests.none { it.url.endsWith("/devices") })
    }

    @Test fun currentDeviceRevokeAlwaysSignsOutEvenOfflineAndKeepsLibraryOwnership() = runTest {
        for (offline in listOf(false, true)) {
            val r = AccountHarness(testScheduler, backgroundScope)
            r.login()
            r.h.files.put(EngineHarness.source(), "a.md")
            val bytes = r.h.files.bytesSnapshot()
            if (offline) r.respond = { if (it.url.contains("/me/devices/")) throw HttpTransportError.NetworkFailure else null }
            val result = r.service.revokeDevice(r.device)
            assertFalse(result.enabled)
            assertNull(result.account)
            assertEquals(if (offline) SyncRemoteRevocation.UNCONFIRMED else SyncRemoteRevocation.REVOKED, result.cleanup.remote)
            assertTrue(r.secrets.values.isEmpty())
            assertNull(r.h.accounts.loadAccount())
            assertNull(r.h.states.snapshot.value)
            assertNotNull(r.h.accounts.binding(r.root))
            assertEquals(bytes, r.h.files.bytesSnapshot())
        }
    }

    @Test fun offlineLogoutDisablesResumeClearsCredentialsAndLeavesLibraryBytes() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.files.put(EngineHarness.source(), "a.md")
        val bytes = r.h.files.bytesSnapshot()
        r.respond = { throw HttpTransportError.NetworkFailure }
        val cleanup = r.service.signOut()
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, cleanup.remote)
        assertFalse(cleanup.isComplete)
        assertTrue(r.secrets.values.isEmpty())
        assertFalse(r.h.engine.reports.value.enabled)
        assertEquals(bytes, r.h.files.bytesSnapshot())
        val requests = r.requests.size
        val reads = r.secrets.reads.size
        r.reopen().startup()
        r.h.engine.syncNow(); advanceTimeBy(600_001); runCurrent()
        assertEquals(requests, r.requests.size)
        assertEquals(reads, r.secrets.reads.size)
    }

    @Test fun inactiveAndSignedOutStartupStopAnyOldForegroundSessionWithoutSecretLookup() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.engine.setExecutionMode(SyncExecutionMode.FOREGROUND); runCurrent()
        r.h.accounts.disableAutomaticResume()
        val requests = r.requests.size
        val reads = r.secrets.reads.size
        assertFalse(r.service.startup().enabled)
        r.h.engine.syncNow(); advanceTimeBy(60_001); runCurrent()
        assertEquals(requests, r.requests.size)
        assertEquals(reads, r.secrets.reads.size)
        assertFailsWith<SyncAccountServiceError> { r.service.refresh() }
    }

    @Test fun logoutDeleteFailureIsDurableAndLaterSignOutRetriesWithoutHTTP() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val account = r.login().account!!
        r.secrets.deleteError = SecretStoreError.DeleteFailed
        val cleanup = r.service.signOut()
        assertEquals(listOf(account.connectionID), cleanup.secretFailures)
        assertEquals(listOf(account.connectionID), r.h.rig.restart().accounts.loadConnection().cleanupConnections)
        val requests = r.requests.size
        val reads = r.secrets.reads.size
        r.reopen().startup()
        assertEquals(reads, r.secrets.reads.size)
        r.secrets.deleteError = null
        assertTrue(r.reopen().signOut().isComplete)
        assertEquals(requests, r.requests.size)
        assertTrue(r.h.accounts.loadConnection().cleanupConnections.isEmpty())
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun failedMetadataClearStillLeavesDurableInactiveConnection() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val account = r.login().account!!
        var count = 0
        r.h.data.fault = { op, path -> if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/account.json" && ++count >= 2) StoreError.IOFailure else null }
        val cleanup = r.service.signOut()
        assertNotNull(cleanup.metadataIssue)
        assertFalse(r.service.snapshot.enabled)
        r.h.data.fault = null
        assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
        assertEquals(account, r.h.accounts.loadAccount())
        val requests = r.requests.size
        r.reopen().startup()
        assertEquals(requests, r.requests.size)
    }

    @Test fun corruptOwnershipCannotHideCredentialCleanupAndIsNeverRewritten() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val account = r.login().account!!
        r.h.data.put("{", "sync/binding.json")
        val cleanup = r.reopen().signOut()
        assertEquals(SyncRemoteRevocation.REVOKED, cleanup.remote)
        assertNull(r.secrets.values[account.secretAccount])
        assertEquals("{", r.h.data.text("sync/binding.json"))
        assertNull(r.h.accounts.connectionForSignOut().account)
    }

    @Test fun corruptConnectionReportsUnknownRemoteRevocationWithoutDroppingLiveSecretReference() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.data.put("{", "sync/account.json")
        val cleanup = r.reopen().signOut()
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, cleanup.remote)
        assertEquals(SyncError.CorruptFile, cleanup.metadataIssue)
        assertFalse(cleanup.isComplete)
    }

    @Test fun cleanupMeValidationAndLogoutShareOneFiveSecondDeadline() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.respond = { request -> when {
            request.url.endsWith("/me") -> { delay(4_000); null }
            request.url.endsWith("/auth/logout") -> { delay(2_000); null }
            else -> null
        } }
        val start = testScheduler.currentTime
        val cleanup = r.reopen().signOut()
        assertEquals(5_000, testScheduler.currentTime - start)
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, cleanup.remote)
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun blockedSecretReadCannotPreventCancellationOrFiveSecondRemoteCleanup() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        val release = CompletableDeferred<Unit>()
        r.secrets.beforeRead = { withContext(NonCancellable) { release.await() } }
        val reopened = r.reopen()
        val startup = launch { reopened.startup() }
        runCurrent()
        assertTrue(reopened.isBusy)
        startup.cancel(); runCurrent()
        assertTrue(startup.isCompleted)
        assertFalse(reopened.isBusy)
        val before = testScheduler.currentTime
        val cleanup = r.reopen().signOut()
        assertEquals(5_000, testScheduler.currentTime - before)
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, cleanup.remote)
        assertTrue(r.secrets.values.isEmpty())
        release.complete(Unit); runCurrent()
        assertFalse(reopened.snapshot.enabled)
    }

    @Test fun cancelledCandidateStillGetsIndependentRevocationWithoutAdoption() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.respond = { if (it.url.endsWith("/me")) awaitCancellation() else null }
        val login = launch { r.login() }
        runCurrent(); login.cancel(); runCurrent()
        assertTrue(login.isCompleted)
        assertEquals(1, r.logouts.size)
        assertEquals(SyncRemoteRevocation.REVOKED, r.service.snapshot.cleanup.remote)
        assertTrue(r.secrets.values.isEmpty())
        assertNull(r.h.accounts.loadAccount())
    }

    @Test fun cancelledWriteFinishesThenCompensatesBeforeAnotherOperationCanEnter() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val release = CompletableDeferred<Unit>()
        r.secrets.beforeWrite = { release.await() }
        val login = launch { r.login() }
        runCurrent(); login.cancel(); runCurrent()
        assertFalse(login.isCompleted)
        assertEquals(SyncAccountIssue.Busy, assertFailsWith<SyncAccountServiceError> { r.login() }.issue)
        release.complete(Unit); runCurrent()
        assertTrue(login.isCompleted)
        assertFalse(r.service.isBusy)
        assertTrue(r.secrets.values.isEmpty())
        assertEquals(1, r.logouts.size)
    }

    @Test fun sameServiceRejectsConcurrentCompoundOperationWithoutASecondLogin() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val release = CompletableDeferred<Unit>()
        r.respond = { if (it.url.endsWith("/auth/login")) { release.await(); null } else null }
        val first = launch { r.login() }
        runCurrent()
        assertEquals(SyncAccountIssue.Busy, assertFailsWith<SyncAccountServiceError> { r.login() }.issue)
        assertEquals(1, r.requests.size)
        release.complete(Unit); first.join()
    }

    @Test fun signOutRetainsPendingWriteWithoutSendingAndFailedRecoveryCannotUseRetiredToken() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.engine.stop(); r.h.engine.drain()
        r.pendingCreate()
        assertTrue(r.service.signOut().isComplete)
        assertTrue(r.puts.isEmpty())
        assertTrue(r.h.data.listFiles().any { it.relativePath.startsWith("sync/retained/push-") })
        assertFailsWith<SyncError> { r.h.engine.recoverJournal() }
        assertTrue(r.puts.isEmpty())
    }

    @Test fun unreadableApplyJournalPreservesStateAndRecoveryButStillClearsCredentials() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val account = r.login().account!!
        r.h.data.put("{", "sync/apply.json")
        assertFailsWith<SyncError> { r.h.rig.journal.replay() }
        val service = r.reopen()
        val cleanup = service.signOut()
        assertTrue(cleanup.recoveryRequired)
        assertNotNull(r.h.states.snapshot.value ?: r.h.states.loadForAccountTransition())
        assertEquals("{", r.h.data.text("sync/apply.json"))
        assertNull(r.secrets.values[account.secretAccount])
        assertFailsWith<SyncError> { r.h.engine.recoverJournal() }
        assertTrue(r.puts.isEmpty())
    }

    @Test fun refreshUnauthorizedImmediatelyRetiresCredentialsAndWork() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.respond = { if (it.url.endsWith("/me")) EngineHarness.errorResponse(401, FailureCode.UNAUTHORIZED) else null }
        assertFailsWith<SyncAccountServiceError> { r.service.refresh() }
        assertFalse(r.service.snapshot.enabled)
        assertNull(r.service.snapshot.me)
        assertNull(r.service.snapshot.tier)
        assertTrue(r.h.engine.reports.value.needsSignIn)
        assertFailsWith<SyncError> { r.h.engine.recoverJournal() }
    }

    @Test fun oldCleanupReferenceSurvivesNewActivationAndDoubleCleanupFailure() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val old = r.login().account!!
        r.secrets.deleteError = SecretStoreError.DeleteFailed
        r.login(r.reopen())
        assertEquals(listOf(old.connectionID), r.h.rig.restart().accounts.loadConnection().cleanupConnections)
        assertEquals(listOf(old.connectionID), r.reopen().startup().cleanup.secretFailures)
        r.secrets.deleteError = null
        r.service.signOut()
        assertTrue(r.h.accounts.loadConnection().cleanupConnections.isEmpty())
    }

    @Test fun inviteRegistrationSharesActivationAndReportsCommittedAccountOnLocalFailure() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val invite = SecretValue("C".repeat(42) + "A")
        r.secrets.writeError = SecretStoreError.WriteFailed
        val error = assertFailsWith<SyncAccountServiceError> { r.service.register(r.server, "person", r.password, invite, "Android") }
        assertTrue(error.registrationCommitted)
        assertEquals(SyncRemoteRevocation.REVOKED, error.cleanup.remote)
        assertNull(r.h.accounts.loadAccount())
        r.secrets.writeError = null
        assertTrue(r.service.register(r.server, "person", r.password, invite, "Android").enabled)
        for (file in r.h.data.listFiles()) invite.withValue { assertFalse(r.h.data.text(file.relativePath).contains(it)) }
    }

    @Test fun serviceSnapshotsAndErrorsHaveFixedRedactedDiagnostics() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        assertEquals("<sync account service redacted>", r.service.toString())
        assertEquals("<sync account snapshot redacted>", r.service.snapshot.toString())
        assertEquals("<sync account cleanup redacted>", r.service.snapshot.cleanup.toString())
        val error = SyncAccountServiceError(SyncAccountIssue.Secret(SecretStoreError.Locked))
        assertEquals("<sync account error redacted>", error.toString())
        assertNull(error.cause)
        r.assertNoCredentials()
    }

    @Test fun accountChangeFlushFailureKeepsInactiveConnectionAndJournalThenReplaysBeforeEnablement() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        r.h.files.put(EngineHarness.source(id = null), "old.md")
        r.user = SyncTestValues.otherUser
        var failed = false
        r.h.rig.dataOperations.onOperation = { op -> if (op == "file:sync/binding.json" && !failed) {
            failed = true
            throw StoreError.IOFailure
        } }
        assertFailsWith<SyncAccountServiceError> { r.login() }
        assertNotNull(r.h.rig.journal.pending)
        assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.connectionForSignOut().activation)
        assertFalse(r.service.snapshot.enabled)
        assertFailsWith<LibraryError> { r.h.rig.local.library.entries() }
        val requests = r.requests.size
        assertFailsWith<SyncAccountServiceError> { r.service.startup() }
        assertEquals(requests, r.requests.size)
        r.h.rig.dataOperations.onOperation = null
        r.login()
        assertNull(r.h.rig.journal.pending)
        assertEquals(1, r.service.heldPrompts().size)
        r.h.engine.runBackground()
        assertTrue(r.puts.isEmpty())
    }

    @Test fun unavailableRootRejectsActivationAndCompensatesWithoutMutatingLibrary() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.h.files.put(EngineHarness.source(), "a.md")
        val before = r.h.files.bytesSnapshot()
        r.h.engine.rootHealthChanged(SyncRootHealth.UNAVAILABLE)
        assertFailsWith<SyncAccountServiceError> { r.login() }
        assertEquals(before, r.h.files.bytesSnapshot())
        assertEquals(1, r.logouts.size)
        assertTrue(r.secrets.values.isEmpty())
        assertNull(r.h.accounts.binding(r.root))
        assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.loadConnection().activation)
    }

    @Test fun oldSecretReferenceSurvivesSuccessfulOtherDeletionAndMetadataFailure() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val old = r.login().account!!
        val spare = UUID(0, 5)
        r.h.accounts.setAccount(old, retiring = listOf(spare))
        r.secrets.values[SecretAccount.device(spare)] = StoredSecret(SecretValue("unused synthetic"), SecretTier.KEYSTORE)
        r.secrets.beforeDelete = { account ->
            if (account == SecretAccount.device(spare)) r.h.data.fault = { op, path ->
                if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/account.json") StoreError.IOFailure else null
            }
            if (account == old.secretAccount) throw SecretStoreError.DeleteFailed
        }
        val result = r.login(r.reopen())
        assertEquals(listOf(old.connectionID), result.cleanup.secretFailures)
        assertNotNull(result.cleanup.metadataIssue)
        assertEquals(listOf(spare, old.connectionID), r.h.rig.restart().accounts.loadConnection().cleanupConnections)
        assertNotNull(r.secrets.values[old.secretAccount])
        assertNull(r.secrets.values[SecretAccount.device(spare)])
        r.h.data.fault = null
        r.secrets.beforeDelete = null
        assertTrue(r.reopen().signOut().isComplete)
        assertTrue(r.h.accounts.loadConnection().cleanupConnections.isEmpty())
    }

    @Test fun blockedNativeReadHoldingStoreLockCannotHangLocalSignOut() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        val account = r.login().account!!
        val mutex = Mutex()
        val release = CompletableDeferred<Unit>()
        val serialized = object : SecretStore {
            override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? = mutex.withLock {
                withContext(NonCancellable) { release.await() }
                r.secrets.read(account, source)
            }
            override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier = mutex.withLock { r.secrets.write(value, account) }
            override suspend fun delete(account: SecretAccount) = mutex.withLock { r.secrets.delete(account) }
        }
        val service = r.reopen(serialized)
        val startup = launch { service.startup() }
        runCurrent(); startup.cancel(); runCurrent()
        assertTrue(startup.isCompleted)
        val cleanup = async { service.signOut() }
        advanceTimeBy(10_000); runCurrent()
        val completed = cleanup.isCompleted
        release.complete(Unit); runCurrent()
        val result = cleanup.await()
        assertTrue(completed, "Cleanup must return while the native read still owns the secret-store lock")
        assertEquals(listOf(account.connectionID), result.secretFailures)
        assertEquals(listOf(account.connectionID), r.h.accounts.loadConnection().cleanupConnections)
        assertFalse(service.snapshot.enabled)
        assertTrue(service.signOut().isComplete)
    }

    @Test fun ownershipAndStatePublicationFailuresNeverEnableOrAdoptTheCandidate() = runTest {
        for (path in listOf("sync/binding.json", "sync/state.json")) {
            for (flush in listOf(false, true)) {
                val r = AccountHarness(testScheduler, backgroundScope)
                r.h.files.put(EngineHarness.source(), "a.md")
                val before = r.h.files.bytesSnapshot()
                var failed = false
                if (flush) r.h.rig.dataOperations.onOperation = { op -> if (op == "file:$path" && !failed) {
                    failed = true
                    throw StoreError.IOFailure
                } } else r.h.data.fault = { op, target ->
                    if (op == MemoryStore.Operation.PRIVATE_WRITE && target == path && !failed) {
                        failed = true
                        StoreError.IOFailure
                    } else null
                }
                assertFailsWith<SyncAccountServiceError> { r.login() }
                assertTrue(failed)
                assertFalse(r.service.snapshot.enabled)
                assertEquals(SyncAccountActivation.INACTIVE, r.h.accounts.connectionForSignOut().activation)
                assertEquals(before, r.h.files.bytesSnapshot())
                assertTrue(r.puts.isEmpty())
                assertTrue(r.secrets.values.isEmpty())
                val requests = r.requests.size
                try { r.reopen().startup() } catch (_: SyncAccountServiceError) { }
                assertEquals(requests, r.requests.size)
            }
        }
    }

    @Test fun explicitInclusionDoesNotBypassInvalidContentUploadPolicy() = runTest {
        val r = AccountHarness(testScheduler, backgroundScope)
        r.login()
        val raw = byteArrayOf(-1, 0, 1)
        r.h.files.put(raw, "invalid.md")
        r.user = SyncTestValues.otherUser
        r.login()
        val identity = r.service.heldPrompts().single().identity
        r.service.includeHeld(setOf(identity))
        r.h.engine.runBackground()
        assertContentEquals(raw, r.h.files.read("invalid.md"))
        assertTrue(r.puts.isEmpty())
        assertTrue(r.h.engine.reports.value.counts.fileErrors > 0)
    }
}
