@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.ui.account

import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AppModule
import ch.lkmc.monkeyspaw.entry.InviteIntentDecoder
import android.content.Intent
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.*

internal class AccountViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val rigs = mutableListOf<Rig>()

    @BeforeTest fun main() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun close() {
        models.clear()
        for (rig in rigs) rig.scope.cancel()
        dispatcher.scheduler.runCurrent()
        Dispatchers.resetMain()
    }

    private class Secrets : SecretStore {
        val values = mutableMapOf<SecretAccount, StoredSecret>()
        var reads = 0
        var failDelete = false
        override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? { reads++; return values[account] }
        override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
            values[account] = StoredSecret(value, SecretTier.KEYSTORE)
            return SecretTier.KEYSTORE
        }
        override suspend fun delete(account: SecretAccount) {
            if (failDelete) throw SecretStoreError.DeleteFailed
            values.remove(account)
        }
    }

    private inner class Rig {
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val io = JvmCheckedSyncIO()
        val prompts = AndroidPromptStore(libraryDir.toFile(), io = io)
        val files = AndroidStateStore(stateDir.toFile(), isMainThread = { false }, io = io)
        val library = library(files, prompts)
        val startup = AndroidSyncStartup(library, prompts, files, libraryDir.toFile().absolutePath, dispatcher)
        val local = LibraryRepository(library, EditingService(library), prompts, dispatcher) { startup.ready() }
        var failSettingsRead = false
        var failAuthenticationScheduling = false
        private val settingsData = DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
            produceFile = { filesDir.resolve("datastore/settings.json").toFile() })
        val settings = AndroidSettingsStore(object : DataStore<AndroidSettings> by settingsData {
            override val data = flow {
                if (failSettingsRead) throw java.io.IOException("Synthetic settings failure")
                emitAll(settingsData.data)
            }
        })
        val secrets = Secrets()
        val requests = mutableListOf<HttpRequest>()
        val enqueued = mutableListOf<SyncWorkRequest>()
        val canceled = mutableListOf<String>()
        var userID = userA
        var memberships = emptyList<GroupMembership>()
        var handler: (suspend (HttpRequest) -> HttpResponse?)? = null
        private val transport = HttpTransport { request ->
            requests.add(request)
            handler?.invoke(request) ?: when {
                request.url.endsWith("/auth/login") -> HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse("A".repeat(43), user())))
                request.url.endsWith("/auth/register") -> HttpResponse(200,
                    body = AuthResponse.codec.encode(AuthResponse("C".repeat(42) + "A", user())))
                request.url.endsWith("/groups/join") -> {
                    val joined = GroupMembership("01ARZ3NDEKTSV4RRFFQ69G5FAZ", "Team", Role.VIEWER)
                    if (memberships.none { it.groupID == joined.groupID }) memberships = memberships + joined
                    HttpResponse(200, body = GroupMembership.codec.encode(joined))
                }
                request.url.endsWith("/me") -> HttpResponse(200, body = MeResponse.codec.encode(MeResponse(user(), memberships, listOf(
                    Device(deviceA, "Android", time, time, null, true), Device(deviceB, "Desktop", time, null, null, false)))))
                request.url.endsWith("/sync/pull") -> HttpResponse(200, body = PullResponse.codec.encode(PullResponse(databaseID,
                    listOf(SyncScope(ScopeIdentity.User(userID), Mode.SNAPSHOT, 1, "u-1", false, emptyList())) +
                        memberships.map { SyncScope(ScopeIdentity.Group(it.groupID, it.name, it.role), Mode.SNAPSHOT, 1, "g-1", false, emptyList()) }, emptyList())))
                request.url.endsWith("/auth/logout") || request.url.contains("/devices/") -> HttpResponse(200, body = EmptyResponse.codec.encode(EmptyResponse))
                request.method == HttpMethod.PUT -> HttpResponse(200, body = WriteResponse.codec.encode(WriteResponse(1, 2)))
                else -> error("Unexpected synthetic HTTP request")
            }
        }
        val scheduler: SyncWorkScheduler by lazy {
            SyncWorkScheduler(SyncWorkPolicy(SyncWorkStateStore(files, files.syncOperations), object : SyncWorkQueue {
                override suspend fun periodic(generation: String, intervalMillis: Long) {}
                override suspend fun once(request: SyncWorkRequest) { enqueued.add(request) }
                override suspend fun cancel(generation: String) { canceled.add(generation) }
            }, AndroidSyncWorkSession(startup, Lazy { sync }), { Instant.parse(time).toEpochMilli() }, 31), dispatcher)
        }
        private val hooks = object : SyncWorkHooks {
            override suspend fun authenticationStopped() = scheduler.authenticationStopped()
            override suspend fun authenticated(connection: String) {
                if (failAuthenticationScheduling) throw java.io.IOException("Synthetic scheduling failure")
                scheduler.authenticated(connection)
            }
            override suspend fun signedOut() { scheduler.signedOut() }
            override suspend fun saved() { scheduler.saved() }
            override suspend fun changed() { scheduler.changed() }
        }
        private var draw = 0
        val sync = AppModule.syncRepository(startup, library, local, scope, dispatcher, Clock { Instant.parse(time) },
            Entropy { count -> ByteArray(count) { (draw++).toByte() } }, MonotonicClock(System::nanoTime), Lazy { secrets }, Lazy { transport }, settings, hooks)
        fun user() = User(userID, "person", null, AccountKind.MEMBER, time, null)
        suspend fun login() = sync.login(server, "person", SecretValue(password), "Android")
        suspend fun close() { scope.cancel(); scope.coroutineContext[Job]!!.join() }
    }

    private fun rig() = Rig().also { rigs.add(it) }
    private fun model(rig: Rig) = AccountViewModel(rig.sync, rig.scheduler).also { models.put("model-${rigs.size}", it) }
    private fun credentials(model: AccountViewModel, selectedServer: String = server) {
        model.setServer(selectedServer)
        model.setUsername("person")
        model.setDeviceName("Android")
        model.setPassword(password)
    }
    private fun count(r: Rig, suffix: String) = r.requests.count { it.url.endsWith(suffix) }

    @Test fun `construction is passive and inactive refresh does no HTTP or secret lookup`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        runCurrent()
        assertTrue(r.requests.isEmpty())
        assertNull(r.sync.accounts.value)
        m.refresh(); m.refresh()
        assertEquals(AccountAction.REFRESH, m.state.value.busy)
        runCurrent()
        assertEquals(AccountCondition.INACTIVE, m.state.value.condition)
        assertNull(m.state.value.busy)
        assertEquals(0, r.secrets.reads)
        assertTrue(r.requests.isEmpty())
        assertTrue(r.enqueued.isEmpty())
    }

    @Test fun `inactive retained metadata requires explicit sign in and never reads its secret`() = runTest(dispatcher) {
        val r = rig()
        r.startup.ready().accounts.setAccount(SyncAccount(SyncAccountIdentity(server, checkNotNull(ULID.parse(userA))),
            "person", checkNotNull(ULID.parse(deviceA)), "Android", UUID.randomUUID()), SyncAccountActivation.INACTIVE)
        val m = model(r)
        m.refresh(); runCurrent()
        assertEquals(AccountCondition.INACTIVE, m.state.value.condition)
        assertEquals(server, m.state.value.draft.server)
        assertEquals("person", m.state.value.draft.username)
        assertEquals(0, r.secrets.reads)
        assertTrue(r.requests.isEmpty())
    }

    @Test fun `sign in clears password before IO and repeated taps issue one login and me`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        credentials(m)
        m.signIn(); m.signIn()
        assertEquals("", m.state.value.draft.password)
        assertEquals(AccountAction.SIGN_IN, m.state.value.busy)
        runCurrent()
        assertEquals(AccountCondition.ACTIVE, m.state.value.condition)
        assertEquals("", m.state.value.draft.password)
        assertEquals(1, count(r, "/auth/login"))
        assertEquals(1, count(r, "/me"))
        assertNull(m.state.value.failure)
        assertTrue(m.state.value.canSync)
        val disk = Files.walk(filesDir).use { paths -> paths.filter { Files.isRegularFile(it) }.map { Files.readString(it) }.toList().joinToString() }
        assertFalse(disk.contains(password))
        assertFalse(m.state.value.toString().contains(password))
        assertFalse(m.state.value.draft.toString().contains(password))
    }

    @Test fun `invalid input clears password without HTTP and cancellation clears a newer password`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        credentials(m, "http://public.example")
        m.signIn(); runCurrent()
        assertEquals(R.string.account_invalid_input, m.state.value.failure)
        assertEquals("", m.state.value.draft.password)
        assertTrue(r.requests.isEmpty())
        credentials(m)
        val started = CompletableDeferred<Unit>()
        r.handler = { if (it.url.endsWith("/auth/login")) { started.complete(Unit); awaitCancellation() } else null }
        m.signIn(); runCurrent(); started.await()
        m.setPassword("new synthetic secret")
        m.cancel(); runCurrent()
        assertEquals("", m.state.value.draft.password)
        assertNull(m.state.value.busy)
        assertEquals(AccountCondition.INACTIVE, m.state.value.condition)
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun `offline and unauthorized errors are fixed states with no invented last success`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        credentials(m)
        r.handler = { throw HttpTransportError.NetworkFailure }
        m.signIn(); runCurrent()
        assertEquals(AccountCondition.OFFLINE, m.state.value.condition)
        assertEquals(R.string.sync_offline, m.state.value.failure)
        assertNull(m.state.value.sync.lastSuccess)
        r.handler = { HttpResponse(401, body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.UNAUTHORIZED))) }
        m.setPassword(password); m.signIn(); runCurrent()
        assertEquals(AccountCondition.NEEDS_SIGN_IN, m.state.value.condition)
        assertEquals("", m.state.value.draft.password)
        assertNull(m.state.value.sync.lastSuccess)
    }

    @Test fun `HTTP warning and trust follow the normalized deployment and stale edits cannot transfer trust`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        m.setServer("http://192.168.1.2/paw/api/v1/"); runCurrent()
        assertTrue(m.state.value.httpWarning)
        assertEquals("http://192.168.1.2/paw", m.state.value.server?.baseURL)
        m.setTrust(true); runCurrent()
        assertFalse(m.state.value.trustsUserCAs)
        m.setServer("HTTPS://EXAMPLE.TEST:443/paw/api/v1"); runCurrent()
        assertFalse(m.state.value.httpWarning)
        m.setTrust(true); runCurrent()
        assertTrue(m.state.value.trustsUserCAs)
        assertEquals(SyncTLSTrust.SYSTEM_AND_USER, r.settings.read().syncTls?.trustFor(SyncServerURL(server)))
        m.setServer(server + "/api/v1/"); runCurrent()
        assertTrue(m.state.value.trustsUserCAs)
        m.setServer("https://example.test/other")
        assertFalse(m.state.value.trustsUserCAs)
        runCurrent()
        assertEquals(SyncTLSTrust.SYSTEM, r.settings.read().syncTls?.trust)
        m.setTrust(true)
        m.setServer(server)
        runCurrent()
        assertFalse(m.state.value.trustsUserCAs)
        assertEquals(SyncTLSTrust.SYSTEM, r.settings.read().syncTls?.trust)
        assertTrue(r.requests.isEmpty())
    }

    @Test fun `refresh coalesces and does not overwrite newer server user or device drafts`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        r.handler = { if (it.url.endsWith("/me")) { started.complete(Unit); release.await() }; null }
        runCurrent()
        val before = count(r, "/me")
        m.refresh(); m.refresh(); runCurrent(); started.await()
        m.setServer("https://other.test/paw")
        m.setUsername("newperson")
        m.setDeviceName("New device")
        release.complete(Unit); runCurrent()
        assertEquals(before + 1, count(r, "/me"))
        assertEquals("https://other.test/paw", m.state.value.draft.server)
        assertEquals("newperson", m.state.value.draft.username)
        assertEquals("New device", m.state.value.draft.deviceName)
        assertEquals(server, m.state.value.account.account?.identity?.serverURL)
        assertEquals(2, m.state.value.account.me?.devices?.size)
    }

    @Test fun `explicit trust reaches only requests for its selected deployment`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        m.setServer(server); runCurrent()
        m.setTrust(true); runCurrent()
        credentials(m); m.signIn(); runCurrent()
        assertTrue(r.requests.isNotEmpty())
        for (request in r.requests) assertEquals(SyncTLSTrust.SYSTEM_AND_USER, (request.urlPolicy as HttpUrlPolicy.Sync).trust)
        val other = "https://other.test/paw"
        credentials(m, other); m.signIn(); runCurrent()
        assertEquals(other, m.state.value.account.account?.identity?.serverURL)
        val changed = r.requests.filter { it.url.startsWith(other + "/api/v1/") }
        assertEquals(2, changed.size)
        for (request in changed) assertEquals(SyncTLSTrust.SYSTEM, (request.urlPolicy as HttpUrlPolicy.Sync).trust)
    }

    @Test fun `rapid server round trips never restore a trust choice after it was reset`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        m.setServer(server); runCurrent()
        m.setTrust(true); runCurrent()
        assertTrue(m.state.value.trustsUserCAs)
        m.setServer("https://other.test/paw")
        m.setServer(server)
        runCurrent()
        assertFalse(m.state.value.trustsUserCAs)
        assertEquals(SyncTLSTrust.SYSTEM, r.settings.read().syncTls?.trust)
        m.setTrust(true); runCurrent()
        m.setServer("")
        m.setServer(server)
        runCurrent()
        assertFalse(m.state.value.trustsUserCAs)
        assertEquals(SyncTLSTrust.SYSTEM, r.settings.read().syncTls?.trust)
    }

    @Test fun `reserved folders refuse activation and recovery cannot rename or delete user content`() = runTest(dispatcher) {
        val r = rig()
        put(libraryDir.resolve("Groups/keep.md"), "preserve".encodeToByteArray())
        val m = model(r)
        credentials(m); m.signIn(); runCurrent()
        assertEquals(R.string.account_reserved_folders, m.state.value.failure)
        assertFalse(m.state.value.account.enabled)
        val before = r.requests.size
        m.recover(); m.syncNow(); runCurrent()
        assertEquals(before, r.requests.size)
        assertEquals("preserve", Files.readString(libraryDir.resolve("Groups/keep.md")))
        assertEquals(1, count(r, "/auth/logout"))
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun `corrupt metadata is explicit recovery with no network or destructive repair`() = runTest(dispatcher) {
        val r = rig()
        put(stateDir.resolve("sync/account.json"), "broken".encodeToByteArray())
        val m = model(r)
        m.refresh(); runCurrent()
        assertEquals(AccountCondition.RECOVERY, m.state.value.condition)
        assertEquals(R.string.sync_recovery_required, m.state.value.failure)
        m.recover(); runCurrent()
        assertEquals("broken", Files.readString(stateDir.resolve("sync/account.json")))
        assertTrue(r.requests.isEmpty())
        assertFalse(Files.exists(libraryDir))
    }

    @Test fun `cold missing root still allows explicit credential cleanup without recreating the root`() = runTest(dispatcher) {
        val first = rig()
        first.login()
        first.close()
        Files.walk(libraryDir).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
        val r = rig()
        r.secrets.values.putAll(first.secrets.values)
        val m = model(r)
        m.refresh(); runCurrent()
        assertEquals(AccountCondition.RECOVERY, m.state.value.condition)
        assertNull(m.state.value.account.account)
        m.requestSignOut()
        assertTrue(m.state.value.signOutConfirmation)
        m.signOut(); runCurrent()
        assertTrue(r.secrets.values.isEmpty())
        assertFalse(Files.exists(libraryDir))
        assertTrue(m.state.value.cleanup.isComplete)
        assertEquals(AccountCondition.INACTIVE, m.state.value.condition)
    }

    @Test fun `membership roles are the authoritative account response without a separate devices request`() = runTest(dispatcher) {
        val r = rig()
        r.memberships = listOf(GroupMembership("01ARZ3NDEKTSV4RRFFQ69G5FAZ", "Team", Role.VIEWER))
        val m = model(r)
        credentials(m); m.signIn(); runCurrent()
        assertEquals(r.memberships, m.state.value.account.me?.groups)
        assertEquals(2, m.state.value.account.me?.devices?.size)
        assertEquals(1, count(r, "/me"))
        assertEquals(0, r.requests.count { it.url.endsWith("/devices") })
    }

    @Test fun `sign out supersedes a blocked refresh and reports offline credential cleanup failures`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        runCurrent()
        val entered = CompletableDeferred<Unit>()
        r.handler = { if (it.url.endsWith("/me")) { entered.complete(Unit); awaitCancellation() } else throw HttpTransportError.NetworkFailure }
        m.refresh(); runCurrent(); entered.await()
        r.secrets.failDelete = true
        m.requestSignOut(); m.signOut(); m.signOut(); runCurrent()
        assertNull(m.state.value.account.account)
        assertEquals(AccountCondition.INACTIVE, m.state.value.condition)
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, m.state.value.cleanup.remote)
        assertEquals(1, m.state.value.cleanup.secretFailures.size)
        assertFalse(m.state.value.cleanup.isComplete)
        assertEquals(1, count(r, "/auth/logout"))
        assertFalse(r.sync.reports.value!!.enabled)
        assertFalse(r.scheduler.authenticationStopped())
        r.handler = null; r.secrets.failDelete = false
        m.requestSignOut(); m.signOut(); runCurrent()
        assertTrue(m.state.value.cleanup.secretFailures.isEmpty())
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun `current device revoke returns signed out even offline and another device retains the account`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        runCurrent()
        m.requestRevoke(deviceB); m.revokeDevice(); m.revokeDevice(); runCurrent()
        assertEquals(1, count(r, "/devices/$deviceB"))
        assertTrue(m.state.value.account.enabled)
        r.handler = { if (it.url.endsWith("/devices/$deviceA")) throw HttpTransportError.NetworkFailure else null }
        m.setPassword(password)
        m.requestRevoke(deviceA); m.revokeDevice(); m.revokeDevice(); runCurrent()
        assertNull(m.state.value.account.account)
        assertEquals(AccountCondition.INACTIVE, m.state.value.condition)
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, m.state.value.cleanup.remote)
        assertEquals(1, count(r, "/devices/$deviceA"))
        assertEquals("", m.state.value.draft.password)
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun `account change holds files until confirmed selected inclusion and reauth keeps holds`() = runTest(dispatcher) {
        val r = rig()
        put(libraryDir.resolve("first.md"), "---\ntitle: First\n---\nfirst".encodeToByteArray())
        put(libraryDir.resolve("second.md"), "---\ntitle: Second\n---\nsecond".encodeToByteArray())
        r.login()
        r.userID = userB
        val m = model(r)
        credentials(m); m.signIn(); runCurrent()
        assertNull(m.state.value.failure)
        assertEquals(AccountCondition.ACTIVE, m.state.value.condition)
        assertEquals(2, m.state.value.holds.size)
        m.setPassword(password); m.signIn(); runCurrent()
        assertEquals(2, m.state.value.holds.size)
        val selected = m.state.value.holds.first()
        m.selectHold(selected.identity)
        m.includeSelected(); runCurrent()
        assertEquals(2, m.state.value.holds.size)
        m.requestInclude(); m.includeSelected(); m.includeSelected(); runCurrent()
        assertEquals(1, m.state.value.holds.size)
        assertTrue(m.state.value.holds.none { it.identity == selected.identity })
        assertTrue(m.state.value.selectedHolds.isEmpty())
        assertTrue(m.state.value.account.enabled)
        assertNull(m.state.value.failure)
    }

    @Test fun `foreground entry is paired on hide and passive model observation never runs a pass`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        runCurrent()
        assertEquals(0, count(r, "/sync/pull"))
        m.setForeground(SyncForegroundOwner.LIBRARY)
        m.setForeground(SyncForegroundOwner.LIBRARY)
        runCurrent()
        assertTrue(count(r, "/sync/pull") <= 1)
        val meBeforeHop = count(r, "/me")
        m.setForeground(SyncForegroundOwner.ACCOUNT); runCurrent()
        assertEquals(meBeforeHop, count(r, "/me"))
        m.setPassword(password)
        m.setForeground(null); runCurrent()
        assertEquals("", m.state.value.draft.password)
        val before = r.requests.size
        advanceTimeBy(61_000); runCurrent()
        assertEquals(before, r.requests.size)
    }

    @Test fun `quick foreground return while refresh cancellation drains still resumes polling`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        runCurrent()
        val entered = CompletableDeferred<Unit>()
        r.handler = { if (it.url.endsWith("/me")) { entered.complete(Unit); awaitCancellation() } else null }
        m.setForeground(SyncForegroundOwner.LIBRARY); runCurrent(); entered.await()
        m.setForeground(null)
        r.handler = null
        m.setForeground(SyncForegroundOwner.LIBRARY)
        runCurrent()
        assertNull(m.state.value.busy)
        val before = count(r, "/sync/pull")
        advanceTimeBy(61_000); runCurrent()
        assertTrue(count(r, "/sync/pull") > before)
        m.setForeground(null); runCurrent()
    }

    @Test fun `failed entry refresh retains foreground polling for an authenticated session`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        runCurrent()
        r.handler = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
        m.setForeground(SyncForegroundOwner.LIBRARY); runCurrent()
        assertEquals(AccountCondition.OFFLINE, m.state.value.condition)
        assertEquals(2, count(r, "/me"))
        r.handler = null
        val before = count(r, "/sync/pull")
        advanceTimeBy(61_000); runCurrent()
        assertTrue(count(r, "/sync/pull") > before)
        m.setForeground(null); runCurrent()
    }

    @Test fun `a worker restoring authentication also restores the visible foreground lease`() = runTest(dispatcher) {
        val first = rig()
        first.login(); first.close()
        val r = rig()
        r.secrets.values.putAll(first.secrets.values)
        val m = model(r)
        r.handler = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
        m.setForeground(SyncForegroundOwner.LIBRARY); runCurrent()
        assertEquals(1, count(r, "/me"))
        r.handler = null
        r.sync.resume(); runCurrent()
        val before = count(r, "/sync/pull")
        advanceTimeBy(61_000); runCurrent()
        assertTrue(count(r, "/sync/pull") > before)
        m.setForeground(null); runCurrent()
    }

    @Test fun `hiding during candidate verification compensates the remote session and preserves newer edits`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        val entered = CompletableDeferred<Unit>()
        r.handler = { if (it.url.endsWith("/me")) { entered.complete(Unit); awaitCancellation() } else null }
        credentials(m)
        m.signIn(); runCurrent(); entered.await()
        m.setUsername("newperson")
        m.setDeviceName("New device")
        m.setPassword("new synthetic secret")
        m.hide(); runCurrent()
        assertNull(m.state.value.busy)
        assertEquals("", m.state.value.draft.password)
        assertEquals("newperson", m.state.value.draft.username)
        assertEquals("New device", m.state.value.draft.deviceName)
        assertNull(m.state.value.account.account)
        assertTrue(r.secrets.values.isEmpty())
        assertEquals(1, count(r, "/auth/logout"))
    }

    @Test fun `401 footer stops sync now until reauthentication and does not duplicate a tap`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        runCurrent()
        r.handler = { if (it.url.endsWith("/sync/pull")) HttpResponse(401,
            body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.UNAUTHORIZED))) else null }
        m.syncNow(); m.syncNow(); runCurrent()
        assertEquals(1, count(r, "/sync/pull"))
        assertEquals(AccountCondition.NEEDS_SIGN_IN, m.state.value.condition)
        assertEquals(R.string.sync_needs_sign_in, m.state.value.sync.title)
        m.syncNow(); runCurrent()
        assertEquals(1, count(r, "/sync/pull"))
        credentials(m); r.handler = null
        m.signIn(); runCurrent()
        assertEquals(AccountCondition.ACTIVE, m.state.value.condition)
        assertTrue(m.state.value.canSync)
    }

    private fun route(m: AccountViewModel, data: String?, action: String? = Intent.ACTION_VIEW, restored: Boolean = false) {
        InviteIntentDecoder.decode(action, data, restored)?.withValue { m.stageInvite(it) }
    }

    @Test fun `cold and repeated warm view snapshots stage destination without automatically redeeming`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        for (delivery in 1..3) {
            route(m, inviteLink)
            runCurrent()
            assertEquals(server, m.state.value.invite?.serverURL)
            assertNull(m.state.value.invite?.currentAccount)
            assertTrue(m.state.value.inviteReady)
            assertFalse(m.state.value.canAcceptInvite)
            assertEquals(InviteAcceptance.EXISTING_ACCOUNT, m.state.value.inviteMode)
        }
        assertTrue(r.requests.isEmpty())
        assertEquals(0, r.secrets.reads)
        assertEquals("", m.state.value.inviteDraft)
    }

    @Test fun `warm route shows bound account and server and repeated Accept sends one join`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        assertEquals("person", m.state.value.invite?.currentAccount?.username)
        assertEquals(server, m.state.value.invite?.currentAccount?.identity?.serverURL)
        assertEquals(server, m.state.value.invite?.serverURL)
        assertTrue(m.state.value.canAcceptInvite)
        assertEquals(0, count(r, "/groups/join"))
        m.acceptInvite(); m.acceptInvite()
        assertFalse(m.state.value.inviteReady)
        runCurrent()
        assertEquals(1, count(r, "/groups/join"))
        assertEquals(0, count(r, "/auth/register"))
        assertEquals(R.string.invite_accepted, m.state.value.inviteMessage)
        assertEquals(r.memberships, m.state.value.account.me?.groups)
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/groups/join"))
    }

    @Test fun `cold persisted account is verified before presenting the acceptance account`() = runTest(dispatcher) {
        val first = rig()
        first.login(); first.close()
        val r = rig()
        r.secrets.values.putAll(first.secrets.values)
        val m = model(r)
        route(m, inviteLink); runCurrent()
        assertEquals("person", m.state.value.invite?.currentAccount?.username)
        assertTrue(m.state.value.canAcceptInvite)
        assertEquals(1, count(r, "/me"))
        assertEquals(0, count(r, "/groups/join"))
        assertEquals(0, count(r, "/auth/register"))
    }

    @Test fun `malformed view snapshots discard prior invite and never redeem`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        val malformed = listOf(null, "", "https://example.test/", "monkeyspaw://join/?server=https%3A%2F%2Fexample.test&token=$inviteToken",
            "$inviteLink&token=$inviteToken", "$inviteLink&extra=1", "$inviteLink#fragment",
            inviteLink.replace(inviteToken, "%2541".repeat(43)), inviteLink.replace("%2Fpaw", "%2F..%2Fpaw"))
        for (link in malformed) {
            route(m, inviteLink); runCurrent()
            route(m, link); runCurrent()
            assertFalse(m.state.value.inviteReady)
            assertNull(m.state.value.invite)
            assertEquals(R.string.invite_invalid, m.state.value.inviteMessage)
        }
        m.setServer(server)
        route(m, inviteToken); runCurrent()
        assertFalse(m.state.value.inviteReady)
        assertEquals(R.string.invite_invalid, m.state.value.inviteMessage)
        assertTrue(r.requests.isEmpty())
        assertTrue(r.secrets.values.isEmpty())
    }

    @Test fun `only view data is admitted and restored launch snapshots never replay`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        for (action in listOf(null, Intent.ACTION_MAIN, Intent.ACTION_SEND, Intent.ACTION_PROCESS_TEXT))
            route(m, inviteLink, action)
        route(m, inviteLink, restored = true)
        runCurrent()
        assertNull(m.state.value.invite)
        assertNull(m.state.value.busy)
        assertTrue(r.requests.isEmpty())
        val secret = InviteIntentDecoder.decode(Intent.ACTION_VIEW, inviteLink)!!
        assertFalse(secret.toString().contains(inviteToken))
    }

    @Test fun `different server blocks current credentials until explicit sign in and reopening`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        val other = "https://other.test/team"
        route(m, "monkeyspaw://join?server=https%3A%2F%2Fother.test%2Fteam&token=$inviteToken"); runCurrent()
        assertEquals(other, m.state.value.invite?.serverURL)
        assertEquals(server, m.state.value.invite?.currentAccount?.identity?.serverURL)
        assertFalse(m.state.value.canAcceptInvite)
        assertEquals(other, m.state.value.server?.baseURL)
        val requests = r.requests.size
        val reads = r.secrets.reads
        m.acceptInvite(); runCurrent()
        assertEquals(requests, r.requests.size)
        assertEquals(reads, r.secrets.reads)
        credentials(m, other); m.signIn(); runCurrent()
        assertEquals(R.string.invite_account_changed, m.state.value.inviteMessage)
        assertNull(m.state.value.invite)
        val login = r.requests.single { it.url.startsWith(other) && it.url.endsWith("/auth/login") }
        assertFalse(login.headers.keys.any { it.equals("Authorization", true) })
        assertEquals(0, count(r, "/groups/join"))
        route(m, "monkeyspaw://join?server=https%3A%2F%2Fother.test%2Fteam&token=$inviteToken"); runCurrent()
        assertTrue(m.state.value.canAcceptInvite)
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/groups/join"))
        assertTrue(r.requests.filter { it.url.endsWith("/groups/join") }.all { it.url.startsWith(other + "/api/v1/") })
    }

    @Test fun `cancel hide and process loss discard invite and password without redemption`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        m.setPassword(password)
        m.cancel(); runCurrent()
        assertNull(m.state.value.invite)
        assertEquals("", m.state.value.inviteDraft)
        assertEquals("", m.state.value.draft.password)
        m.acceptInvite(); runCurrent()
        route(m, inviteLink); m.hide(); runCurrent()
        assertNull(m.state.value.invite)
        val fresh = model(r)
        route(fresh, inviteLink, restored = true); runCurrent()
        assertNull(fresh.state.value.invite)
        assertTrue(r.requests.isEmpty())
    }

    @Test fun `new account requires an explicit mode and Accept and keeps successful scheduling hook`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        credentials(m)
        assertFalse(m.state.value.canAcceptInvite)
        m.acceptInvite(); runCurrent()
        assertTrue(r.requests.isEmpty())
        m.setInviteMode(InviteAcceptance.NEW_ACCOUNT)
        assertEquals("", m.state.value.draft.password)
        m.setPassword(password)
        assertTrue(m.state.value.canAcceptInvite)
        assertEquals("person", m.state.value.draft.username)
        assertEquals(server, m.state.value.invite?.serverURL)
        assertTrue(r.requests.isEmpty())
        m.acceptInvite(); m.acceptInvite()
        assertEquals("", m.state.value.draft.password)
        runCurrent()
        assertEquals(1, count(r, "/auth/register"))
        assertEquals(0, count(r, "/groups/join"))
        assertEquals(AccountCondition.ACTIVE, m.state.value.condition)
        assertEquals(R.string.invite_accepted, m.state.value.inviteMessage)
        val request = r.requests.single { it.url.endsWith("/auth/register") }
        assertFalse(request.headers.keys.any { it.equals("Authorization", true) })
        val registration = RegisterRequest.codec.decode(request.body!!)
        assertTrue(registration.inviteToken == inviteToken)
        assertTrue(registration.password == password)
        assertTrue(r.enqueued.isNotEmpty())
        assertFalse(r.scheduler.authenticationStopped())
        val disk = Files.walk(filesDir).use { paths -> paths.filter { Files.isRegularFile(it) }.map { Files.readString(it) }.toList().joinToString() }
        assertFalse(disk.contains(inviteToken))
        assertFalse(disk.contains(password))
        assertFalse(m.state.value.toString().contains(inviteToken))
        assertFalse(m.state.value.invite.toString().contains(inviteToken))
    }

    @Test fun `bare token needs explicitly selected server and HTTP destination warns`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        m.setInviteDraft(inviteToken); m.stageInvite(); runCurrent()
        assertEquals(R.string.invite_server_required, m.state.value.inviteMessage)
        assertEquals("", m.state.value.inviteDraft)
        m.setServer("http://192.168.1.2/paw")
        m.setInviteDraft(inviteToken); m.stageInvite(); runCurrent()
        assertEquals("http://192.168.1.2/paw", m.state.value.invite?.serverURL)
        assertTrue(m.state.value.invite?.usesHTTP == true)
        assertTrue(r.requests.isEmpty())
    }

    @Test fun `new account on another server registers anonymously and activates only its returned credential`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        val other = "https://other.test/team"
        route(m, "monkeyspaw://join?server=https%3A%2F%2Fother.test%2Fteam&token=$inviteToken"); runCurrent()
        assertEquals(server, m.state.value.invite?.currentAccount?.identity?.serverURL)
        m.setInviteMode(InviteAcceptance.NEW_ACCOUNT)
        credentials(m, other)
        r.userID = userB
        m.acceptInvite(); runCurrent()
        assertEquals(R.string.invite_accepted, m.state.value.inviteMessage)
        assertEquals(other, m.state.value.account.account?.identity?.serverURL)
        assertEquals(ULID.parse(userB), m.state.value.account.account?.identity?.userID)
        assertEquals(1, count(r, "/auth/register"))
        val foreign = r.requests.filter { it.url.startsWith(other) }
        assertTrue(foreign.isNotEmpty())
        assertTrue(foreign.filter { it.url.endsWith("/auth/register") }.all {
            it.headers.keys.none { name -> name.equals("Authorization", true) }
        })
        assertTrue(foreign.none { request -> request.headers.values.any { it.contains("A".repeat(43)) } })
        assertEquals(0, count(r, "/groups/join"))
    }

    @Test fun `rapid warm snapshots keep only the newest staged destination`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        route(m, inviteLink)
        route(m, "monkeyspaw://join?server=https%3A%2F%2Fother.test%2Fteam&token=$inviteToken")
        runCurrent()
        assertEquals("https://other.test/team", m.state.value.invite?.serverURL)
        assertTrue(m.state.value.inviteReady)
        assertTrue(r.requests.isEmpty())
    }

    @Test fun `accepted join with refresh failure reports commitment and never retries on refresh`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        r.handler = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
        m.acceptInvite(); runCurrent()
        assertEquals(R.string.invite_refresh_incomplete, m.state.value.inviteMessage)
        assertNull(m.state.value.account.me)
        assertFalse(m.state.value.inviteReady)
        r.handler = null
        m.refresh(); runCurrent()
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/groups/join"))
        assertNotNull(m.state.value.account.me)
    }

    @Test fun `failure to load local account details after a committed invite preserves accepted status`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        r.handler = { if (it.url.endsWith("/groups/join")) r.failSettingsRead = true; null }
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/groups/join"))
        assertTrue(m.state.value.inviteMessage in setOf(R.string.invite_accepted, R.string.invite_refresh_incomplete))
        assertFalse(m.state.value.inviteReady)
        assertNotNull(m.state.value.failure)
    }

    @Test fun `scheduling failure after committed registration still reports account created`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        m.setInviteMode(InviteAcceptance.NEW_ACCOUNT)
        credentials(m)
        r.failAuthenticationScheduling = true
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/auth/register"))
        assertEquals(R.string.invite_registration_incomplete, m.state.value.inviteMessage)
        assertFalse(m.state.value.inviteReady)
        assertEquals("", m.state.value.draft.password)
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/auth/register"))
        r.failAuthenticationScheduling = false
        credentials(m); m.signIn(); runCurrent()
        assertEquals(1, count(r, "/auth/login"))
        assertEquals(1, count(r, "/auth/register"))
    }

    @Test fun `unavailable invite is consumed and fixed messages never contain server response secrets`() = runTest(dispatcher) {
        val r = rig()
        r.login()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        r.handler = { if (it.url.endsWith("/groups/join")) HttpResponse(400,
            body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.MALFORMED_REQUEST))) else null }
        m.acceptInvite(); runCurrent()
        assertEquals(R.string.invite_unavailable, m.state.value.inviteMessage)
        assertFalse(m.state.value.inviteReady)
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/groups/join"))
    }

    @Test fun `remote registration with failed local activation offers sign in without repeat redemption`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        put(libraryDir.resolve("Groups/keep.md"), "preserve".encodeToByteArray())
        m.setInviteMode(InviteAcceptance.NEW_ACCOUNT)
        credentials(m)
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/auth/register"))
        assertEquals(R.string.invite_registration_incomplete, m.state.value.inviteMessage)
        assertFalse(m.state.value.inviteReady)
        assertEquals("", m.state.value.draft.password)
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/auth/register"))
        Files.delete(libraryDir.resolve("Groups/keep.md"))
        Files.delete(libraryDir.resolve("Groups"))
        credentials(m); m.signIn(); runCurrent()
        assertEquals(1, count(r, "/auth/login"))
        assertEquals(1, count(r, "/auth/register"))
        assertEquals(AccountCondition.ACTIVE, m.state.value.condition)
    }

    @Test fun `cancelling registration during verification drops secret drafts and fences a late result`() = runTest(dispatcher) {
        val r = rig()
        val m = model(r)
        route(m, inviteLink); runCurrent()
        m.setInviteMode(InviteAcceptance.NEW_ACCOUNT)
        credentials(m)
        val entered = CompletableDeferred<Unit>()
        r.handler = { if (it.url.endsWith("/me")) { entered.complete(Unit); awaitCancellation() } else null }
        m.acceptInvite(); runCurrent(); entered.await()
        m.setPassword("new synthetic secret")
        m.hide(); runCurrent()
        assertNull(m.state.value.invite)
        assertNull(m.state.value.inviteMessage)
        assertEquals("", m.state.value.draft.password)
        assertTrue(r.secrets.values.isEmpty())
        assertEquals(1, count(r, "/auth/register"))
        assertEquals(1, count(r, "/auth/logout"))
        m.acceptInvite(); runCurrent()
        assertEquals(1, count(r, "/auth/register"))
    }

    private companion object {
        const val server = "https://example.test/paw"
        const val time = "2026-10-15T00:00:00.000Z"
        const val password = "Synthetic-password-123"
        const val userA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        const val userB = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        const val deviceA = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
        const val deviceB = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        const val databaseID = "11111111-1111-4111-8111-111111111111"
        val inviteToken = "B".repeat(42) + "A"
        val inviteLink = "monkeyspaw://join?server=https%3A%2F%2Fexample.test%2Fpaw&token=$inviteToken"
    }
}
