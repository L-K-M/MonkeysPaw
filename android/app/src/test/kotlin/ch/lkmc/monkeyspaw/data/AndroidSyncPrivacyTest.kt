@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.DataStoreFactory
import androidx.lifecycle.ViewModelStore
import androidx.work.Data
import androidx.work.ListenableWorker.Result
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.di.AppModule
import ch.lkmc.monkeyspaw.ui.account.AccountViewModel
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.net.URLEncoder
import java.nio.file.Files
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.logging.Handler
import java.util.logging.Level
import java.util.logging.LogRecord
import java.util.logging.Logger
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlin.test.*

/** Real app composition and DataStores; JVM AES-GCM is not AndroidKeyStore or device logcat proof. */
internal class AndroidSyncPrivacyTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val rigs = mutableListOf<Rig>()
    private val sentinels = mutableListOf<String>()
    private val descriptions = mutableListOf<String>()
    private val jobs = mutableListOf<Data>()
    private val requests = mutableListOf<SyncWorkRequest>()
    private val periodic = mutableSetOf<String>()
    private val keys = object : SecretKeyProvider {
        private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        override fun read(): SecretKey = key
        override fun create(): SecretKey = error("Reuse the test alias")
        override fun replace(): SecretKey = error("No alias recovery is expected")
    }
    private val password = secret(UUID.randomUUID().toString() + "\"\\/%+雪😀")
    private val tokens = List(3) { token() }
    private val inviteToken = token()
    private val providerKey = secret(UUID.randomUUID().toString() + "\"\\/%+雪😀")
    private val otherToken = token()
    private val otherDevice = SecretAccount.device(UUID.randomUUID())
    private val provider = ProviderDraft(key = ProviderKeyEdit.Replace(SecretValue(providerKey)))
    private var logins = 0
    private var logouts = 0
    private var joins = 0
    private var pulls = 0
    private var currentUser = userA
    private var currentToken = tokens.first()

    @BeforeTest fun main() { Dispatchers.setMain(dispatcher) }

    @AfterTest fun close() = runBlocking {
        models.clear()
        dispatcher.scheduler.runCurrent()
        for (rig in rigs) rig.close()
        Dispatchers.resetMain()
    }

    private inner class Rig {
        // Serialize publication and audit walks; an observer may still be writing after UI state settles.
        val io = Dispatchers.IO.limitedParallelism(1)
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val persistence = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val settings = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = persistence,
            produceFile = { filesDir.resolve("datastore/settings.json").toFile() }))
        val secretData = DataStoreFactory.create(serializer = SecretsSerializer, scope = persistence,
            produceFile = { filesDir.resolve("datastore/secrets.json").toFile() })
        val secrets = AndroidKeystoreSecretStore(secretData, keys, io)
        private val auditedSecrets = object : SecretStore by secrets {
            override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
                // Include the whole bound envelope so encoded/nested copies are detected too.
                sentinels.add(value.withValue { it })
                return secrets.write(value, account)
            }
        }
        private val checked = JvmCheckedSyncIO()
        val prompts = AndroidPromptStore(libraryDir.toFile(), io = checked)
        val files = AndroidStateStore(stateDir.toFile(), settings = settings, isMainThread = { false }, io = checked)
        private val library = library(files, prompts)
        private val startup = AndroidSyncStartup(library, prompts, files, libraryDir.toFile().absolutePath, io)
        private val local = LibraryRepository(library, EditingService(library), prompts, io) { startup.ready() }
        val work = SyncWorkStateStore(files, files.syncOperations)
        val scheduler: SyncWorkScheduler by lazy {
            SyncWorkScheduler(SyncWorkPolicy(work, object : SyncWorkQueue {
                override suspend fun periodic(generation: String, intervalMillis: Long) {
                    assertEquals(900_000L, intervalMillis)
                    periodic.add(generation)
                    capture(SyncWorkRequest(generation))
                }
                override suspend fun once(request: SyncWorkRequest) { requests.add(request); capture(request) }
                override suspend fun cancel(generation: String) { periodic.remove(generation) }
            }, AndroidSyncWorkSession(startup, Lazy { sync }), { Instant.parse(time).toEpochMilli() }, 31), io)
        }
        // Real disk IO must use real cleanup deadlines rather than auto-advanced virtual time.
        val sync = AppModule.syncRepository(startup, library, local, scope, io, Clock { Instant.parse(time) },
            Entropy { count -> ByteArray(count).also(SecureRandom()::nextBytes) }, MonotonicClock(System::nanoTime),
            Lazy { auditedSecrets }, Lazy { HttpTransport(::respond) },
            Lazy { ProviderSettingsService(ProviderSettingsStore(files), auditedSecrets, io) },
            Lazy { ProviderSyncKeyService(auditedSecrets, Entropy { count -> ByteArray(count) }) },
            settings, AppModule.syncWorkHooks(Lazy { scheduler }))

        suspend fun close() {
            scope.coroutineContext.job.cancelAndJoin()
            persistence.coroutineContext.job.cancelAndJoin()
        }
    }

    @Test fun `account lifecycle leaves only ciphertext and preserves unrelated credentials`() = runTest(dispatcher) {
        val diagnostics = ByteArrayOutputStream()
        val stdout = System.out
        val stderr = System.err
        val sink = PrintStream(diagnostics, true, "UTF-8")
        val logger = Logger.getLogger("")
        val handlers = logger.handlers
        val level = logger.level
        val capture = object : Handler() {
            override fun publish(record: LogRecord) {
                sink.println(record.message)
                record.parameters?.forEach { sink.println(it) }
                record.thrown?.printStackTrace(sink)
            }
            override fun flush() = sink.flush()
            override fun close() = Unit
        }.apply { this.level = Level.ALL }
        handlers.forEach(logger::removeHandler)
        logger.addHandler(capture)
        logger.level = Level.ALL
        System.setOut(sink)
        System.setErr(sink)
        try {
            println("stdout capture ready")
            System.err.println("stderr capture ready")
            logger.fine("logging capture ready")
            assertTrue(listOf("stdout", "stderr", "logging").all { "$it capture ready" in diagnostics.toString("UTF-8") })
            var rig = Rig().also(rigs::add)
            // Provider metadata uses the real settings DataStore, on a worker as required by its synchronous port.
            suspend fun providerService() = withContext(Dispatchers.IO) {
                ProviderSettingsService(ProviderSettingsStore(rig.files), rig.secrets, Dispatchers.IO)
            }
            providerService().save(provider)
            sentinels.add(rig.secrets.read(SecretAccount.provider(provider.id), SecretReadSource.PERSISTED)!!.value.withValue { it })
            rig.secrets.write(SecretValue(otherToken), otherDevice)
            val unrelated = rig.secretData.data.first().entries
            val baseline = unrelated.keys
            var model = model(rig)

            suspend fun worker(input: Data, scheduler: Lazy<SyncWorkScheduler> = Lazy { rig.scheduler }): Result {
                val result = try { syncWorkerResult(input, scheduler) }
                catch (error: CancellationException) { throw error }
                catch (_: Exception) { fail("Worker must return a result without throwing diagnostics") }
                jobs.add(when (result) {
                    is Result.Success -> result.outputData
                    is Result.Failure -> result.outputData
                    else -> fail("Worker must return success or failure without a retry result")
                })
                return result
            }

            suspend fun checkpoint(label: String, expected: Set<String>) = withContext(rig.io) {
                val ui = model.state.value
                assertNull(ui.busy, "Account operation must settle before scanning")
                assertTrue(ui.draft.password.isEmpty() && ui.inviteDraft.isEmpty(), "Transient secret input must be cleared")
                val state = listOf(ui.toString(), ui.draft.toString(), ui.draft.server, ui.draft.username, ui.draft.deviceName,
                    ui.draft.password, ui.inviteDraft, ui.invite.toString(), ui.invite?.serverURL.orEmpty(),
                    ui.account.toString(), ui.account.account?.toString().orEmpty(), ui.cleanup.toString(), ui.sync.toString(),
                    rig.sync.reports.value.toString(), rig.sync.scheduling.value.toString(), rig.work.read().toString(),
                    rig.settings.read().toString()).joinToString("\n").encodeToByteArray()
                val scanner = SecretScan(sentinels)
                assertFalse(scanner.contains(state), "$label: secret in non-secret account/scheduler state")
                ui.account.me?.let { assertFalse(scanner.contains(MeResponse.codec.encode(it)), "$label: secret in account details") }
                assertFalse(scanner.contains(descriptions.joinToString("\n").encodeToByteArray()), "$label: secret in descriptions")
                for (job in jobs) {
                    assertTrue(job.keyValueMap.keys.all { it in setOf(AndroidSyncWorkQueue.GENERATION, AndroidSyncWorkQueue.VERSION) },
                        "Jobs contain only generation and optional version")
                    assertFalse(scanner.contains(job.toByteArray()), "$label: secret in job input/output Data")
                    assertFalse(scanner.contains(job.keyValueMap.toString().encodeToByteArray()), "$label: secret in job values")
                }
                assertFalse(scanner.contains(diagnostics.toByteArray()), "$label: secret in stdout/stderr/logging")
                put(temporary.resolve(".logs/.cache/diagnostics.bin"), diagnostics.toByteArray())
                put(temporary.resolve("cache/job-data.bin"), jobs.flatMap { it.toByteArray().toList() }.toByteArray())
                put(temporary.resolve(".temp/account-state.bin"), state)
                assertTrue(scanner.matches(temporary).isEmpty(), "$label: secret in app/DataStore/cache/temp files")
                assertEquals(expected, rig.secretData.data.first().entries.keys, "Only expected ciphertext accounts persist")
                for ((account, record) in unrelated) assertEquals(record, rig.secretData.data.first().entries[account],
                    "Unrelated ciphertext must remain unchanged")
                assertTrue(providerService().connection(provider.id).key == SecretValue(providerKey), "Provider credential remains readable")
                assertTrue(rig.secrets.read(otherDevice, SecretReadSource.PERSISTED)?.value == SecretValue(otherToken),
                    "Other device credential remains readable")
            }

            checkpoint("baseline", baseline)
            // Reserved user content refuses activation after the candidate token was encrypted and staged.
            put(libraryDir.resolve("Groups/keep.md"))
            signIn(model, "first")
            model.state.first { it.busy == null }
            assertEquals(R.string.account_reserved_folders, model.state.value.failure)
            assertTrue(model.state.value.cleanup.isComplete)
            assertFalse(model.state.value.account.enabled)
            assertEquals(1, logouts, "Failed activation revokes the unused session")
            assertEquals(1, sentinels.count { it.contains("\"connection_id\"") }, "The failed candidate reached encrypted storage")
            checkpoint("failed activation and cleanup", baseline)
            Files.delete(libraryDir.resolve("Groups/keep.md"))
            Files.delete(libraryDir.resolve("Groups"))

            signIn(model, "first")
            model.state.first { it.busy == null }
            assertNull(model.state.value.failure)
            assertTrue(model.state.value.account.enabled)
            val firstAccount = assertNotNull(model.state.value.account.account)
            val oldWork = requests.last()
            checkpoint("login", baseline + firstAccount.secretAccount.rawValue)

            // Process-style reconstruction: no live model, graph, DataStore or scheduler instance is reused.
            models.clear()
            runCurrent()
            rig.close()
            rig = Rig().also(rigs::add)
            model = model(rig)
            checkpoint("reopened DataStores before resume", baseline + firstAccount.secretAccount.rawValue)
            assertTrue(model.state.value.draft.password.isEmpty() && model.state.value.invite == null)
            model.refresh()
            model.state.first { it.busy == null }
            assertEquals(firstAccount, model.state.value.account.account)
            assertTrue(model.state.value.account.enabled)
            assertTrue(worker(AndroidSyncWorkQueue.input(oldWork)) is Result.Success, "Valid work returns success")
            assertTrue(worker(AndroidSyncWorkQueue.input(oldWork.copy(version = null))) is Result.Success,
                "Periodic work without a version returns success")
            val invalidInputs = listOf(Data.EMPTY,
                Data.Builder().putString(AndroidSyncWorkQueue.GENERATION, "invalid-generation").build(),
                Data.Builder().putString(AndroidSyncWorkQueue.GENERATION, "1-1-1-1-1").build(),
                AndroidSyncWorkQueue.input(oldWork.copy(version = 0)),
                AndroidSyncWorkQueue.input(oldWork.copy(version = -1)))
            for (input in invalidInputs) {
                assertTrue(worker(input, Lazy { fail("Invalid input must not resolve the scheduler") }) is Result.Failure,
                    "Invalid input returns failure")
            }
            val input = AndroidSyncWorkQueue.input(oldWork)
            assertTrue(worker(input, Lazy { throw IllegalStateException(tokens.first()) }) is Result.Failure,
                "Dispatch failure returns failure without retaining exception diagnostics")
            assertFailsWith<CancellationException> { worker(input, Lazy { throw CancellationException() }) }
            assertEquals(1, pulls, "Reconstructed work runs through the shared production engine")
            checkpoint("reconstructed account and worker", baseline + firstAccount.secretAccount.rawValue)

            signIn(model, "second")
            model.state.first { it.busy == null }
            assertNull(model.state.value.failure)
            val secondAccount = assertNotNull(model.state.value.account.account)
            assertNotEquals(firstAccount.identity, secondAccount.identity)
            assertNull(rig.secrets.read(firstAccount.secretAccount, SecretReadSource.PERSISTED))
            checkpoint("account switch", baseline + secondAccount.secretAccount.rawValue)

            val link = secret("monkeyspaw://join?server=${URLEncoder.encode(server, "UTF-8")}&token=$inviteToken")
            model.setInviteDraft(link)
            model.stageInvite()
            model.state.first { it.busy == null }
            assertTrue(model.state.value.inviteReady)
            assertEquals(0, joins, "Staging requires explicit consent before redemption")
            checkpoint("invite staged", baseline + secondAccount.secretAccount.rawValue)
            model.setPassword(password)
            model.cancel()
            runCurrent()
            assertNull(model.state.value.invite)
            model.acceptInvite()
            assertEquals(0, joins)
            checkpoint("invite cancellation and clearing", baseline + secondAccount.secretAccount.rawValue)
            model.stageInvite(link)
            model.state.first { it.busy == null }
            model.acceptInvite()
            model.state.first { it.busy == null }
            assertEquals(1, joins)
            assertFalse(model.state.value.inviteReady)
            assertEquals(R.string.invite_accepted, model.state.value.inviteMessage)
            checkpoint("explicit invite acceptance and clearing", baseline + secondAccount.secretAccount.rawValue)

            model.requestSignOut()
            model.signOut()
            model.state.first { it.busy == null }
            assertTrue(model.state.value.cleanup.isComplete)
            assertNull(model.state.value.account.account)
            assertNull(rig.work.read().connection)
            assertTrue(periodic.isEmpty())
            val before = pulls
            for (request in requests.toList()) {
                assertTrue(worker(AndroidSyncWorkQueue.input(request)) is Result.Success, "Stale work completes without HTTP")
            }
            assertEquals(before, pulls, "Old jobs are inert after sign-out")
            checkpoint("sign-out and stale jobs", baseline)

            models.clear()
            runCurrent()
            rig.close()
            rig = Rig().also(rigs::add)
            model = model(rig)
            model.refresh()
            model.state.first { it.busy == null }
            assertFalse(model.state.value.account.enabled)
            assertNull(model.state.value.account.account)
            assertNull(model.state.value.invite)
            assertEquals(before, pulls)
            checkpoint("signed-out reconstruction", baseline)
        } finally {
            models.clear()
            runCurrent()
            for (rig in rigs) rig.close()
            System.setOut(stdout)
            System.setErr(stderr)
            logger.removeHandler(capture)
            handlers.forEach(logger::addHandler)
            logger.level = level
            sink.close()
            // Never replay captured diagnostics, even when an assertion fails.
        }
    }

    private fun model(rig: Rig) = AccountViewModel(rig.sync, rig.scheduler).also { models.put(UUID.randomUUID().toString(), it) }

    private fun signIn(model: AccountViewModel, username: String) {
        model.setServer(server)
        model.setUsername(username)
        model.setPassword(password)
        model.signIn()
        assertTrue(model.state.value.draft.password.isEmpty(), "Sign-in clears the password before awaiting")
    }

    private fun capture(request: SyncWorkRequest) {
        descriptions.add(request.toString())
        jobs.add(AndroidSyncWorkQueue.input(request))
    }

    private fun respond(request: HttpRequest): HttpResponse {
        descriptions.add(request.toString())
        val response = when {
            request.url.endsWith("/auth/login") -> {
                sentinels.add(request.body!!.decodeToString())
                val login = LoginRequest.codec.decode(request.body!!)
                assertTrue(login.password == password, "Only the submitted password reaches authentication")
                currentUser = if (login.username == "first") userA else userB
                currentToken = tokens[logins++]
                HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse(currentToken, user())))
            }
            request.url.endsWith("/me") -> {
                assertTrue(request.headers["Authorization"] == "Bearer $currentToken", "Only the bound device token reaches account refresh")
                HttpResponse(200, body = MeResponse.codec.encode(MeResponse(user(), emptyList(),
                    listOf(Device(device, "Android", time, null, null, true)))))
            }
            request.url.endsWith("/auth/logout") -> {
                logouts++
                HttpResponse(200, body = EmptyResponse.codec.encode(EmptyResponse))
            }
            request.url.endsWith("/sync/pull") -> {
                pulls++
                HttpResponse(200, body = PullResponse.codec.encode(PullResponse(database,
                    listOf(SyncScope(ScopeIdentity.User(currentUser), Mode.SNAPSHOT, 1, "u-1", false, emptyList())), emptyList())))
            }
            request.url.endsWith("/me/provider-settings") -> {
                // No sync key is provisioned; the step reports keyRequired after this GET.
                HttpResponse(200, body = ProviderSettingsDocument.codec.encode(
                    ProviderSettingsDocument(0, null, time)))
            }
            request.url.endsWith("/groups/join") -> {
                sentinels.add(request.body!!.decodeToString())
                assertTrue(JoinGroupRequest.codec.decode(request.body!!).inviteToken == inviteToken, "Only explicit acceptance redeems the staged invite")
                joins++
                HttpResponse(200, body = GroupMembership.codec.encode(GroupMembership(group, "Team", Role.VIEWER)))
            }
            else -> error("Unexpected synthetic request")
        }
        if (request.url.endsWith("/auth/login")) sentinels.add(response.body.decodeToString())
        descriptions.add(response.toString())
        return response
    }

    private fun user() = User(currentUser, if (currentUser == userA) "first" else "second", null, AccountKind.MEMBER, time, null)
    private fun secret(value: String) = value.also(sentinels::add)
    private fun token() = secret(Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also(SecureRandom()::nextBytes)))

    private companion object {
        const val server = "https://example.test/paw"
        const val userA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        const val userB = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        const val device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        const val group = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
        const val database = "11111111-1111-4111-8111-111111111111"
        const val time = "2026-10-18T00:00:00.000Z"
    }
}
