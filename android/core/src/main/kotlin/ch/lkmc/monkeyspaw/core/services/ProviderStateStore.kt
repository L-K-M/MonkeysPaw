package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.serialization.json.*
import java.math.BigDecimal
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Share one instance per configuration root; the lock owns IO and observed identities. */
class ProviderStateStore(private val files: StateStore) {
    private data class Entry(val key: ProviderCacheKey, val format: OpenAIResponseFormat)
    // Null entries mean readable corruption; parsed metadata remains available for repair.
    private data class Loaded(val entries: List<Entry>?, val objectValue: JsonObject)

    private val lock = ReentrantLock()
    private val path = "provider-state.json"
    private val observedKeys = mutableMapOf<ProviderProfileID, ProviderCacheKey>()
    private val pendingResets = mutableMapOf<ProviderProfileID, ProviderCacheKey>()
    private val numberPattern = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")

    internal fun format(connection: ProviderConnection): OpenAIResponseFormat = lock.withLock {
        val key = try { key(connection) } catch (_: Exception) {
            warn("Provider capability cache lookup failed.")
            return@withLock OpenAIResponseFormat.JSON_SCHEMA
        }
        val previous = observedKeys.put(key.profileID, key)
        if (previous != null && previous != key) pendingResets[key.profileID] = previous

        val loaded = try { read() } catch (_: Exception) {
            warn("Provider capability cache read failed.")
            return@withLock OpenAIResponseFormat.JSON_SCHEMA
        }
        val entry = loaded.entries?.firstOrNull { it.key.profileID == key.profileID }
            ?: return@withLock OpenAIResponseFormat.JSON_SCHEMA
        if (entry.key == key && key.profileID !in pendingResets) return@withLock entry.format

        // Returning to an old model still resets; future metadata follows the stable profile ID.
        pendingResets[key.profileID] = entry.key
        try {
            write(OpenAIResponseFormat.JSON_SCHEMA, key, loaded)
            pendingResets.remove(key.profileID)
        } catch (_: Exception) { warn("Provider capability cache reset failed.") }
        OpenAIResponseFormat.JSON_SCHEMA
    }

    /** Call only after a lower-format response passes stop checks, recovery and strict validation.
     * Learning is best effort: its IO failure cannot discard the validated action result. */
    internal fun recordSuccess(format: OpenAIResponseFormat, connection: ProviderConnection): Unit = lock.withLock {
        if (format == OpenAIResponseFormat.JSON_SCHEMA) return@withLock
        try {
            // Never replace unreadable state; retry reading on the next action.
            val loaded = read()
            val key = key(connection)
            if (observedKeys[key.profileID] != key) return@withLock
            val entry = loaded.entries?.firstOrNull { it.key.profileID == key.profileID }
            if (entry != null) {
                val resetPending = entry.key != key && pendingResets[key.profileID] == entry.key
                if (entry.key != key && !resetPending) return@withLock
                // Out-of-order success must not forget a format already rejected by another action.
                if (!resetPending && (entry.format == OpenAIResponseFormat.NONE || entry.format == format)) return@withLock
            }
            write(format, key, loaded)
            pendingResets.remove(key.profileID)
        } catch (_: Exception) { warn("Provider capability cache update failed.") }
    }

    private fun key(connection: ProviderConnection): ProviderCacheKey {
        if (connection.modelID.trimProviderWhitespace().isEmpty() || connection.modelID.hasControls()) {
            throw ProviderSettingsError.InvalidProfile
        }
        return ProviderCacheKey(connection.profileID, connection.kind,
            ProviderSettings.normalizeBaseURL(connection.baseURL, connection.kind), connection.modelID)
    }

    private fun read(): Loaded {
        val bytes = try { files.read(path) }
        catch (_: StoreError.NotFound) { return Loaded(emptyList(), JsonObject(emptyMap())) }
        catch (_: Exception) { throw ProviderSettingsError.ReadFailed }

        val objectValue = try {
            val text = bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF")
            checkDepth(text)
            (Json.parseToJsonElement(text) as? JsonObject)?.also(::validateJson)
        } catch (_: Exception) { null } ?: JsonObject(emptyMap())
        val entries = try {
            val version = objectValue["version"] as? JsonPrimitive ?: throw ProviderSettingsError.CorruptFile
            if (version.isString || version.content.toBigDecimalOrNull()?.compareTo(BigDecimal.ONE) != 0) {
                throw ProviderSettingsError.CorruptFile
            }
            val profiles = objectValue["profiles"] as? JsonArray ?: throw ProviderSettingsError.CorruptFile
            profiles.map { decodeEntry(StateJson.fields(it)) }.also { entries ->
                if (entries.map { it.key.profileID }.toSet().size != entries.size) throw ProviderSettingsError.CorruptFile
            }
        } catch (_: Exception) { null }
        return Loaded(entries, objectValue)
    }

    private fun checkDepth(text: String) {
        // Bound the recursive tree reader before parsing; brackets in strings do not count.
        var depth = 0
        var quoted = false
        var escaped = false
        for (character in text) {
            if (quoted) {
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == '"' -> quoted = false
                }
                continue
            }
            when (character) {
                '"' -> quoted = true
                '{', '[' -> {
                    depth++
                    if (depth > Limits.providerStateJSONNestingCap) throw ProviderSettingsError.CorruptFile
                }
                '}', ']' -> {
                    depth--
                    if (depth < 0) throw ProviderSettingsError.CorruptFile
                }
            }
        }
    }

    private fun validateJson(value: JsonElement) {
        when (value) {
            is JsonObject -> value.forEach { (key, item) ->
                key.encodeToByteArray(throwOnInvalidSequence = true)
                validateJson(item)
            }
            is JsonArray -> value.forEach(::validateJson)
            is JsonPrimitive -> {
                // JsonElement parsing accepts bare NaN/01 tokens; Foundation rejects them.
                if (value.isString) value.content.encodeToByteArray(throwOnInvalidSequence = true)
                else if (value != JsonNull && value.content != "true" && value.content != "false" &&
                    !numberPattern.matches(value.content)) throw ProviderSettingsError.CorruptFile
            }
        }
    }

    private fun decodeEntry(objectValue: JsonObject): Entry {
        fun text(name: String): String = StateJson.text(objectValue[name] ?: throw ProviderSettingsError.CorruptFile)
        val id = ProviderProfileID.parse(text("id"))
        val kind = text("kind").let { raw -> ProviderKind.entries.firstOrNull { it.rawValue == raw } }
            ?: throw ProviderSettingsError.CorruptFile
        val base = ProviderSettings.normalizeBaseURL(text("baseURL"), kind)
        val model = text("modelID")
        if (model.trimProviderWhitespace().isEmpty() || model.hasControls()) throw ProviderSettingsError.CorruptFile
        val format = text("format").let { raw -> OpenAIResponseFormat.entries.firstOrNull { it.rawValue == raw } }
            ?: throw ProviderSettingsError.CorruptFile
        return Entry(ProviderCacheKey(id, kind, base, model), format)
    }

    private fun write(format: OpenAIResponseFormat, key: ProviderCacheKey, loaded: Loaded) {
        val objectValue = loaded.objectValue.toMutableMap()
        val originals = (objectValue["profiles"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
        val index = originals.indexOfFirst {
            val id = try { ProviderProfileID.parse(StateJson.text(it["id"] ?: JsonNull)) } catch (_: Exception) { null }
            id == key.profileID
        }
        val entry = originals.getOrNull(index)?.toMutableMap() ?: mutableMapOf()
        entry["id"] = JsonPrimitive(key.profileID.rawValue)
        entry["kind"] = JsonPrimitive(key.kind.rawValue)
        entry["baseURL"] = JsonPrimitive(key.baseURL)
        entry["modelID"] = JsonPrimitive(key.modelID)
        entry["format"] = JsonPrimitive(format.rawValue)
        val profiles = if (loaded.entries == null) mutableListOf() else originals.toMutableList()
        if (index >= 0 && loaded.entries != null) profiles[index] = JsonObject(entry)
        else profiles.add(JsonObject(entry))
        objectValue["version"] = JsonPrimitive(1)
        objectValue["profiles"] = JsonArray(profiles)

        try {
            // Foundation's JSONSerialization escapes slashes and emits compact UTF-8 without a newline.
            val bytes = sorted(JsonObject(objectValue)).toString().replace("/", "\\/")
                .encodeToByteArray(throwOnInvalidSequence = true)
            files.write(bytes, path)
        } catch (_: Exception) { throw ProviderSettingsError.WriteFailed }
    }

    private fun sorted(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> StateJson.objectOf(value.mapValues { sorted(it.value) })
        is JsonArray -> JsonArray(value.map(::sorted))
        else -> value
    }

    private fun warn(message: String) { System.err.println(message) }

    override fun toString(): String = "<provider capability state>"
}
