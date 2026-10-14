package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsService
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.*
import java.io.IOException
import java.nio.file.Files
import kotlin.test.*

internal class ProviderRecordMappingTest : TemporaryFiles() {
    @Test fun `old M8 settings open without a speculative rewrite and provider records reopen byte exact`() = runBlocking {
        val original = "{\"version\":1,\"seedProgress\":\"DECLINED\"}"
        val path = filesDir.resolve("datastore/settings.json")
        put(path, original.encodeToByteArray())
        val metadata = " \n{\"version\":1,\"profiles\":[],\"unknown\":{\"a\":[null,\"雪/é😀\"]}}\n"
        val capability = "{\"version\":1,\"profiles\":[],\"future\":true}"
        withStore { settings, state ->
            assertEquals(SeedProgress.DECLINED, settings.read().seedProgress)
            assertNull(state.stamp("provider-settings.json"))
            assertFailsWith<StoreError.NotFound> { state.read("provider-state.json") }
            assertEquals(original, Files.readString(path))
            state.write(metadata.encodeToByteArray(), "provider-settings.json")
            state.write(capability.encodeToByteArray(), "provider-state.json")
            settings.setSeedProgress(SeedProgress.COMPLETE)
            assertContentEquals(metadata.encodeToByteArray(), state.read("provider-settings.json"))
            assertContentEquals(capability.encodeToByteArray(), state.read("provider-state.json"))
        }
        withStore { settings, state ->
            assertEquals(SeedProgress.COMPLETE, settings.read().seedProgress)
            assertEquals(metadata, state.read("provider-settings.json").decodeToString())
            assertEquals(capability, state.read("provider-state.json").decodeToString())
            val root = Json.parseToJsonElement(Files.readString(path)).jsonObject
            assertEquals(setOf("provider-settings", "provider-state"), root.getValue("records").jsonObject.keys)
        }
        assertFalse(Files.exists(stateDir.resolve("provider-settings.json")))
        assertFalse(Files.exists(stateDir.resolve("provider-state.json")))
        assertEquals(listOf("settings.json"), Files.list(path.parent).use { it.map { entry -> entry.fileName.toString() }.toList() })
    }

    @Test fun `concurrent seed and provider record updates preserve all three independent settings`() = runBlocking {
        withStore { settings, state ->
            coroutineScope {
                val seed = async { repeat(20) { settings.setSeedProgress(SeedProgress.INSTALLING) } }
                val metadata = async(Dispatchers.IO) { repeat(20) { state.write("metadata-$it".encodeToByteArray(), "provider-settings.json") } }
                val capability = async(Dispatchers.IO) { repeat(20) { state.write("capability-$it".encodeToByteArray(), "provider-state.json") } }
                awaitAll(seed, metadata, capability)
            }
            assertEquals(SeedProgress.INSTALLING, settings.read().seedProgress)
            assertEquals("metadata-19", state.read("provider-settings.json").decodeToString())
            assertEquals("capability-19", state.read("provider-state.json").decodeToString())
        }
        withStore { _, state -> assertEquals("metadata-19", state.read("provider-settings.json").decodeToString()) }
    }

    @Test fun `provider corruption stays intact through seed updates and blocks Core before secrets`() = runBlocking {
        withStore { settings, state ->
            for ((payload, expected) in listOf("invalid" to ProviderSettingsError.CorruptFile,
                "{\"version\":9}" to ProviderSettingsError.FutureVersion(9))) {
                state.write(payload.encodeToByteArray(), "provider-settings.json")
                val secrets = NoSecretAccess()
                val service = ProviderSettingsService(ProviderSettingsStore(state), secrets, Dispatchers.IO)
                assertEquals(expected, service.snapshot.readOnlyError)
                assertEquals(expected, assertFailsWith<ProviderSettingsError> { service.save(ProviderDraft()) })
                assertEquals(expected, assertFailsWith<ProviderSettingsError> { service.resolveForTesting(ProviderDraft()) })
                settings.setSeedProgress(SeedProgress.COMPLETE)
                assertEquals(payload, state.read("provider-settings.json").decodeToString())
                assertEquals(0, secrets.calls)
            }
        }
    }

    @Test fun `malformed future and unreadable outer settings never reset or create provider files`() = runBlocking {
        val path = filesDir.resolve("datastore/settings.json")
        for (text in listOf("invalid", "{\"version\":7,\"seedProgress\":\"COMPLETE\"}",
            "{\"version\":1,\"seedProgress\":\"COMPLETE\",\"records\":{\"provider-settings\":7}}",
            "{\"version\":1,\"seedProgress\":\"COMPLETE\",\"records\":{\"provider-settings\":{\"payload\":\"{}\",\"stamp\":\"\"}}}",
            "{\"version\":1,\"seedProgress\":\"COMPLETE\",\"records\":{\"provider-settings\":{\"payload\":\"raw\nnewline\",\"stamp\":\"fixture\"}}}",
            "{\"version\":1,\"seedProgress\":\"COMPLETE\",\"records\":" + "[".repeat(2000) + "0" + "]".repeat(2000) + "}")) {
            put(path, text.encodeToByteArray())
            withStore { settings, state ->
                assertFailsWith<CorruptionException> { state.read("provider-settings.json") }
                assertFailsWith<CorruptionException> { state.write("{}".encodeToByteArray(), "provider-settings.json") }
                assertFailsWith<CorruptionException> { settings.setSeedProgress(SeedProgress.NOT_OFFERED) }
            }
            assertEquals(text, Files.readString(path))
            assertFalse(Files.exists(stateDir.resolve("provider-settings.json")))
        }
        val inaccessible = AndroidSettingsStore(object : DataStore<AndroidSettings> {
            override val data: Flow<AndroidSettings> = flow { throw IOException("fixture-only path") }
            override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings = throw IOException("fixture-only path")
        })
        val state = AndroidStateStore(stateDir.toFile(), settings = inaccessible)
        assertEquals(ProviderSettingsError.ReadFailed, ProviderSettingsStore(state).let {
            ProviderSettingsService(it, NoSecretAccess(), Dispatchers.IO).snapshot.readOnlyError
        })
    }

    @Test fun `failed atomic DataStore publication preserves both provider records and seed state`() = runBlocking {
        val current = AndroidSettings(SeedProgress.COMPLETE, mapOf(
            "provider-settings" to SettingsRecord("metadata", "original-incarnation"),
            "provider-state" to SettingsRecord("capability", "other-incarnation")))
        val fake = object : DataStore<AndroidSettings> {
            override val data = MutableStateFlow(current)
            override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings {
                transform(data.value)
                throw IOException("fixture publication failed")
            }
        }
        val state = AndroidStateStore(stateDir.toFile(), settings = AndroidSettingsStore(fake))
        val stamp = state.stamp("provider-settings.json")
        assertFailsWith<StoreError.IOFailure> { state.write("new".encodeToByteArray(), "provider-settings.json") }
        assertEquals(current, fake.data.value)
        assertEquals(stamp, state.stamp("provider-settings.json"))
        assertEquals("metadata", state.read("provider-settings.json").decodeToString())
        assertFalse(Files.exists(stateDir.resolve("provider-settings.json")))
    }

    @Test fun `DataStore flow cancellation reaches Core without poisoning the provider store`() = runBlocking {
        var cancelledRead = false
        var current = AndroidSettings(records = mapOf("provider-settings" to SettingsRecord(
            "{\"version\":1,\"profiles\":[]}", "fixture-incarnation")))
        val fake = object : DataStore<AndroidSettings> {
            override val data: Flow<AndroidSettings> = flow {
                if (cancelledRead) throw CancellationException("fixture cancellation")
                emit(current)
            }
            override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings {
                current = transform(current)
                return current
            }
        }
        val state = AndroidStateStore(stateDir.toFile(), settings = AndroidSettingsStore(fake))
        val service = ProviderSettingsService(ProviderSettingsStore(state), NoSecretAccess(), Dispatchers.IO)
        val before = service.snapshot
        cancelledRead = true
        assertFailsWith<CancellationException> { service.resolveForTesting(ProviderDraft()) }
        assertEquals(before, service.snapshot)
        assertFalse(service.snapshot.isReadOnly)
        cancelledRead = false
        val draft = ProviderDraft()
        service.save(draft)
        assertEquals(draft.id, service.snapshot.settings.selectedProfileID)
    }

    @Test fun `mapped file operations retain incarnation semantics and refuse moves across backends`() = runBlocking {
        withStore { _, state ->
            val path = "provider-settings.json"
            state.create("one".encodeToByteArray(), path)
            val stamp = state.stamp(path)
            assertFailsWith<StoreError.AlreadyExists> { state.create("two".encodeToByteArray(), path) }
            assertEquals(stamp, state.stamp(path))
            assertEquals("one", state.read(path).decodeToString())
            assertFailsWith<StoreError.InvalidPath> { state.move(path, "history/other.json") }
            state.move(path, "provider-state.json")
            assertNull(state.stamp(path))
            assertEquals(stamp, state.stamp("provider-state.json"))
            state.create("one".encodeToByteArray(), path)
            assertNotEquals(stamp, state.stamp(path))
            val next = state.stamp(path)
            state.writePrivate("one".encodeToByteArray(), path)
            assertNotEquals(next, state.stamp(path))
            state.delete(path)
            assertFailsWith<StoreError.NotFound> { state.delete(path) }
            assertFailsWith<StoreError.NotFound> { state.read(path) }
            assertEquals(listOf("provider-state.json"), state.listFiles().map { it.relativePath })
        }
    }

    @Test fun `existing values usage and history still use their original file backend`() = runBlocking {
        withStore { settings, state ->
            for (path in listOf("values.json", "usage/local", "history/local/000001.md")) {
                state.writePrivate(path.encodeToByteArray(), path)
                assertContentEquals(path.encodeToByteArray(), Files.readAllBytes(stateDir.resolve(path)))
            }
            assertTrue(settings.read().records.isEmpty())
            state.move("history/local/000001.md", "history/local/000002.md")
            assertTrue(state.listFiles().any { it.relativePath == "history/local/000002.md" })
        }
    }

    @Test fun `invalid UTF8 publication cannot damage the prior logical record`() = runBlocking {
        withStore { _, state ->
            state.write("kept".encodeToByteArray(), "provider-settings.json")
            assertFailsWith<StoreError.IOFailure> { state.write(byteArrayOf(-1), "provider-settings.json") }
            assertEquals("kept", state.read("provider-settings.json").decodeToString())
        }
    }

    private suspend fun withStore(work: suspend (AndroidSettingsStore, AndroidStateStore) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val settings = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
                produceFile = { filesDir.resolve("datastore/settings.json").toFile() }))
            work(settings, AndroidStateStore(stateDir.toFile(), settings = settings))
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }

    private class NoSecretAccess : SecretStore {
        var calls = 0
        override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? { calls++; error("Unexpected secret access") }
        override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier { calls++; error("Unexpected secret access") }
        override suspend fun delete(account: SecretAccount) { calls++; error("Unexpected secret access") }
    }
}
