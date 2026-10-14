package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import ch.lkmc.monkeyspaw.core.domain.llm.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.security.InvalidKeyException
import java.util.Base64
import java.util.UUID
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec
import kotlin.test.*

/** Real JVM AES-GCM and DataStore; injected keys do not prove AndroidKeyStore or hardware backing. */
internal class AndroidKeystoreSecretStoreTest : TemporaryFiles() {
    private val first = SecretAccount("provider", "first")
    private val second = SecretAccount("device", "first")
    private val third = SecretAccount("provider", "third")
    private val path get() = filesDir.resolve("datastore/secrets.json")

    @Test
    fun `round trip uses fresh IVs and survives store reconstruction without plaintext or key metadata`() = runBlocking {
        val keys = TestKeys(null)
        val value = sentinel()
        val ivs = mutableSetOf<String>()
        withStore(keys) { data, store ->
            assertNull(store.read(first, SecretReadSource.EFFECTIVE))
            repeat(16) {
                assertEquals(SecretTier.KEYSTORE, store.write(value, first))
                assertSecret(value, store.read(first, SecretReadSource.EFFECTIVE))
                val record = data.data.first().entries.getValue(first.rawValue)
                assertTrue(ivs.add(record.iv), "Encryption must use fresh IVs")
                assertEquals(12, Base64.getDecoder().decode(record.iv).size)
                assertEquals(value.withValue { it.encodeToByteArray().size } + 16,
                    Base64.getDecoder().decode(record.ciphertext).size)
                assertNoPlaintext(value, keys.key!!)
                assertEquals("<encrypted secret redacted>", record.toString())
                assertEquals("<secret records redacted>", data.data.first().toString())
            }
        }
        withStore(keys) { _, store -> assertSecret(value, store.read(first, SecretReadSource.PERSISTED)) }
        assertEquals(1, keys.creates)
        val root = Json.parseToJsonElement(Files.readString(path)).jsonObject
        assertEquals(setOf("version", "entries"), root.keys)
        assertEquals(setOf("iv", "ciphertext"), root.getValue("entries").jsonObject.getValue(first.rawValue).jsonObject.keys)
    }

    @Test
    fun `account and namespace swaps reject read and replacement while preserving unrelated accounts`() = runBlocking {
        val keys = TestKeys()
        val value = sentinel()
        withStore(keys) { data, store ->
            store.write(value, first)
            store.write(sentinel(), second)
            store.write(value, third)
            val records = data.data.first().entries
            data.updateData { SecretRecords(records + mapOf(first.rawValue to records.getValue(second.rawValue),
                second.rawValue to records.getValue(first.rawValue))) }
            val bytes = Files.readAllBytes(path)
            for (account in listOf(first, second)) {
                assertError(SecretStoreError.ReadFailed) { store.read(account, SecretReadSource.PERSISTED) }
                assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), account) }
                assertContentEquals(bytes, Files.readAllBytes(path))
            }
            assertSecret(value, store.read(third, SecretReadSource.PERSISTED))
            store.delete(first)
            assertEquals(records.getValue(first.rawValue), data.data.first().entries[second.rawValue])
            assertEquals(records.getValue(third.rawValue), data.data.first().entries[third.rawValue])
        }
    }

    @Test
    fun `ciphertext tag and IV tampering fail without overwrite and Clear does not decrypt`() = runBlocking {
        val keys = TestKeys()
        val value = sentinel()
        withStore(keys) { data, store ->
            store.write(value, first)
            store.write(value, second)
            val records = data.data.first().entries
            val original = records.getValue(first.rawValue)
            fun flip(encoded: String, index: Int): String = Base64.getDecoder().decode(encoded).let { bytes ->
                bytes[index] = (bytes[index].toInt() xor 1).toByte()
                Base64.getEncoder().encodeToString(bytes)
            }
            val last = Base64.getDecoder().decode(original.ciphertext).lastIndex
            for (tampered in listOf(original.copy(ciphertext = flip(original.ciphertext, 0)),
                original.copy(ciphertext = flip(original.ciphertext, last)), original.copy(iv = flip(original.iv, 0)))) {
                data.updateData { SecretRecords(records + (first.rawValue to tampered)) }
                val bytes = Files.readAllBytes(path)
                assertError(SecretStoreError.ReadFailed) { store.read(first, SecretReadSource.EFFECTIVE) }
                assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), first) }
                assertContentEquals(bytes, Files.readAllBytes(path))
                store.delete(first)
                store.delete(first)
                assertNull(store.read(first, SecretReadSource.PERSISTED))
                assertEquals(records.getValue(second.rawValue), data.data.first().entries[second.rawValue])
                assertSecret(value, store.read(second, SecretReadSource.PERSISTED))
            }
        }
        assertEquals(0, keys.creates)
    }

    @Test
    fun `corrupt malformed and future DataStores fail every operation without reset or key access`() = runBlocking {
        val keys = TestKeys()
        withStore(keys) { _, store -> store.write(sentinel(), first) }
        val valid = Json.parseToJsonElement(Files.readString(path)).jsonObject
        val invalid = listOf(byteArrayOf(-1), byteArrayOf(), "bad".encodeToByteArray(),
            JsonObject(valid + ("version" to JsonPrimitive(2))).toString().encodeToByteArray(),
            JsonObject(valid + ("version" to JsonPrimitive("1"))).toString().encodeToByteArray(),
            JsonObject(valid + ("extra" to JsonPrimitive(true))).toString().encodeToByteArray(),
            "{\"version\":1,\"entries\":[]}".encodeToByteArray(),
            "{\"version\":1,\"entries\":{\"provider:first\":{\"iv\":7,\"ciphertext\":\"bad\"}}}".encodeToByteArray(),
            "{\"version\":1,\"entries\":{\"provider:first\":{\"iv\":\"bad\",\"ciphertext\":\"bad\"}}}".encodeToByteArray())
        val reads = keys.reads
        for (bytes in invalid) {
            put(path, bytes)
            withStore(keys) { _, store ->
                assertError(SecretStoreError.ReadFailed) { store.read(first, SecretReadSource.EFFECTIVE) }
                assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), third) }
                assertError(SecretStoreError.DeleteFailed) { store.delete(first) }
            }
            assertContentEquals(bytes, Files.readAllBytes(path))
            withStore(keys) { _, store -> assertError(SecretStoreError.ReadFailed) { store.read(first, SecretReadSource.PERSISTED) } }
            assertContentEquals(bytes, Files.readAllBytes(path))
        }
        assertEquals(reads, keys.reads)
        assertEquals(0, keys.creates)
    }

    @Test
    fun `lost alias never regenerates for retained ciphertext and explicit Clear preserves other accounts`() = runBlocking {
        val keys = TestKeys()
        withStore(keys) { _, store ->
            store.write(sentinel(), first)
            store.write(sentinel(), second)
        }
        keys.key = null
        val bytes = Files.readAllBytes(path)
        withStore(keys) { data, store ->
            assertError(SecretStoreError.Unavailable) { store.read(first, SecretReadSource.PERSISTED) }
            assertError(SecretStoreError.Unavailable) { store.write(sentinel(), first) }
            assertError(SecretStoreError.Unavailable) { store.write(sentinel(), third) }
            assertContentEquals(bytes, Files.readAllBytes(path))
            assertEquals(0, keys.creates)
            val retained = data.data.first().entries.getValue(second.rawValue)
            store.delete(first)
            store.delete(first)
            assertEquals(mapOf(second.rawValue to retained), data.data.first().entries)
            assertError(SecretStoreError.Unavailable) { store.write(sentinel(), first) }
            store.delete(second)
            // All old ciphertext was explicitly cleared; initial creation is safe again.
            val replacement = sentinel()
            store.write(replacement, first)
            assertSecret(replacement, store.read(first, SecretReadSource.EFFECTIVE))
            assertEquals(1, keys.creates)
        }
    }

    @Test
    fun `unusable and locked keys retain records while Clear works without key access`() = runBlocking {
        val keys = TestKeys()
        val original = keys.key
        withStore(keys) { _, store -> store.write(sentinel(), first) }
        val bytes = Files.readAllBytes(path)
        withStore(keys) { _, store ->
            for (failure in listOf(SecretStoreError.Unavailable, SecretStoreError.Locked)) {
                keys.failure = failure
                assertError(failure) { store.read(first, SecretReadSource.EFFECTIVE) }
                assertError(failure) { store.write(sentinel(), first) }
                assertError(failure) { store.write(sentinel(), third) }
                assertContentEquals(bytes, Files.readAllBytes(path))
                assertSame(original, keys.key)
                assertEquals(0, keys.creates)
                assertEquals(0, keys.replacements)
            }
            val reads = keys.reads
            store.delete(third)
            store.delete(first)
            store.delete(first)
            assertEquals(reads, keys.reads)
        }
    }

    @Test
    fun `unusable alias lookup recovers after every ciphertext record is cleared`() = runBlocking {
        val keys = TestKeys()
        val original = keys.key
        val value = sentinel()
        withStore(keys) { data, store ->
            store.write(sentinel(), first)
            store.write(sentinel(), second)
            keys.failure = SecretStoreError.Unavailable
            store.delete(first)
            assertError(SecretStoreError.Unavailable) { store.write(value, third) }
            assertEquals(0, keys.replacements)
            store.delete(second)
            assertTrue(data.data.first().entries.isEmpty())

            assertEquals(SecretTier.KEYSTORE, store.write(value, third))
            assertEquals(1, keys.replacements)
            assertEquals(1, keys.creates)
            assertNotSame(original, keys.key)
            assertSecret(value, store.read(third, SecretReadSource.EFFECTIVE))
            assertNoPlaintext(value, keys.key!!)
        }
        withStore(keys) { _, store -> assertSecret(value, store.read(third, SecretReadSource.PERSISTED)) }
    }

    @Test
    fun `invalid encryption key is replaced when the ciphertext store is empty`() = runBlocking {
        val invalid = SecretKeySpec(byteArrayOf(1), "AES")
        val keys = TestKeys(invalid)
        val value = sentinel()
        assertFailsWith<InvalidKeyException> { SecretEnvelope.seal(value, first, invalid) }
        withStore(keys) { _, store ->
            assertEquals(SecretTier.KEYSTORE, store.write(value, first))
            assertEquals(1, keys.replacements)
            assertEquals(1, keys.creates)
            assertNotSame(invalid, keys.key)
            assertSecret(value, store.read(first, SecretReadSource.EFFECTIVE))
            assertNoPlaintext(value, keys.key!!)
        }
        withStore(keys) { _, store -> assertSecret(value, store.read(first, SecretReadSource.PERSISTED)) }
    }

    @Test
    fun `invalid encryption key with retained ciphertext fails without replacing the alias`() = runBlocking {
        val keys = TestKeys()
        val original = keys.key
        val value = sentinel()
        withStore(keys) { data, store ->
            store.write(value, first)
            val retained = data.data.first().entries
            val bytes = Files.readAllBytes(path)
            val invalid = SecretKeySpec(byteArrayOf(1), "AES")
            keys.key = invalid
            assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), third) }
            assertEquals(retained, data.data.first().entries)
            assertContentEquals(bytes, Files.readAllBytes(path))
            assertSame(invalid, keys.key)
            assertEquals(0, keys.creates)
            assertEquals(0, keys.replacements)
            keys.key = original
            assertSecret(value, store.read(first, SecretReadSource.PERSISTED))
        }
    }

    @Test
    fun `usable alias is reused after clearing every record`() = runBlocking {
        val keys = TestKeys()
        val original = keys.key
        val value = sentinel()
        withStore(keys) { data, store ->
            store.write(sentinel(), first)
            store.delete(first)
            assertTrue(data.data.first().entries.isEmpty())
            assertEquals(SecretTier.KEYSTORE, store.write(value, second))
            assertSame(original, keys.key)
            assertEquals(0, keys.creates)
            assertEquals(0, keys.replacements)
            assertSecret(value, store.read(second, SecretReadSource.PERSISTED))
        }
    }

    @Test
    fun `locked or cancelled lookup never replaces an alias even with no ciphertext`() = runBlocking {
        val keys = TestKeys()
        val original = keys.key
        withStore(keys) { data, store ->
            keys.failure = SecretStoreError.Locked
            assertError(SecretStoreError.Locked) { store.write(sentinel(), first) }
            keys.failure = IOException("lookup failed")
            assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), first) }
            keys.failure = CancellationException("cancelled")
            assertFailsWith<CancellationException> { store.write(sentinel(), first) }
            assertTrue(data.data.first().entries.isEmpty())
            assertSame(original, keys.key)
            assertEquals(0, keys.creates)
            assertEquals(0, keys.replacements)
        }
    }

    @Test
    fun `failed atomic publication preserves prior bytes and unrelated entries after reopening`() = runBlocking {
        val keys = TestKeys()
        val old = sentinel()
        val serializer = FailingPublication()
        withStore(keys, serializer) { _, store ->
            store.write(old, first)
            store.write(old, second)
            val bytes = Files.readAllBytes(path)
            serializer.fail = true
            assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), first) }
            assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), third) }
            assertError(SecretStoreError.DeleteFailed) { store.delete(first) }
            assertContentEquals(bytes, Files.readAllBytes(path))
            assertSecret(old, store.read(first, SecretReadSource.PERSISTED))
            assertSecret(old, store.read(second, SecretReadSource.PERSISTED))
            assertNull(store.read(third, SecretReadSource.EFFECTIVE))
            assertNoPlaintext(old, keys.key!!)
        }
        withStore(keys) { _, store ->
            assertSecret(old, store.read(first, SecretReadSource.PERSISTED))
            assertSecret(old, store.read(second, SecretReadSource.PERSISTED))
            assertNull(store.read(third, SecretReadSource.PERSISTED))
        }
    }

    @Test
    fun `failed first publication keeps generated alias for retry and publishes no secret`() = runBlocking {
        val keys = TestKeys(null)
        val value = sentinel()
        val serializer = FailingPublication().apply { fail = true }
        withStore(keys, serializer) { _, store ->
            assertError(SecretStoreError.WriteFailed) { store.write(value, first) }
            assertFalse(Files.exists(path))
            assertNull(store.read(first, SecretReadSource.PERSISTED))
            assertEquals(1, keys.creates)
            assertNoPlaintext(value, keys.key!!)
            serializer.fail = false
            store.write(value, first)
            assertEquals(1, keys.creates)
            assertSecret(value, store.read(first, SecretReadSource.PERSISTED))
        }
    }

    @Test
    fun `idempotent Clear of absent accounts neither creates a file nor touches keys`() = runBlocking {
        val keys = TestKeys(null)
        withStore(keys) { _, store ->
            repeat(3) { store.delete(first) }
            assertNull(store.read(first, SecretReadSource.PERSISTED))
        }
        assertFalse(Files.exists(path))
        assertEquals(0, keys.reads)
        assertEquals(0, keys.creates)
    }

    @Test
    fun `concurrent saves preserve every unrelated record and key work runs on injected IO`() = runBlocking {
        lateinit var ioThread: Thread
        Executors.newSingleThreadExecutor { Thread(it, "l8-secret-io").also { ioThread = it } }.asCoroutineDispatcher().use { io ->
            val keys = TestKeys(null)
            val value = sentinel()
            withStore(keys, io = io) { data, store ->
                val accounts = (1..12).map { SecretAccount("provider", "account$it") }
                coroutineScope { accounts.map { async { store.write(value, it) } }.awaitAll() }
                for (account in accounts) assertSecret(value, store.read(account, SecretReadSource.PERSISTED))
                val before = data.data.first().entries
                store.write(sentinel(), first)
                store.delete(first)
                assertEquals(before, data.data.first().entries)
                assertEquals(setOf(ioThread), keys.threads)
                assertEquals(1, keys.creates)
            }
        }
    }

    @Test
    fun `driver errors discard diagnostic bodies and cancellation stays cancellation`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val value = sentinel()
        try {
            val data = DataStoreFactory.create(serializer = SecretsSerializer, scope = scope,
                produceFile = { throw IOException(value.withValue { it }) })
            val store = AndroidKeystoreSecretStore(data, TestKeys(), Dispatchers.IO)
            assertError(SecretStoreError.ReadFailed) { store.read(first, SecretReadSource.EFFECTIVE) }
            assertError(SecretStoreError.WriteFailed) { store.write(value, first) }
            assertError(SecretStoreError.DeleteFailed) { store.delete(first) }
        } finally { scope.coroutineContext.job.cancelAndJoin() }

        val keys = TestKeys()
        withStore(keys) { _, store ->
            store.write(value, first)
            keys.failure = IOException(value.withValue { it })
            assertError(SecretStoreError.ReadFailed) { store.read(first, SecretReadSource.EFFECTIVE) }
            assertError(SecretStoreError.WriteFailed) { store.write(value, first) }
            keys.failure = CancellationException("cancelled")
            assertFailsWith<CancellationException> { store.read(first, SecretReadSource.EFFECTIVE) }
            keys.failure = null
            assertSecret(value, store.read(first, SecretReadSource.EFFECTIVE))
        }
    }

    @Test
    fun `device account factories isolate tokens from providers and preserve other accounts through replacement and Clear`() = runBlocking {
        val id = UUID.randomUUID()
        val device = SecretAccount.device(id)
        val provider = SecretAccount("provider", id.toString())
        val otherDevice = SecretAccount.device(UUID.randomUUID())
        val keys = TestKeys()
        val token = sentinel()
        val providerKey = sentinel()
        val otherToken = sentinel()
        withStore(keys) { data, store ->
            assertNotEquals(provider, device)
            store.write(providerKey, provider)
            store.write(token, device)
            store.write(otherToken, otherDevice)
            val preserved = data.data.first().entries.filterKeys { it != device.rawValue }
            val replacement = sentinel()
            store.write(replacement, device)
            assertSecret(replacement, store.read(device, SecretReadSource.PERSISTED))
            assertEquals(preserved, data.data.first().entries.filterKeys { it != device.rawValue })
            for (value in listOf(token, replacement, providerKey, otherToken)) assertNoPlaintext(value, keys.key!!)
            store.delete(device)
            store.delete(device)
            assertEquals(preserved, data.data.first().entries)
        }
        withStore(keys) { _, store ->
            assertNull(store.read(device, SecretReadSource.EFFECTIVE))
            assertSecret(providerKey, store.read(provider, SecretReadSource.PERSISTED))
            assertSecret(otherToken, store.read(otherDevice, SecretReadSource.PERSISTED))
        }
        assertEquals(0, keys.replacements)
    }

    @Test
    fun `missing device alias fails without regenerating and device cleanup preserves provider ciphertext`() = runBlocking {
        val device = SecretAccount.device(UUID.randomUUID())
        val keys = TestKeys()
        val originalKey = keys.key
        val providerKey = sentinel()
        withStore(keys) { _, store ->
            store.write(providerKey, first)
            store.write(sentinel(), device)
        }
        val bytes = Files.readAllBytes(path)
        keys.key = null
        withStore(keys) { data, store ->
            val retained = data.data.first().entries.getValue(first.rawValue)
            assertError(SecretStoreError.Unavailable) { store.read(device, SecretReadSource.PERSISTED) }
            assertError(SecretStoreError.Unavailable) { store.write(sentinel(), device) }
            assertContentEquals(bytes, Files.readAllBytes(path))
            store.delete(device)
            assertEquals(mapOf(first.rawValue to retained), data.data.first().entries)
            assertError(SecretStoreError.Unavailable) { store.write(sentinel(), device) }
            assertEquals(0, keys.creates)
            assertEquals(0, keys.replacements)
        }
        keys.key = originalKey
        withStore(keys) { _, store ->
            assertSecret(providerKey, store.read(first, SecretReadSource.PERSISTED))
            assertNull(store.read(device, SecretReadSource.PERSISTED))
        }
    }

    @Test
    fun `tampered device token fails before replacement and clearing it leaves the provider usable after restart`() = runBlocking {
        val device = SecretAccount.device(UUID.randomUUID())
        val keys = TestKeys()
        val providerKey = sentinel()
        val token = sentinel()
        withStore(keys) { data, store ->
            store.write(providerKey, first)
            store.write(token, device)
            val records = data.data.first().entries
            val original = records.getValue(device.rawValue)
            val tag = Base64.getDecoder().decode(original.ciphertext).apply {
                this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte()
            }
            // A device/provider swap must also reject under the exact namespaced-account AAD.
            for (tampered in listOf(original.copy(ciphertext = Base64.getEncoder().encodeToString(tag)), records.getValue(first.rawValue))) {
                data.updateData { SecretRecords(records + (device.rawValue to tampered)) }
                val bytes = Files.readAllBytes(path)
                assertError(SecretStoreError.ReadFailed) { store.read(device, SecretReadSource.EFFECTIVE) }
                assertError(SecretStoreError.WriteFailed) { store.write(sentinel(), device) }
                assertContentEquals(bytes, Files.readAllBytes(path))
                assertSecret(providerKey, store.read(first, SecretReadSource.PERSISTED))
                store.delete(device)
                assertEquals(mapOf(first.rawValue to records.getValue(first.rawValue)), data.data.first().entries)
            }
            assertNoPlaintext(token, keys.key!!)
            assertNoPlaintext(providerKey, keys.key!!)
        }
        withStore(keys) { _, store ->
            assertSecret(providerKey, store.read(first, SecretReadSource.PERSISTED))
            assertNull(store.read(device, SecretReadSource.PERSISTED))
        }
    }

    private suspend fun withStore(keys: TestKeys, serializer: Serializer<SecretRecords> = SecretsSerializer,
        io: CoroutineDispatcher = Dispatchers.IO, work: suspend (DataStore<SecretRecords>, AndroidKeystoreSecretStore) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + io)
        try {
            val data = DataStoreFactory.create(serializer = serializer, scope = scope, produceFile = { path.toFile() })
            work(data, AndroidKeystoreSecretStore(data, keys, io))
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }

    private fun sentinel(): SecretValue = SecretValue("test-${UUID.randomUUID()}-\"\\é\n/%")

    private fun assertSecret(expected: SecretValue, actual: StoredSecret?) {
        assertTrue(expected == actual?.value, "Credential mismatch")
        assertEquals(SecretTier.KEYSTORE, actual.tier)
    }

    private suspend fun assertError(expected: SecretStoreError, work: suspend () -> Any?) {
        val error = assertFailsWith<SecretStoreError> { work() }
        assertEquals(expected, error)
        assertNull(error.cause)
        assertTrue(error.suppressed.isEmpty())
        assertEquals(expected.message, error.toString())
    }

    private fun assertNoPlaintext(value: SecretValue, key: SecretKey) {
        val variants = value.withValue { raw -> listOf(raw, Base64.getEncoder().encodeToString(raw.encodeToByteArray()),
            java.net.URLEncoder.encode(raw, "UTF-8"), JsonPrimitive(raw).toString().removeSurrounding("\"")) } +
            Base64.getEncoder().encodeToString(key.encoded)
        Files.walk(temporary).use { files -> files.filter(Files::isRegularFile).forEach { file ->
            val text = Files.readAllBytes(file).decodeToString()
            for (variant in variants) assertFalse(text.contains(variant), "Plaintext or key found in persistence")
        } }
    }

    private class TestKeys(var key: SecretKey? = newKey()) : SecretKeyProvider {
        var creates = 0
        var reads = 0
        var replacements = 0
        var failure: Exception? = null
        val threads = mutableSetOf<Thread>()
        override fun read(): SecretKey? {
            reads++
            threads += Thread.currentThread()
            failure?.let { throw it }
            return key
        }
        override fun create(): SecretKey {
            creates++
            failure?.let { throw it }
            return newKey().also { key = it }
        }
        override fun replace(): SecretKey {
            replacements++
            key = null
            failure = null
            return create()
        }
    }

    private class FailingPublication : Serializer<SecretRecords> by SecretsSerializer {
        var fail = false
        override suspend fun writeTo(t: SecretRecords, output: OutputStream) {
            SecretsSerializer.writeTo(t, output)
            if (fail) throw IOException("publication failed")
        }
    }

    companion object {
        private fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    }
}
