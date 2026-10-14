package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.serialization.json.JsonPrimitive

/** Whole-map migration and private read/merge/write share the library graph's mutation boundary. */
class ValuesStore internal constructor(private val files: StateStore, private val mutations: MutationBoundary) : PromptKeyedStore {
    fun rememberedValues(identity: PromptIdentity): Map<String, String> = mutations.run {
        val key = identity.storageKey
        read()[key]?.toMap() ?: emptyMap()
    }

    /** Empty input does no IO, even on rejected state. Empty strings are real remembered choices. */
    fun record(identity: PromptIdentity, values: Map<String, String>) {
        if (values.isEmpty()) return
        mutations.run {
            val key = identity.storageKey
            val payload = read().toMutableMap()
            payload[key] = payload[key].orEmpty() + values
            write(payload)
        }
    }

    fun remove(identity: PromptIdentity) = mutations.run {
        val key = identity.storageKey
        val payload = read().toMutableMap()
        if (payload.remove(key) != null) write(payload)
    }

    /** Explicit Forget all is recovery: bypass unreadable/corrupt/future/over-cap state. */
    fun removeAll() = mutations.run { write(emptyMap()) }

    override fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration = mutations.run {
        val sourceKey = source.storageKey
        val targetKey = destination.storageKey
        val payload = read().toMutableMap()
        val values = payload[sourceKey]
        if (source == destination || values == null) return@run KeyMigration.UNCHANGED
        if (targetKey in payload) throw LibraryError.KeyedStateConflict
        payload.remove(sourceKey)
        payload[targetKey] = values
        write(payload)
        KeyMigration.MIGRATED
    }

    private fun read(): Map<String, Map<String, String>> {
        val bytes = try { files.read("values.json") } catch (_: StoreError.NotFound) { return emptyMap() }
        if (bytes.size > Limits.valuesFileCapBytes) throw LibraryError.OperationFailed
        val payload = StateJson.fields(StateJson.read(bytes)["values"])
        return payload.mapValues { (_, fields) -> StateJson.fields(fields).mapValues { StateJson.text(it.value) } }
    }

    private fun write(values: Map<String, Map<String, String>>) {
        val maps = StateJson.objectOf(values.mapValues { (_, fields) ->
            StateJson.objectOf(fields.mapValues { JsonPrimitive(it.value) })
        })
        val bytes = StateJson.encode("values", maps)
        if (bytes.size > Limits.valuesFileCapBytes) throw LibraryError.OperationFailed
        files.writePrivate(bytes, "values.json")
    }
}
