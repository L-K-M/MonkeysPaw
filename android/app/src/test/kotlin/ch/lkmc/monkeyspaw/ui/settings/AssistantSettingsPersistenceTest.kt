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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Dispatcher
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.net.URLEncoder
import java.net.InetAddress
import java.net.Socket
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit.SECONDS
import java.util.logging.Handler
import java.util.logging.LogRecord
import java.util.logging.Logger
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

    @Test fun `scanner detects hidden binary encoded and nested JSON copies`() {
        val sentinel = UUID.randomUUID().toString() + "\"\\/%+雪😀"
        val credential = "{\"key\":" + JsonPrimitive(sentinel) + "}"
        reportToHostAudit(sentinel, credential)
        fun escaped(value: String) = JsonPrimitive(value).toString().removeSurrounding("\"")
        val copies = listOf(sentinel, credential,
            Base64.getEncoder().encodeToString(sentinel.encodeToByteArray()),
            Base64.getUrlEncoder().encodeToString(sentinel.encodeToByteArray()),
            Base64.getEncoder().encodeToString(credential.encodeToByteArray()),
            URLEncoder.encode(sentinel, "UTF-8"),
            Regex("%[0-9A-F]{2}").replace(URLEncoder.encode(sentinel, "UTF-8")) { it.value.lowercase() },
            escaped(sentinel), escaped(escaped(sentinel)), escaped(credential), escaped(escaped(credential)),
            escaped(sentinel).replace("/", "\\/"),
            escaped(sentinel).replace("雪", "\\u96ea").replace("😀", "\\ud83d\\ude00"))
            .map { it.encodeToByteArray() } + listOf(Charsets.UTF_16LE, Charsets.UTF_16BE).flatMap { charset ->
                listOf(sentinel, credential).map { it.toByteArray(charset) }
            }
        val path = temporary.resolve(".logs/.cache/output.bin")
        for ((index, copy) in copies.withIndex()) {
            put(path, ByteArray(65_533) + copy + byteArrayOf(-1))
            assertFailsWith<AssertionError>("Encoded copy $index was missed") { scan(sentinel, credential, ByteArrayOutputStream()) }
            Files.delete(path)
            val output = ByteArrayOutputStream().apply { write(copy) }
            assertFailsWith<AssertionError>("Diagnostic copy $index was missed") { scan(sentinel, credential, output) }
        }
        scan(sentinel, credential, ByteArrayOutputStream())
        val scanner = SecretScan(listOf(sentinel, credential))
        assertFailsWith<IllegalStateException> { scanner.matches(temporary.resolve("missing")) }
        val link = temporary.resolve("log-link")
        Files.createSymbolicLink(link, path.parent)
        try { assertFailsWith<IllegalStateException> { scanner.matches(temporary) } }
        finally { Files.delete(link) }
    }

    @Test fun `OpenAI lifecycle persists ciphertext only`() = lifecycle(ProviderKind.OPENAI_COMPATIBLE)
    @Test fun `Anthropic lifecycle persists ciphertext only`() = lifecycle(ProviderKind.ANTHROPIC)

    private fun lifecycle(kind: ProviderKind) = runTest(scheduler) {
        val sentinel = UUID.randomUUID().toString() + "\"\\/%+雪😀"
        val owner = Thread.currentThread()
        var persistenceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        lateinit var state: AndroidStateStore
        lateinit var secrets: AndroidKeystoreSecretStore
        var readUnavailable = false
        val keys = object : SecretKeyProvider {
            private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            override fun read(): SecretKey {
                if (readUnavailable) throw SecretStoreError.Unavailable
                return key
            }
            override fun create(): SecretKey = error("Existing test alias should be reused")
            override fun replace(): SecretKey = error("No recovery is expected")
        }
        fun openStores() {
            val metadata = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = persistenceScope,
                produceFile = { filesDir.resolve("datastore/settings.json").toFile() }))
            state = AndroidStateStore(stateDir.toFile(), settings = metadata, isMainThread = { Thread.currentThread() == owner })
            secrets = AndroidKeystoreSecretStore(DataStoreFactory.create(serializer = SecretsSerializer, scope = persistenceScope,
                produceFile = { filesDir.resolve("datastore/secrets.json").toFile() }), keys, Dispatchers.IO)
        }
        openStores()
        val server = MockWebServer().apply { start() }
        val dispatcher = Dispatcher()
        val clock = MonotonicClock(System::nanoTime)
        val transport = OkHttpHttpTransport(clock, scope, dispatcher)
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
        val logger = Logger.getLogger("MonkeysPaw")
        val handler = object : Handler() {
            override fun publish(record: LogRecord) {
                sink.println(record.message)
                record.parameters?.forEach { sink.println(it) }
                record.thrown?.printStackTrace(sink)
            }
            override fun flush() = sink.flush()
            override fun close() = Unit
        }
        logger.addHandler(handler)
        var safeDiagnostics = false
        System.setOut(sink); System.setErr(sink)
        try {
            val device = SecretAccount.device(UUID.randomUUID())
            secrets.write(SecretValue(sentinel), device)
            var model = newModel()
            settled(model)
            model.addProfile(kind)
            model.setBaseURL(server.url("/v1").toString())
            model.setModelID("manual")
            model.setKeyInput(sentinel)
            model.save()
            settled(model)
            val first = model.state.value.draft!!.id
            assertEquals(AssistantKeyStorage.Saved(SecretTier.KEYSTORE), model.state.value.keyStorage)
            assertEquals(AssistantKeyEdit.KEEP, model.state.value.keyEdit)
            val credential = secrets.read(SecretAccount.provider(first), SecretReadSource.PERSISTED)!!.value.withValue { it }
            // Optional host audit retains these runtime values in memory until Gradle writes its final reports.
            reportToHostAudit(sentinel, credential)
            val account = SecretAccount.provider(first).rawValue
            suspend fun checkpoint(label: String, accounts: Set<String> = setOf(account, device.rawValue)) {
                sink.println(model.state.value)
                logger.warning("Assistant scan checkpoint: $label")
                put(temporary.resolve(".logs/.cache/diagnostic.log"), diagnostics.toByteArray())
                put(temporary.resolve(".temp/test-output.bin"), diagnostics.toByteArray())
                scan(sentinel, credential, diagnostics)
                val records = Files.newInputStream(filesDir.resolve("datastore/secrets.json")).use { SecretsSerializer.readFrom(it) }
                assertEquals(accounts, records.entries.keys, "Only expected encrypted accounts may persist")
                println("$kind $label: zero secret copies; ${accounts.size} encrypted accounts.")
            }
            checkpoint("Save")
            server.enqueue(MockResponse.Builder().body("{\"data\":[{\"id\":\"listed\"}]}").build())
            model.testConnection()
            model.state.first { !it.isTesting }
            assertEquals(ConnectionTestResult.Ok(listOf(ModelDescriptor("listed"))), model.state.value.testResult)
            val successRequest = assertNotNull(server.takeRequest(2, SECONDS))
            assertEquals("GET", successRequest.method)
            assertEquals("/v1/models", successRequest.target)
            val header = if (kind == ProviderKind.ANTHROPIC) "x-api-key" else "Authorization"
            val authentication = if (kind == ProviderKind.ANTHROPIC) sentinel else "Bearer $sentinel"
            assertTrue(successRequest.headers[header] == authentication, "Only the draft's stored credential is sent")
            checkpoint("successful Test")
            server.enqueue(MockResponse.Builder().code(401).body("{\"error\":{\"message\":" + JsonPrimitive(sentinel) + "}}").build())
            model.testConnection()
            model.state.first { !it.isTesting }
            assertEquals(ConnectionTestResult.Authentication, model.state.value.testResult)
            val failedRequest = assertNotNull(server.takeRequest(2, SECONDS))
            assertTrue(failedRequest.headers[header] == authentication, "Failed Test retains credential isolation")
            checkpoint("failed Test with diagnostic echo")
            model.close()
            models.clear()
            persistenceScope.coroutineContext[Job]!!.cancelAndJoin()
            persistenceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            openStores()
            model = newModel()
            settled(model)
            assertEquals(first, model.state.value.selectedProfileID)
            assertTrue(secrets.read(SecretAccount.provider(first), SecretReadSource.PERSISTED)!!.value.withValue { it == credential },
                "Reopened encrypted credential must resolve unchanged")
            checkpoint("graph reconstruction with reopened DataStores")
            model.renameProfile("Renamed"); model.save(); settled(model)
            checkpoint("rename")

            val savedMetadata = Files.readAllBytes(filesDir.resolve("datastore/settings.json"))
            val savedCiphertext = Files.readAllBytes(filesDir.resolve("datastore/secrets.json"))
            readUnavailable = true
            model.clearKey(); model.save(); settled(model)
            assertEquals(ProviderSettingsError.Secret(SecretStoreError.Unavailable), model.state.value.error)
            checkpoint("unavailable alias refuses Settings Clear")
            model.deleteProfile(first); settled(model)
            assertEquals(ProviderSettingsError.Secret(SecretStoreError.Unavailable), model.state.value.error)
            assertTrue(savedMetadata.contentEquals(Files.readAllBytes(filesDir.resolve("datastore/settings.json"))))
            assertTrue(savedCiphertext.contentEquals(Files.readAllBytes(filesDir.resolve("datastore/secrets.json"))))
            checkpoint("unavailable alias refuses Settings Delete")
            readUnavailable = false
            model.refresh(); settled(model)

            model.addProfile(); model.save(); settled(model)
            val second = model.state.value.draft!!.id
            model.selectProfile(second); settled(model)
            checkpoint("switch away")
            model.selectProfile(null); settled(model)
            checkpoint("switch off")
            model.selectProfile(first); settled(model)
            checkpoint("switch back")
            model.deleteProfile(second); settled(model)
            checkpoint("unrelated profile deletion")
            model.deleteProfile(first); settled(model)
            assertNull(secrets.read(SecretAccount.provider(first), SecretReadSource.PERSISTED))
            assertTrue(model.state.value.profiles.isEmpty())
            assertEquals(2, server.requestCount, "Only the two explicit Test intents issue requests")
            assertNotNull(provider)
            assertTrue(secrets.read(device, SecretReadSource.PERSISTED)!!.value.withValue { it == sentinel },
                "Provider deletion preserves the device account")
            checkpoint("sentinel profile deletion", setOf(device.rawValue))
            secrets.delete(device)
            checkpoint("final account deletion", emptySet())
            assertFalse(Files.exists(stateDir.resolve("provider-settings.json")))
            assertFalse(Files.exists(stateDir.resolve("provider-state.json")))
            scan(sentinel, credential, diagnostics)
            safeDiagnostics = true
        } finally {
            logger.removeHandler(handler)
            System.setOut(stdout); System.setErr(stderr); sink.close()
            if (safeDiagnostics) stdout.print(diagnostics.toString("UTF-8"))
            models.clear()
            persistenceScope.coroutineContext[Job]!!.cancelAndJoin()
            scope.coroutineContext[Job]!!.cancelAndJoin()
            dispatcher.cancelAll()
            server.close()
            dispatcher.executorService.shutdown()
        }
    }

    private fun scan(sentinel: String, credential: String, diagnostics: ByteArrayOutputStream) {
        val scanner = SecretScan(listOf(sentinel, credential))
        assertTrue(scanner.matches(temporary).isEmpty(), "Secret escaped encrypted storage into a file")
        assertFalse(scanner.contains(diagnostics.toByteArray()), "Secret escaped into diagnostics/test output")
    }

    private fun reportToHostAudit(vararg values: String) {
        val port = System.getenv("MONKEYSPAW_TEST_SECRET_AUDIT_PORT")?.toInt() ?: return
        Socket(InetAddress.getLoopbackAddress(), port).use { socket ->
            socket.getOutputStream().write((JsonArray(values.map(::JsonPrimitive)).toString() + "\n").encodeToByteArray())
        }
    }
}

/** Byte-preserving, streaming scan: hidden files count, symlinks and unreadable roots cannot silently pass. */
private class SecretScan(values: List<String>) {
    private val patterns: List<String> = values.flatMap { value ->
        val variants = mutableSetOf(value, Base64.getEncoder().encodeToString(value.encodeToByteArray()),
            Base64.getUrlEncoder().encodeToString(value.encodeToByteArray()))
        val percent = URLEncoder.encode(value, "UTF-8")
        variants += listOf(percent, percent.replace("+", "%20"),
            Regex("%[0-9A-F]{2}").replace(percent) { it.value.lowercase() })
        var escaped = setOf(value)
        repeat(2) {
            escaped = escaped.flatMap { text ->
                val json = JsonPrimitive(text).toString().removeSurrounding("\"")
                val ascii = json.flatMap { char -> if (char.code > 127) "\\u%04x".format(char.code).toList() else listOf(char) }.joinToString("")
                listOf(json, json.replace("/", "\\/"), ascii, ascii.replace("/", "\\/"))
            }.toSet()
            variants += escaped
        }
        variants
    }.map { String(it.encodeToByteArray(), Charsets.ISO_8859_1) } + values.flatMap { value ->
        listOf(Charsets.UTF_16LE, Charsets.UTF_16BE).map { String(value.toByteArray(it), Charsets.ISO_8859_1) }
    }

    fun contains(bytes: ByteArray): Boolean {
        val text = String(bytes, Charsets.ISO_8859_1)
        return patterns.any { it in text }
    }

    fun matches(root: Path): Set<Path> {
        check(Files.isDirectory(root, NOFOLLOW_LINKS)) { "A scan root is missing" }
        val found = mutableSetOf<Path>()
        Files.walk(root).use { paths -> paths.forEach { path ->
            check(!Files.isSymbolicLink(path)) { "A scan root contains a symlink" }
            if (Files.isRegularFile(path, NOFOLLOW_LINKS)) Files.newInputStream(path).use { stream ->
                var tail = byteArrayOf()
                val overlap = patterns.maxOf { it.length } - 1
                val buffer = ByteArray(65_536)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    val bytes = tail + buffer.copyOf(count)
                    if (contains(bytes)) { found.add(path); break }
                    tail = bytes.takeLast(overlap).toByteArray()
                }
            }
        } }
        return found
    }
}
