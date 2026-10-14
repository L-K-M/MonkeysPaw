package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** Share one instance per settings root. Construct off UI; IO and secret edits share the mutex. */
class ProviderSettingsStore(private val files: StateStore) {
    private data class Loaded(val settings: ProviderSettings, val objectValue: JsonObject, val needsRewrite: Boolean)

    private val mutex = Mutex()
    private val path = "provider-settings.json"
    // A UI snapshot must never wait behind a native credential read.
    @Volatile private var cached = ProviderSettingsSnapshot(ProviderSettings())

    init {
        try { cached = ProviderSettingsSnapshot(read().settings) }
        catch (error: Exception) { failClosed(error) }
    }

    internal val snapshot: ProviderSettingsSnapshot get() = cached

    internal suspend fun <T> withSettings(body: suspend (ProviderSettings) -> T): T = mutex.withLock {
        val loaded = loadCurrent()
        cached = ProviderSettingsSnapshot(loaded.settings)
        body(loaded.settings)
    }

    internal suspend fun update(change: suspend (ProviderSettings) -> ProviderSettings,
                                rollback: suspend () -> Unit = {}) = mutex.withLock {
        // Once a compound edit starts, cancellation cannot strand a committed secret
        // between metadata publication and compensation. Queued edits remain cancellable.
        withContext(NonCancellable) {
            val loaded = loadCurrent()
            try {
                val next = change(loaded.settings)
                if (next != loaded.settings || loaded.needsRewrite) write(next, loaded.objectValue)
                cached = ProviderSettingsSnapshot(next)
            } catch (error: Exception) {
                try { rollback() }
                catch (_: Exception) {
                    cached = ProviderSettingsSnapshot(loaded.settings, ProviderSettingsError.SecretRollbackFailed)
                    System.err.println("Provider secret restoration failed.")
                    throw ProviderSettingsError.SecretRollbackFailed
                }
                throw error
            }
        }
    }

    private fun loadCurrent(): Loaded {
        cached.readOnlyError?.let { throw it }
        return try { read() } catch (error: Exception) { throw failClosed(error) }
    }

    private fun read(): Loaded {
        val bytes = try { files.read(path) }
        catch (_: StoreError.NotFound) { return Loaded(ProviderSettings(), JsonObject(emptyMap()), true) }
        catch (_: Exception) { throw ProviderSettingsError.ReadFailed }

        val objectValue: JsonObject
        try {
            objectValue = ProviderSettingsJson.read(bytes)
            val version = ProviderSettingsJson.version(ProviderSettingsJson.firstFields(bytes, "version")["version"])
            if (version > ProviderSettings.currentVersion) throw ProviderSettingsError.FutureVersion(version)
            if (version < ProviderSettings.currentVersion) throw ProviderSettingsError.UnsupportedVersion(version)
        } catch (error: ProviderSettingsError.FutureVersion) { throw error }
        catch (error: ProviderSettingsError.UnsupportedVersion) { throw error }
        catch (_: Exception) { throw ProviderSettingsError.CorruptFile }

        return try {
            if (ProviderSettingsJson.version(objectValue["version"]) != ProviderSettings.currentVersion.toLong()) {
                throw ProviderSettingsError.CorruptFile
            }
            val profiles = objectValue["profiles"] as? JsonArray ?: throw ProviderSettingsError.CorruptFile
            val selected = objectValue["selectedProfileID"].let {
                if (it == null || it == JsonNull) null else ProviderProfileID.parse(ProviderSettingsJson.text(it))
            }
            Loaded(ProviderSettings(profiles.map(::decodeProfile), selected), objectValue, false)
        } catch (_: Exception) { throw ProviderSettingsError.CorruptFile }
    }

    private fun decodeProfile(value: JsonElement): ProviderProfile {
        val profile = value as? JsonObject ?: throw ProviderSettingsError.CorruptFile
        fun text(name: String) = ProviderSettingsJson.text(profile[name])
        val id = ProviderProfileID.parse(text("id"))
        val kind = ProviderKind.entries.firstOrNull { it.rawValue == text("kind") }
            ?: throw ProviderSettingsError.CorruptFile
        val reference = profile["secretReference"].let {
            if (it == null || it == JsonNull) null else SecretAccount.parse(ProviderSettingsJson.text(it))
        }
        return ProviderProfile(id, text("displayName"), kind, text("baseURL"), text("modelID"), reference)
    }

    private fun write(settings: ProviderSettings, original: JsonObject) {
        try {
            val originals = (original["profiles"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
            val profiles = settings.profiles.map { profile ->
                val fields = originals.firstOrNull {
                    ProviderProfileID.parse(ProviderSettingsJson.text(it["id"])) == profile.id
                }?.toMutableMap() ?: mutableMapOf()
                fields["id"] = JsonPrimitive(profile.id.rawValue)
                fields["displayName"] = JsonPrimitive(profile.displayName)
                fields["kind"] = JsonPrimitive(profile.kind.rawValue)
                fields["baseURL"] = JsonPrimitive(profile.baseURL)
                fields["modelID"] = JsonPrimitive(profile.modelID)
                fields["secretReference"] = profile.secretReference?.let { JsonPrimitive(it.rawValue) } ?: JsonNull
                JsonObject(fields)
            }
            val root = original.toMutableMap()
            root["version"] = JsonPrimitive(settings.version)
            root["profiles"] = JsonArray(profiles)
            root["selectedProfileID"] = settings.selectedProfileID?.let { JsonPrimitive(it.rawValue) } ?: JsonNull
            files.write(ProviderSettingsJson.encode(JsonObject(root)), path)
        } catch (_: Exception) {
            System.err.println("Provider settings write failed.")
            throw ProviderSettingsError.WriteFailed
        }
    }

    private fun failClosed(error: Exception): ProviderSettingsError {
        val sanitized = error as? ProviderSettingsError ?: ProviderSettingsError.ReadFailed
        cached = ProviderSettingsSnapshot(ProviderSettings(), sanitized)
        System.err.println("Provider settings read failed; settings are read-only.")
        return sanitized
    }

    override fun toString(): String = "<provider settings store>"
}
