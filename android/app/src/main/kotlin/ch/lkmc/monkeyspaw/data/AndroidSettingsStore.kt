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
import java.io.InputStream
import java.io.OutputStream

/** INSTALLING survives partial installs; K13 must never automatically offer that library again. */
internal enum class SeedProgress { NOT_OFFERED, DECLINED, INSTALLING, COMPLETE }

internal data class AndroidSettings(val seedProgress: SeedProgress = SeedProgress.NOT_OFFERED)

/** Settings only. Prompt bytes, history, usage and remembered values never enter DataStore. */
internal class AndroidSettingsStore(private val store: DataStore<AndroidSettings>) {
    val data: Flow<AndroidSettings> = store.data.catch { throw sanitized(it) }

    suspend fun read(): AndroidSettings = data.first()

    suspend fun setSeedProgress(progress: SeedProgress): AndroidSettings = try {
        store.updateData { it.copy(seedProgress = progress) }
    } catch (error: Exception) { throw sanitized(error) }

    private fun sanitized(error: Throwable): Throwable = when (error) {
        is CancellationException -> error
        is CorruptionException -> CorruptionException("Settings are unreadable or use an unsupported version.")
        else -> StoreError.IOFailure
    }
}

/** No corruption handler: malformed or future settings fail closed and keep the original file. */
internal object SettingsSerializer : Serializer<AndroidSettings> {
    override val defaultValue = AndroidSettings()

    override suspend fun readFrom(input: InputStream): AndroidSettings {
        val bytes = input.readBytes()
        return try {
            val root = Json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)) as? JsonObject
                ?: throw IllegalArgumentException()
            if (root.keys != setOf("version", "seedProgress") || root["version"] != JsonPrimitive(1)) {
                throw IllegalArgumentException()
            }
            val progress = root["seedProgress"] as? JsonPrimitive ?: throw IllegalArgumentException()
            if (!progress.isString) throw IllegalArgumentException()
            AndroidSettings(SeedProgress.valueOf(progress.content))
        } catch (_: Exception) {
            throw CorruptionException("Settings are unreadable or use an unsupported version.")
        }
    }

    override suspend fun writeTo(t: AndroidSettings, output: OutputStream) {
        output.write(JsonObject(linkedMapOf("seedProgress" to JsonPrimitive(t.seedProgress.name),
            "version" to JsonPrimitive(1))).toString().encodeToByteArray())
    }
}
