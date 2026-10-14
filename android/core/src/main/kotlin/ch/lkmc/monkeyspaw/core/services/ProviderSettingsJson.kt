package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderSettingsError
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*

/** Foundation's local-state JSON profile, distinct from the strict assistant output grammar. */
internal object ProviderSettingsJson {
    private val numberPattern = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
    private val firstFieldsJson = Json { ignoreUnknownKeys = true }

    fun read(bytes: ByteArray): JsonObject {
        val text = bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF")
        // Bound the recursive parser before it sees untrusted nested metadata.
        var depth = 0
        var quoted = false
        var escaped = false
        for (character in text) {
            if (quoted) {
                if (character.code < 32) throw ProviderSettingsError.CorruptFile
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == '"' -> quoted = false
                }
                continue
            }
            when (character) {
                '"' -> quoted = true
                '{', '[' -> if (++depth > Limits.providerSettingsJSONNestingCap) throw ProviderSettingsError.CorruptFile
                '}', ']' -> if (--depth < 0) throw ProviderSettingsError.CorruptFile
            }
        }
        return (Json.parseToJsonElement(text) as? JsonObject ?: throw ProviderSettingsError.CorruptFile)
            .also(::validate)
    }

    /** JSONDecoder uses the first duplicate; JSONSerialization uses the last.
     * The settings loader checks the first version before decoding the collapsed metadata.
     * Credentials go directly through JSONDecoder and use first values for all known fields.
     */
    fun firstFields(bytes: ByteArray, vararg names: String): JsonObject = firstFieldsJson.decodeFromString(
        FirstFieldsReader(names.toList()), bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF"))

    private class FirstFieldsReader(private val names: List<String>) : KSerializer<JsonObject> {
        override val descriptor = buildClassSerialDescriptor("ProviderSettingsFields") {
            names.forEach { element(it, JsonElement.serializer().descriptor) }
        }

        override fun deserialize(decoder: Decoder): JsonObject {
            val fields = linkedMapOf<String, JsonElement>()
            decoder.decodeStructure(descriptor) {
                while (true) {
                    val index = decodeElementIndex(descriptor)
                    if (index == CompositeDecoder.DECODE_DONE) break
                    val value = decodeSerializableElement(descriptor, index, JsonElement.serializer())
                    fields.putIfAbsent(names[index], value)
                }
            }
            return JsonObject(fields)
        }

        override fun serialize(encoder: Encoder, value: JsonObject) = throw UnsupportedOperationException("Read-only decoder.")
    }

    private fun validate(value: JsonElement) {
        when (value) {
            is JsonObject -> value.forEach { (key, item) ->
                key.encodeToByteArray(throwOnInvalidSequence = true)
                validate(item)
            }
            is JsonArray -> value.forEach(::validate)
            is JsonPrimitive -> {
                if (value.isString) value.content.encodeToByteArray(throwOnInvalidSequence = true)
                else if (value != JsonNull && value.content != "true" && value.content != "false" &&
                    (!numberPattern.matches(value.content) || value.content.toDoubleOrNull()?.isFinite() != true)) {
                    throw ProviderSettingsError.CorruptFile
                }
            }
        }
    }

    fun text(value: JsonElement?): String {
        val primitive = value as? JsonPrimitive ?: throw ProviderSettingsError.CorruptFile
        if (!primitive.isString) throw ProviderSettingsError.CorruptFile
        return primitive.content
    }

    fun version(value: JsonElement?): Long {
        val primitive = value as? JsonPrimitive ?: throw ProviderSettingsError.CorruptFile
        if (primitive.isString) throw ProviderSettingsError.CorruptFile
        return primitive.content.toBigDecimal().longValueExact()
    }

    fun encode(value: JsonObject): ByteArray = sorted(value).toString().replace("/", "\\/")
        .encodeToByteArray(throwOnInvalidSequence = true)

    private fun sorted(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> StateJson.objectOf(value.mapValues { sorted(it.value) })
        is JsonArray -> JsonArray(value.map(::sorted))
        else -> value
    }
}
