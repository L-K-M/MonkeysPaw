package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import kotlin.test.*

internal class AndroidSettingsStoreTest : TemporaryFiles() {
    @Test
    fun `only versioned seed and setup decisions are serialized`() = runBlocking {
        val output = ByteArrayOutputStream()
        SettingsSerializer.writeTo(AndroidSettings(SeedProgress.INSTALLING), output)
        assertEquals("{\"seedProgress\":\"INSTALLING\",\"version\":1,\"keyboardTileSetup\":{\"version\":1," +
            "\"enableKeyboard\":\"PENDING\",\"selectKeyboard\":\"PENDING\",\"addTile\":\"PENDING\"}}", output.toString(Charsets.UTF_8))
        assertEquals(AndroidSettings(SeedProgress.INSTALLING), SettingsSerializer.readFrom(ByteArrayInputStream(output.toByteArray())))
    }

    @Test
    fun `seed provider records sync trust and setup decisions round trip together`() = runBlocking {
        val settings = AndroidSettings(seedProgress = SeedProgress.DECLINED, records = mapOf(
            "provider-settings" to SettingsRecord(" metadata\n雪/é😀 ", "settings-incarnation"),
            "provider-state" to SettingsRecord("capability", "state-incarnation")),
            syncTls = SyncTlsSettings(SyncServerURL("https://sync.example/paw"), SyncTLSTrust.SYSTEM_AND_USER),
            keyboardTileSetup = KeyboardTileSetupProgress(SetupDecision.COMPLETE, SetupDecision.SKIPPED, SetupDecision.PENDING))
        val output = ByteArrayOutputStream()
        SettingsSerializer.writeTo(settings, output)
        assertEquals(settings, SettingsSerializer.readFrom(ByteArrayInputStream(output.toByteArray())))
    }

    @Test
    fun `version one files with every optional field subset load without rewriting`() = runBlocking {
        val path = filesDir.resolve("datastore/settings.json")
        val records = mapOf("provider-settings" to SettingsRecord("metadata", "fixture-stamp"))
        val syncTls = SyncTlsSettings(SyncServerURL("https://sync.example/paw"), SyncTLSTrust.SYSTEM_AND_USER)
        val setup = KeyboardTileSetupProgress(SetupDecision.COMPLETE, SetupDecision.SKIPPED, SetupDecision.COMPLETE)
        val recordsField = """, "records":{"provider-settings":{"payload":"metadata","stamp":"fixture-stamp"}}"""
        val syncTlsField = """, "syncTls":{"serverURL":"https://sync.example/paw","trust":"SYSTEM_AND_USER"}"""
        val setupField = """, "keyboardTileSetup":{"version":1,"enableKeyboard":"COMPLETE","selectKeyboard":"SKIPPED","addTile":"COMPLETE"}"""
        for ((fields, expected) in listOf(
            "" to AndroidSettings(),
            recordsField to AndroidSettings(records = records),
            syncTlsField to AndroidSettings(syncTls = syncTls),
            setupField to AndroidSettings(keyboardTileSetup = setup),
            "$recordsField$syncTlsField" to AndroidSettings(records = records, syncTls = syncTls),
            "$recordsField$setupField" to AndroidSettings(records = records, keyboardTileSetup = setup),
            "$syncTlsField$setupField" to AndroidSettings(syncTls = syncTls, keyboardTileSetup = setup),
            "$recordsField$syncTlsField$setupField" to AndroidSettings(records = records, syncTls = syncTls, keyboardTileSetup = setup),
        )) {
            for (seed in SeedProgress.entries) {
                val original = """{"version":1,"seedProgress":"${seed.name}"$fields}""".encodeToByteArray()
                put(path, original)
                withStore { assertEquals(expected.copy(seedProgress = seed), it.read()) }
                assertContentEquals(original, Files.readAllBytes(path))
            }
        }
    }

    @Test
    fun `atomic seed provider record sync trust and setup updates preserve all fields on reopen`() = runBlocking {
        val records = mapOf("provider-settings" to SettingsRecord("metadata", "settings-incarnation"),
            "provider-state" to SettingsRecord("capability", "state-incarnation"))
        val server = SyncServerURL("https://sync.example/paw")
        val setup = KeyboardTileSetupProgress(SetupDecision.SKIPPED, SetupDecision.COMPLETE, SetupDecision.SKIPPED)
        val expected = AndroidSettings(seedProgress = SeedProgress.COMPLETE, records = records,
            syncTls = SyncTlsSettings(server, SyncTLSTrust.SYSTEM_AND_USER), keyboardTileSetup = setup)
        withStore { store ->
            store.selectSyncServer(server)
            coroutineScope {
                (1..20).flatMap { listOf(async { store.setSeedProgress(expected.seedProgress) },
                    async { store.updateRecords { records } },
                    async { store.setSyncTlsTrust(server, SyncTLSTrust.SYSTEM_AND_USER) },
                    async { store.setKeyboardTileSetup(setup) }) }.awaitAll()
            }
            assertEquals(expected, store.read())
        }
        withStore { assertEquals(expected, it.read()) }
    }

    @Test
    fun `null optional fields and unknown keys reject without overwriting coexisting settings`() = runBlocking {
        val server = SyncServerURL("https://sync.example/paw")
        val settings = AndroidSettings(seedProgress = SeedProgress.DECLINED,
            records = mapOf("provider-settings" to SettingsRecord("metadata", "fixture-stamp")),
            syncTls = SyncTlsSettings(server, SyncTLSTrust.SYSTEM_AND_USER),
            keyboardTileSetup = KeyboardTileSetupProgress(SetupDecision.COMPLETE, SetupDecision.SKIPPED, SetupDecision.COMPLETE))
        val output = ByteArrayOutputStream()
        SettingsSerializer.writeTo(settings, output)
        val valid = Json.parseToJsonElement(output.toString(Charsets.UTF_8)) as JsonObject
        val path = filesDir.resolve("datastore/settings.json")
        for (key in listOf("records", "syncTls", "keyboardTileSetup", "unknown")) {
            val bytes = JsonObject(valid + (key to JsonNull)).toString().encodeToByteArray()
            put(path, bytes)
            withStore { store ->
                assertFailsWith<CorruptionException> { store.read() }
                assertFailsWith<CorruptionException> { store.setSeedProgress(SeedProgress.NOT_OFFERED) }
                assertFailsWith<CorruptionException> { store.updateRecords { emptyMap() } }
                assertFailsWith<CorruptionException> { store.selectSyncServer(null) }
                assertFailsWith<CorruptionException> { store.setSyncTlsTrust(server, SyncTLSTrust.SYSTEM) }
                assertFailsWith<CorruptionException> { store.setKeyboardTileSetup(KeyboardTileSetupProgress()) }
            }
            assertContentEquals(bytes, Files.readAllBytes(path))
            withStore { assertFailsWith<CorruptionException> { it.read() } }
            assertContentEquals(bytes, Files.readAllBytes(path))
        }
    }

    @Test
    fun `M8 settings upgrade retains every seed state and offers setup only until resolved`() = runBlocking {
        val path = filesDir.resolve("datastore/settings.json")
        val resolved = KeyboardTileSetupProgress(SetupDecision.COMPLETE, SetupDecision.SKIPPED, SetupDecision.COMPLETE)
        for (seed in SeedProgress.entries) {
            val original = "{\"version\":1,\"seedProgress\":\"${seed.name}\"}".encodeToByteArray()
            put(path, original)
            withStore { store ->
                assertEquals(AndroidSettings(seed), store.read())
                assertContentEquals(original, java.nio.file.Files.readAllBytes(path))
                store.setKeyboardTileSetup(resolved)
                assertEquals(seed, store.read().seedProgress)
            }
            withStore { assertEquals(AndroidSettings(seed, keyboardTileSetup = resolved), it.read()) }
        }
    }

    @Test
    fun `atomic setup and seed updates preserve one another`() = runBlocking {
        val resolved = KeyboardTileSetupProgress(SetupDecision.SKIPPED, SetupDecision.COMPLETE, SetupDecision.SKIPPED)
        withStore { store ->
            coroutineScope {
                (1..20).flatMap { listOf(async { store.setSeedProgress(SeedProgress.COMPLETE) },
                    async { store.setKeyboardTileSetup(resolved) }) }.awaitAll()
            }
            assertEquals(AndroidSettings(SeedProgress.COMPLETE, keyboardTileSetup = resolved), store.read())
        }
        withStore { assertEquals(AndroidSettings(SeedProgress.COMPLETE, keyboardTileSetup = resolved), it.read()) }
    }

    @Test
    fun `DataStore persists progress atomically and reopens`() = runBlocking {
        withStore { store ->
            assertEquals(AndroidSettings(), store.read())
            store.setSeedProgress(SeedProgress.INSTALLING)
            assertEquals(SeedProgress.INSTALLING, store.read().seedProgress)
        }
        withStore { store ->
            assertEquals(SeedProgress.INSTALLING, store.read().seedProgress)
            store.setSeedProgress(SeedProgress.COMPLETE)
        }
        withStore { assertEquals(SeedProgress.COMPLETE, it.read().seedProgress) }
    }

    @Test
    fun `concurrent updates remain a complete valid settings document`() = runBlocking {
        withStore { store ->
            coroutineScope {
                (1..30).map { async { store.setSeedProgress(SeedProgress.INSTALLING) } }.awaitAll()
            }
            assertEquals(SeedProgress.INSTALLING, store.read().seedProgress)
        }
        withStore { assertEquals(SeedProgress.INSTALLING, it.read().seedProgress) }
    }

    @Test
    fun `decline survives restart so it cannot be offered again`() = runBlocking {
        withStore { it.setSeedProgress(SeedProgress.DECLINED) }
        withStore { assertEquals(SeedProgress.DECLINED, it.read().seedProgress) }
    }

    @Test
    fun `corrupt invalid UTF8 wrong types and future versions never reset on read or update`() = runBlocking {
        val path = filesDir.resolve("datastore/settings.json")
        for (bytes in listOf(byteArrayOf(-1), "bad".encodeToByteArray(),
            "{\"version\":2,\"seedProgress\":\"COMPLETE\"}".encodeToByteArray(),
            "{\"version\":3,\"seedProgress\":\"COMPLETE\"}".encodeToByteArray(),
            "{\"version\":\"1\",\"seedProgress\":\"COMPLETE\"}".encodeToByteArray(),
            "{\"version\":1,\"seedProgress\":7}".encodeToByteArray(),
            "{\"version\":1,\"seedProgress\":\"UNKNOWN\"}".encodeToByteArray(),
            "{\"version\":1,\"seedProgress\":\"COMPLETE\",\"values\":{}}".encodeToByteArray())) {
            put(path, bytes)
            withStore { store ->
                val error = assertFailsWith<CorruptionException> { store.read() }
                assertNull(error.cause)
                assertFailsWith<CorruptionException> { store.setSeedProgress(SeedProgress.NOT_OFFERED) }
            }
            assertContentEquals(bytes, java.nio.file.Files.readAllBytes(path))
            withStore { assertFailsWith<CorruptionException> { it.read() } }
            assertContentEquals(bytes, java.nio.file.Files.readAllBytes(path))
        }
        val output = ByteArrayOutputStream()
        SettingsSerializer.writeTo(AndroidSettings(), output)
        val valid = output.toString(Charsets.UTF_8)
        for (invalid in listOf(valid.replace("\"version\":1", "\"version\":2"),
            valid.replace("\"keyboardTileSetup\":{\"version\":1", "\"keyboardTileSetup\":{\"version\":2"),
            valid.replace("\"enableKeyboard\":\"PENDING\"", "\"enableKeyboard\":false"),
            valid.replace("\"enableKeyboard\":\"PENDING\"", "\"enableKeyboard\":\"FOREIGN_ID\""),
            valid.replace("\"addTile\":\"PENDING\"", "\"addTile\":\"PENDING\",\"keyboardId\":\"private\""))) {
            val bytes = invalid.encodeToByteArray()
            put(path, bytes)
            withStore { store ->
                assertFailsWith<CorruptionException> { store.read() }
                assertFailsWith<CorruptionException> { store.setKeyboardTileSetup(KeyboardTileSetupProgress()) }
            }
            assertContentEquals(bytes, java.nio.file.Files.readAllBytes(path))
        }
    }

    @Test
    fun `a filesystem failure is sanitized rather than turned into defaults`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer,
                scope = scope, produceFile = { throw IOException("SECRET source path") }))
            val error = assertFailsWith<StoreError.IOFailure> { store.read() }
            assertNull(error.cause)
            assertFalse(error.toString().contains("SECRET"))
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }

    @Test
    fun `sync trust reopens bound to one normalized deployment and defaults elsewhere`() = runBlocking {
        val selected = SyncServerURL("HTTPS://SYNC.EXAMPLE.:443/paw/api/v1/")
        withStore { store ->
            assertNull(store.read().syncTls)
            store.selectSyncServer(selected)
            assertEquals(SyncTLSTrust.SYSTEM, store.read().syncTls!!.trust)
            store.setSyncTlsTrust(selected, SyncTLSTrust.SYSTEM_AND_USER)
        }
        withStore { store ->
            val option = store.read().syncTls!!
            assertEquals("https://sync.example/paw", option.server.baseURL)
            assertEquals(SyncTLSTrust.SYSTEM_AND_USER, option.trustFor(SyncServerURL("https://sync.example/paw")))
            for (url in listOf("https://other.example/paw", "https://sync.example:444/paw", "https://sync.example/other",
                "http://localhost/paw")) assertEquals(SyncTLSTrust.SYSTEM, option.trustFor(SyncServerURL(url)))
            store.selectSyncServer(SyncServerURL("https://sync.example/paw/api/v1"))
            assertEquals(option, store.read().syncTls)
            assertEquals("<sync TLS settings>", option.toString())
        }
        val raw = Files.readString(filesDir.resolve("datastore/settings.json"))
        assertTrue(raw.contains("\"syncTls\":{\"serverURL\":\"https://sync.example/paw\",\"trust\":\"SYSTEM_AND_USER\"}"))
        assertFalse(raw.contains("certificate"))
    }

    @Test
    fun `server changes and clearing reset trust while stale opt ins cannot change the selected server`() = runBlocking {
        val first = SyncServerURL("https://sync.example/paw")
        val second = SyncServerURL("https://sync.example/other")
        withStore { store ->
            store.selectSyncServer(first)
            store.setSyncTlsTrust(first, SyncTLSTrust.SYSTEM_AND_USER)
            store.selectSyncServer(second)
            assertEquals(SyncTlsSettings(second), store.read().syncTls)
            val bytes = Files.readAllBytes(filesDir.resolve("datastore/settings.json"))
            val error = assertFailsWith<SyncTlsSettingsError> { store.setSyncTlsTrust(first, SyncTLSTrust.SYSTEM_AND_USER) }
            assertSame(SyncTlsSettingsError.ServerChanged, error)
            assertNull(error.cause)
            assertContentEquals(bytes, Files.readAllBytes(filesDir.resolve("datastore/settings.json")))
            store.selectSyncServer(first)
            assertEquals(SyncTLSTrust.SYSTEM, store.read().syncTls!!.trust)
            store.setSyncTlsTrust(first, SyncTLSTrust.SYSTEM_AND_USER)
            store.setSyncTlsTrust(first, SyncTLSTrust.SYSTEM)
            assertEquals(SyncTLSTrust.SYSTEM, store.read().syncTls!!.trust)
            store.selectSyncServer(null)
            assertNull(store.read().syncTls)
            assertFailsWith<SyncTlsSettingsError> { store.setSyncTlsTrust(first, SyncTLSTrust.SYSTEM_AND_USER) }
        }
        withStore { assertNull(it.read().syncTls) }
    }

    @Test
    fun `sync option writes preserve provider payloads seed progress and setup under concurrent updates`() = runBlocking {
        val server = SyncServerURL("https://sync.example")
        val records = mapOf("provider-settings" to SettingsRecord("provider metadata", "stamp-one"),
            "provider-state" to SettingsRecord("capability state", "stamp-two"))
        val setup = KeyboardTileSetupProgress(SetupDecision.COMPLETE, SetupDecision.SKIPPED, SetupDecision.COMPLETE)
        withStore { store ->
            store.selectSyncServer(server)
            coroutineScope {
                val seed = async { repeat(20) { store.setSeedProgress(SeedProgress.COMPLETE) } }
                val providers = async { repeat(20) { store.updateRecords { records } } }
                val tls = async { repeat(20) { store.setSyncTlsTrust(server, SyncTLSTrust.SYSTEM_AND_USER) } }
                val keyboard = async { repeat(20) { store.setKeyboardTileSetup(setup) } }
                awaitAll(seed, providers, tls, keyboard)
            }
        }
        withStore { store ->
            assertEquals(records, store.read().records)
            assertEquals(SeedProgress.COMPLETE, store.read().seedProgress)
            assertEquals(SyncTlsSettings(server, SyncTLSTrust.SYSTEM_AND_USER), store.read().syncTls)
            assertEquals(setup, store.read().keyboardTileSetup)
            store.updateRecords { it - "provider-state" }
            assertEquals(SyncTlsSettings(server, SyncTLSTrust.SYSTEM_AND_USER), store.read().syncTls)
            assertEquals(setup, store.read().keyboardTileSetup)
            store.selectSyncServer(null)
            assertNull(store.read().syncTls)
            assertEquals(records - "provider-state", store.read().records)
            assertEquals(SeedProgress.COMPLETE, store.read().seedProgress)
            assertEquals(setup, store.read().keyboardTileSetup)
        }
    }

    @Test
    fun `invalid trust records fail closed without resetting or overwriting settings`() = runBlocking {
        val path = filesDir.resolve("datastore/settings.json")
        val server = SyncServerURL("https://sync.example")
        for (option in listOf("null", "[]", "{}", "{\"serverURL\":\"https://sync.example\",\"trust\":true}",
            "{\"serverURL\":7,\"trust\":\"SYSTEM\"}", "{\"serverURL\":\"https://sync.example\",\"trust\":\"TRUST_ALL\"}",
            "{\"serverURL\":\"https://sync.example\",\"trust\":\"SYSTEM\",\"extra\":true}",
            "{\"serverURL\":\"HTTPS://SYNC.EXAMPLE/api/v1\",\"trust\":\"SYSTEM_AND_USER\"}",
            "{\"serverURL\":\"https://user:secret@sync.example\",\"trust\":\"SYSTEM_AND_USER\"}")) {
            val bytes = "{\"version\":1,\"seedProgress\":\"COMPLETE\",\"syncTls\":$option}".encodeToByteArray()
            put(path, bytes)
            withStore { store ->
                assertNull(assertFailsWith<androidx.datastore.core.CorruptionException> { store.read() }.cause)
                assertFailsWith<androidx.datastore.core.CorruptionException> { store.selectSyncServer(server) }
                assertFailsWith<androidx.datastore.core.CorruptionException> { store.setSyncTlsTrust(server, SyncTLSTrust.SYSTEM) }
                assertFailsWith<androidx.datastore.core.CorruptionException> { store.updateRecords { emptyMap() } }
            }
            assertContentEquals(bytes, Files.readAllBytes(path))
        }
    }

    @Test
    fun `failed trust publication preserves the binding and unrelated provider settings after restart`() = runBlocking {
        val server = SyncServerURL("https://sync.example/paw")
        var fail = false
        val serializer = object : Serializer<AndroidSettings> by SettingsSerializer {
            override suspend fun writeTo(t: AndroidSettings, output: OutputStream) {
                SettingsSerializer.writeTo(t, output)
                if (fail) throw IOException("synthetic publication failure")
            }
        }
        val records = mapOf("provider-settings" to SettingsRecord("provider metadata", "stamp"))
        withStore(serializer) { store ->
            store.setSeedProgress(SeedProgress.DECLINED)
            store.updateRecords { records }
            store.selectSyncServer(server)
            store.setSyncTlsTrust(server, SyncTLSTrust.SYSTEM_AND_USER)
            val prior = store.read()
            val bytes = Files.readAllBytes(filesDir.resolve("datastore/settings.json"))
            fail = true
            assertFailsWith<StoreError.IOFailure> { store.setSyncTlsTrust(server, SyncTLSTrust.SYSTEM) }
            assertFailsWith<StoreError.IOFailure> { store.selectSyncServer(SyncServerURL("https://other.example")) }
            assertFailsWith<StoreError.IOFailure> { store.selectSyncServer(null) }
            assertEquals(prior, store.read())
            assertContentEquals(bytes, Files.readAllBytes(filesDir.resolve("datastore/settings.json")))
        }
        withStore { store ->
            assertEquals(records, store.read().records)
            assertEquals(SeedProgress.DECLINED, store.read().seedProgress)
            assertEquals(SyncTlsSettings(server, SyncTLSTrust.SYSTEM_AND_USER), store.read().syncTls)
        }
    }

    private suspend fun withStore(serializer: Serializer<AndroidSettings> = SettingsSerializer, work: suspend (AndroidSettingsStore) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = DataStoreFactory.create(serializer = serializer, scope = scope,
                produceFile = { filesDir.resolve("datastore/settings.json").toFile() })
            work(AndroidSettingsStore(store))
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }
}
