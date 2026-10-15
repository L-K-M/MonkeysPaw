package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.DataStore
import androidx.datastore.core.Serializer
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import java.io.InputStream
import java.io.OutputStream

/** INSTALLING survives partial installs; K13 must never automatically offer that library again. */
internal enum class SeedProgress { NOT_OFFERED, DECLINED, INSTALLING, COMPLETE }

internal data class SettingsRecord(val payload: String, val stamp: String)

internal data class SyncTlsSettings(val server: SyncServerURL, val trust: SyncTLSTrust = SyncTLSTrust.SYSTEM) {
    fun trustFor(server: SyncServerURL): SyncTLSTrust = if (this.server == server) trust else SyncTLSTrust.SYSTEM
    override fun toString(): String = "<sync TLS settings>"
}

internal sealed class SyncTlsSettingsError private constructor(code: String) : Exception(code, null, false, true) {
    data object ServerChanged : SyncTlsSettingsError("syncServerChanged")
    final override fun toString(): String = message.orEmpty()
}

internal enum class SetupDecision { PENDING, COMPLETE, SKIPPED }

internal data class KeyboardTileSetupProgress(
    val enableKeyboard: SetupDecision = SetupDecision.PENDING,
    val selectKeyboard: SetupDecision = SetupDecision.PENDING,
    val addTile: SetupDecision = SetupDecision.PENDING,
)

internal data class AndroidSettings(
    val seedProgress: SeedProgress = SeedProgress.NOT_OFFERED,
    val records: Map<String, SettingsRecord> = emptyMap(),
    val syncTls: SyncTlsSettings? = null,
    val keyboardTileSetup: KeyboardTileSetupProgress = KeyboardTileSetupProgress(),
)

/** Settings only. Prompt bytes, history, usage and remembered values never enter DataStore. */
internal class AndroidSettingsStore(private val store: DataStore<AndroidSettings>) {
    val data: Flow<AndroidSettings> = store.data.catch { throw sanitized(it) }

    suspend fun read(): AndroidSettings = data.first()

    suspend fun setSeedProgress(progress: SeedProgress): AndroidSettings = try {
        store.updateData { it.copy(seedProgress = progress) }
    } catch (error: Exception) { throw sanitized(error) }

    /** Z19/Z21 select the normalized server before accepting an explicit trust change. */
    suspend fun selectSyncServer(server: SyncServerURL?): AndroidSettings = try {
        store.updateData { current ->
            current.copy(syncTls = if (server == null) null else
                current.syncTls?.takeIf { it.server == server } ?: SyncTlsSettings(server))
        }
    } catch (error: Exception) { throw sanitized(error) }

    suspend fun setSyncTlsTrust(server: SyncServerURL, trust: SyncTLSTrust): AndroidSettings = try {
        store.updateData { current ->
            val selected = current.syncTls?.takeIf { it.server == server } ?: throw SyncTlsSettingsError.ServerChanged
            current.copy(syncTls = selected.copy(trust = trust))
        }
    } catch (error: Exception) { throw sanitized(error) }

    /** The synchronous StateStore bridge calls these only from background IO. */
    suspend fun updateRecords(change: (Map<String, SettingsRecord>) -> Map<String, SettingsRecord>) {
        try { store.updateData { it.copy(records = change(it.records).toMap()) } }
        catch (error: Exception) { throw sanitized(error) }
    }

    suspend fun setKeyboardTileSetup(progress: KeyboardTileSetupProgress): AndroidSettings = try {
        store.updateData { it.copy(keyboardTileSetup = progress) }
    } catch (error: Exception) { throw sanitized(error) }

    private fun sanitized(error: Throwable): Throwable = when (error) {
        is CancellationException -> error
        is StoreError -> error
        is SyncTlsSettingsError -> error
        is CorruptionException -> CorruptionException("Settings are unreadable or use an unsupported version.")
        else -> StoreError.IOFailure
    }
}

/** Optional provider records, sync trust and setup decisions extend version 1 without a migration or read-time rewrite.
 * No corruption handler: malformed or future settings fail closed and keep the original file. */
internal object SettingsSerializer : Serializer<AndroidSettings> {
    override val defaultValue = AndroidSettings()

    override suspend fun readFrom(input: InputStream): AndroidSettings {
        val bytes = input.readBytes()
        return try {
            val text = bytes.decodeToString(throwOnInvalidSequence = true)
            checkStructure(text)
            val root = Json.parseToJsonElement(text) as? JsonObject
                ?: throw IllegalArgumentException()
            if (!root.keys.containsAll(setOf("version", "seedProgress")) ||
                root.keys.any { it !in setOf("version", "seedProgress", "records", "syncTls", "keyboardTileSetup") } || root["version"] != JsonPrimitive(1)) {
                throw IllegalArgumentException()
            }
            val progress = root["seedProgress"] as? JsonPrimitive ?: throw IllegalArgumentException()
            if (!progress.isString) throw IllegalArgumentException()
            val records = if ("records" !in root) emptyMap() else {
                val entries = root["records"] as? JsonObject ?: throw IllegalArgumentException()
                entries.mapValues { (name, value) ->
                    if (name !in providerRecordPaths.values) throw IllegalArgumentException()
                    val record = value as? JsonObject ?: throw IllegalArgumentException()
                    if (record.keys != setOf("payload", "stamp")) throw IllegalArgumentException()
                    val payload = record["payload"] as? JsonPrimitive ?: throw IllegalArgumentException()
                    val stamp = record["stamp"] as? JsonPrimitive ?: throw IllegalArgumentException()
                    if (!payload.isString || !stamp.isString || stamp.content.isEmpty()) throw IllegalArgumentException()
                    payload.content.encodeToByteArray(throwOnInvalidSequence = true)
                    stamp.content.encodeToByteArray(throwOnInvalidSequence = true)
                    SettingsRecord(payload.content, stamp.content)
                }
            }
            val syncTls = if ("syncTls" !in root) null else {
                val option = root["syncTls"] as? JsonObject ?: throw IllegalArgumentException()
                if (option.keys != setOf("serverURL", "trust")) throw IllegalArgumentException()
                val url = option["serverURL"] as? JsonPrimitive ?: throw IllegalArgumentException()
                val trust = option["trust"] as? JsonPrimitive ?: throw IllegalArgumentException()
                if (!url.isString || !trust.isString) throw IllegalArgumentException()
                val server = SyncServerURL(url.content)
                if (server.baseURL != url.content) throw IllegalArgumentException()
                SyncTlsSettings(server, SyncTLSTrust.valueOf(trust.content))
            }
            val setup = if ("keyboardTileSetup" !in root) KeyboardTileSetupProgress() else {
                val record = root["keyboardTileSetup"] as? JsonObject ?: throw IllegalArgumentException()
                require(record.keys == setOf("version", "enableKeyboard", "selectKeyboard", "addTile"))
                require(record["version"] == JsonPrimitive(1))
                KeyboardTileSetupProgress(
                    SetupDecision.valueOf(string(record, "enableKeyboard")),
                    SetupDecision.valueOf(string(record, "selectKeyboard")),
                    SetupDecision.valueOf(string(record, "addTile")),
                )
            }
            AndroidSettings(seedProgress = SeedProgress.valueOf(progress.content), records = records,
                syncTls = syncTls, keyboardTileSetup = setup)
        } catch (_: Exception) {
            throw CorruptionException("Settings are unreadable or use an unsupported version.")
        }
    }

    private fun checkStructure(text: String) {
        var depth = 0
        var quoted = false
        var escaped = false
        for (character in text) {
            if (quoted) {
                if (character.code < 32) throw IllegalArgumentException()
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == '"' -> quoted = false
                }
                continue
            }
            when (character) {
                '"' -> quoted = true
                '[' -> throw IllegalArgumentException() // Supported settings contain no arrays.
                '{' -> if (++depth > 3) throw IllegalArgumentException() // Root, records, record.
                '}' -> if (--depth < 0) throw IllegalArgumentException()
            }
        }
    }

    override suspend fun writeTo(t: AndroidSettings, output: OutputStream) {
        val fields = linkedMapOf<String, JsonElement>("seedProgress" to JsonPrimitive(t.seedProgress.name),
            "version" to JsonPrimitive(1), "keyboardTileSetup" to JsonObject(linkedMapOf(
                "version" to JsonPrimitive(1),
                "enableKeyboard" to JsonPrimitive(t.keyboardTileSetup.enableKeyboard.name),
                "selectKeyboard" to JsonPrimitive(t.keyboardTileSetup.selectKeyboard.name),
                "addTile" to JsonPrimitive(t.keyboardTileSetup.addTile.name),
            )))
        // Omit the optional map on an existing M8 install until the first provider edit.
        if (t.records.isNotEmpty()) fields["records"] = JsonObject(t.records.mapValues { (_, record) ->
            JsonObject(mapOf("payload" to JsonPrimitive(record.payload), "stamp" to JsonPrimitive(record.stamp)))
        })
        t.syncTls?.let { option ->
            fields["syncTls"] = JsonObject(mapOf("serverURL" to JsonPrimitive(option.server.baseURL),
                "trust" to JsonPrimitive(option.trust.name)))
        }
        output.write(JsonObject(fields).toString().encodeToByteArray(throwOnInvalidSequence = true))
    }

    private fun string(record: JsonObject, key: String): String {
        val value = record[key] as? JsonPrimitive ?: throw IllegalArgumentException()
        require(value.isString)
        return value.content
    }
}

internal val providerRecordPaths = mapOf("provider-settings.json" to "provider-settings", "provider-state.json" to "provider-state")
