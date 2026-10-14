package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.DataStoreFactory
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.coroutines.*
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.test.*

internal class AndroidSettingsStoreTest : TemporaryFiles() {
    @Test
    fun `only versioned seed progress is serialized`() = runBlocking {
        val output = ByteArrayOutputStream()
        SettingsSerializer.writeTo(AndroidSettings(SeedProgress.INSTALLING), output)
        assertEquals("{\"seedProgress\":\"INSTALLING\",\"version\":1}", output.toString(Charsets.UTF_8))
        assertEquals(AndroidSettings(SeedProgress.INSTALLING), SettingsSerializer.readFrom(ByteArrayInputStream(output.toByteArray())))
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

    private suspend fun withStore(work: suspend (AndroidSettingsStore) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
                produceFile = { filesDir.resolve("datastore/settings.json").toFile() })
            work(AndroidSettingsStore(store))
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }
}
