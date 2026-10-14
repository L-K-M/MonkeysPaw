package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.Serializer
import kotlinx.serialization.json.*
import java.io.InputStream
import java.io.OutputStream

internal data class SecretRecords(val entries: Map<String, SecretEnvelope> = emptyMap()) {
    override fun toString(): String = "<secret records redacted>"
}

/** No corruption handler or reset: malformed/future documents must survive failed operations. */
internal object SecretsSerializer : Serializer<SecretRecords> {
    override val defaultValue = SecretRecords()

    override suspend fun readFrom(input: InputStream): SecretRecords = try {
        val root = Json.parseToJsonElement(input.readBytes().decodeToString(throwOnInvalidSequence = true)) as? JsonObject
            ?: throw IllegalArgumentException()
        require(root.keys == setOf("version", "entries") && root["version"] == JsonPrimitive(SecretEnvelope.VERSION))
        val entries = root["entries"] as? JsonObject ?: throw IllegalArgumentException()
        SecretRecords(entries.mapValues { (_, value) ->
            val record = value as? JsonObject ?: throw IllegalArgumentException()
            require(record.keys == setOf("iv", "ciphertext"))
            fun string(key: String): String = (record[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: throw IllegalArgumentException()
            SecretEnvelope(string("iv"), string("ciphertext"))
        })
    } catch (_: Exception) {
        throw CorruptionException("Secrets are unreadable or use an unsupported version.")
    }

    override suspend fun writeTo(t: SecretRecords, output: OutputStream) {
        val entries = t.entries.mapValues { (_, record) -> JsonObject(linkedMapOf(
            "iv" to JsonPrimitive(record.iv), "ciphertext" to JsonPrimitive(record.ciphertext))) }
        output.write(JsonObject(linkedMapOf("version" to JsonPrimitive(SecretEnvelope.VERSION),
            "entries" to JsonObject(entries))).toString().encodeToByteArray())
    }
}
