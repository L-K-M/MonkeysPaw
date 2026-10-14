package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.json.*

internal class ProviderRecordingState(val memory: MemoryStore = MemoryStore()) : StateStore by memory {
    val attemptedWrites = mutableListOf<ByteArray>()
    var failNextWrite = false
    var readError: Exception? = null
    var onAccess: (() -> Unit)? = null

    override fun read(path: String): ByteArray {
        onAccess?.invoke()
        readError?.let { throw it }
        return memory.read(path)
    }

    override fun write(bytes: ByteArray, path: String) {
        onAccess?.invoke()
        attemptedWrites.add(bytes.copyOf())
        if (failNextWrite) {
            failNextWrite = false
            throw StoreError.IOFailure
        }
        memory.write(bytes, path)
    }
}

internal class ProviderFakeSecrets : SecretStore {
    val persisted = mutableMapOf<SecretAccount, StoredSecret>()
    val reads = mutableListOf<Pair<SecretAccount, SecretReadSource>>()
    val writes = mutableListOf<SecretAccount>()
    val deletions = mutableListOf<SecretAccount>()
    var readError: Exception? = null
    var writeError: Exception? = null
    var deleteError: Exception? = null
    var failWriteNumber: Int? = null
    var beforeRead: (suspend () -> Unit)? = null
    var afterWrite: (suspend () -> Unit)? = null
    var onAccess: (() -> Unit)? = null

    override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? {
        onAccess?.invoke()
        reads.add(account to source)
        beforeRead?.invoke()
        readError?.let { throw it }
        return persisted[account]
    }

    override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
        onAccess?.invoke()
        writes.add(account)
        writeError?.let { throw it }
        if (failWriteNumber == writes.size) throw SecretStoreError.WriteFailed
        persisted[account] = StoredSecret(value, SecretTier.KEYSTORE)
        afterWrite?.invoke()
        return SecretTier.KEYSTORE
    }

    override suspend fun delete(account: SecretAccount) {
        onAccess?.invoke()
        deletions.add(account)
        deleteError?.let { throw it }
        persisted.remove(account)
    }
}

internal class ProviderSettingsHarness(val files: ProviderRecordingState = ProviderRecordingState(),
    val secrets: ProviderFakeSecrets = ProviderFakeSecrets(), val io: CoroutineDispatcher = Dispatchers.Unconfined) {
    val store = ProviderSettingsStore(files)
    val service = ProviderSettingsService(store, secrets, io)

    fun reopen() = ProviderSettingsHarness(files, secrets, io)
    fun json() = Json.parseToJsonElement(files.memory.text("provider-settings.json")) as JsonObject
    fun put(root: JsonObject) = files.memory.put(root.toString(), "provider-settings.json")

    fun editProfile(id: ProviderProfileID, change: (MutableMap<String, JsonElement>) -> Unit) {
        val root = json().toMutableMap()
        root["profiles"] = JsonArray((root["profiles"] as JsonArray).map { value ->
            val fields = (value as JsonObject).toMutableMap()
            if (ProviderProfileID.parse((fields["id"] as JsonPrimitive).content) == id) change(fields)
            JsonObject(fields)
        })
        put(JsonObject(root))
    }
}
