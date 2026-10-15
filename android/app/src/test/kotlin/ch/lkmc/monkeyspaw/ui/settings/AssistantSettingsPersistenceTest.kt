package ch.lkmc.monkeyspaw.ui.settings

import androidx.datastore.core.DataStoreFactory
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AnthropicClient
import ch.lkmc.monkeyspaw.core.llm.OpenAIClient
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import ch.lkmc.monkeyspaw.di.AppModule
import dagger.Lazy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.JsonPrimitive
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.net.URLEncoder
import java.nio.file.Files
import java.util.Base64
import java.util.UUID
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlin.test.*

/** Real DataStore/crypto composition with a JVM AES key. This does not test AndroidKeyStore hardware. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class AssistantSettingsPersistenceTest : TemporaryFiles() {
    private val scheduler = TestCoroutineScheduler()
    private val main = StandardTestDispatcher(scheduler)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val models = ViewModelStore()

    @BeforeTest fun setMain() { Dispatchers.setMain(main) }
    @AfterTest fun retire() { models.clear(); scope.cancel(); scheduler.runCurrent(); Dispatchers.resetMain() }

    @Test fun `save Test reconstruction rename switch and delete persist ciphertext only`() = runTest(scheduler) {
        val sentinel = UUID.randomUUID().toString() + "\"/雪"
        val owner = Thread.currentThread()
        val metadata = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
            produceFile = { filesDir.resolve("datastore/settings.json").toFile() }))
        val state = AndroidStateStore(stateDir.toFile(), settings = metadata, isMainThread = { Thread.currentThread() == owner })
        val keys = object : SecretKeyProvider {
            private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            override fun read(): SecretKey = key
            override fun create(): SecretKey = error("Existing test alias should be reused")
            override fun replace(): SecretKey = error("No recovery is expected")
        }
        val secrets = AndroidKeystoreSecretStore(DataStoreFactory.create(serializer = SecretsSerializer, scope = scope,
            produceFile = { filesDir.resolve("datastore/secrets.json").toFile() }), keys, Dispatchers.IO)
        var requests = 0
        var status = 200
        val transport = HttpTransport {
            requests++
            assertEquals(HttpMethod.GET, it.method)
            HttpResponse(status, emptyMap(), "{\"data\":[{\"id\":\"listed\"}]}".encodeToByteArray())
        }
        val clock = MonotonicClock(System::nanoTime)
        val changes = AppModule.providerChanges()
        var provider: ProviderSettingsService? = null
        fun newModel(): AssistantSettingsViewModel {
            val settings = kotlin.lazy {
                assertNotEquals(owner, Thread.currentThread(), "The graph must be constructed off UI")
                AppModule.providerSettings(AppModule.providerSettingsStore(state), secrets, Dispatchers.IO).also { provider = it }
            }
            val connection = kotlin.lazy {
                AssistantConnectionService(settings.value, AnthropicClient(transport, clock),
                    OpenAIClient(transport, ProviderStateStore(state), clock), Dispatchers.IO, main, clock)
            }
            return AssistantSettingsViewModel(Lazy { settings.value }, Lazy { connection.value }, Dispatchers.IO, scope, changes)
                .also { models.put(UUID.randomUUID().toString(), it); it.open() }
        }
        suspend fun settled(model: AssistantSettingsViewModel) = model.state.first {
            it.operation == null && it.keyStorage != AssistantKeyStorage.Loading
        }
        val diagnostics = ByteArrayOutputStream()
        val stdout = System.out
        val stderr = System.err
        val sink = PrintStream(diagnostics, true, "UTF-8")
        System.setOut(sink); System.setErr(sink)
        try {
            var model = newModel()
            settled(model)
            model.addProfile(ProviderKind.OPENAI_COMPATIBLE)
            model.setBaseURL("http://localhost:11434/v1")
            model.setModelID("manual")
            model.setKeyInput(sentinel)
            model.save()
            settled(model)
            val first = model.state.value.draft!!.id
            assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
            assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
            val credential = secrets.read(SecretAccount.provider(first), SecretReadSource.PERSISTED)!!.value.withValue { it }
            scan(sentinel, credential, diagnostics)
            model.testConnection()
            model.state.first { !it.isTesting }
            assertEquals(ConnectionTestResult.Ok(listOf(ModelDescriptor("listed"))), model.state.value.testResult)
            scan(sentinel, credential, diagnostics)
            status = 401
            model.testConnection()
            model.state.first { !it.isTesting }
            assertEquals(ConnectionTestResult.Authentication, model.state.value.testResult)
            scan(sentinel, credential, diagnostics)
            model.close()
            model = newModel()
            settled(model)
            assertEquals(first, model.state.value.selectedProfileID)
            scan(sentinel, credential, diagnostics)
            model.renameProfile("Renamed"); model.save(); settled(model)
            scan(sentinel, credential, diagnostics)
            model.addProfile(); model.save(); settled(model)
            val second = model.state.value.draft!!.id
            model.selectProfile(second); settled(model)
            model.selectProfile(first); settled(model)
            scan(sentinel, credential, diagnostics)
            model.deleteProfile(first); settled(model)
            assertNull(secrets.read(SecretAccount.provider(first), SecretReadSource.PERSISTED))
            assertEquals(1, model.state.value.profiles.size)
            assertEquals(second, model.state.value.profiles.single().id)
            assertEquals(2, requests, "Only the two explicit Test intents issue requests")
            assertNotNull(provider)
            scan(sentinel, credential, diagnostics)
            assertFalse(Files.exists(stateDir.resolve("provider-settings.json")))
            assertFalse(Files.exists(stateDir.resolve("provider-state.json")))
        } finally {
            System.setOut(stdout); System.setErr(stderr); sink.close()
            models.clear()
            scope.coroutineContext[Job]!!.cancelAndJoin()
        }
    }

    private fun scan(sentinel: String, credential: String, diagnostics: ByteArrayOutputStream) {
        val variants = listOf(sentinel, credential).flatMap {
            listOf(it, Base64.getEncoder().encodeToString(it.encodeToByteArray()), URLEncoder.encode(it, "UTF-8"),
                JsonPrimitive(it).toString().removeSurrounding("\""))
        }
        val outputs = Files.walk(temporary).use { files ->
            files.filter(Files::isRegularFile).map { Files.readAllBytes(it).decodeToString() }.toList()
        } + diagnostics.toString("UTF-8")
        assertTrue(outputs.all { output -> variants.none { it in output } }, "Secret escaped encrypted storage")
    }
}
