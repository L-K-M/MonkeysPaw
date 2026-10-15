package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.SyncError
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncFileFlushing
import kotlinx.serialization.json.JsonPrimitive

/** One store boundary serializes whole-map migration and private read/merge/write. */
class ValuesStore internal constructor(private val files: StateStore, private val mutations: MutationBoundary) : PromptKeyedStore {
    private val syncWriteGates = SyncKeyedWriteGates()
    fun rememberedValues(identity: PromptIdentity): Map<String, String> = mutations.run {
        val key = identity.storageKey
        read()[key]?.toMap() ?: emptyMap()
    }

    /** Empty input does no IO, even on rejected state. Empty strings are real remembered choices. */
    fun record(identity: PromptIdentity, values: Map<String, String>) {
        if (values.isEmpty()) return
        mutations.run {
            syncWriteGates.requireEditable()
            val key = identity.storageKey
            val payload = read().toMutableMap()
            payload[key] = payload[key].orEmpty() + values
            write(payload)
        }
    }

    fun remove(identity: PromptIdentity) = mutations.run {
        syncWriteGates.requireEditable()
        val key = identity.storageKey
        val payload = read().toMutableMap()
        if (payload.remove(key) != null) write(payload)
    }

    /** Forget all bypasses rejected values state once sync recovery no longer owns the graph. */
    fun removeAll() = mutations.run { syncWriteGates.requireEditable(); write(emptyMap()) }

    override fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration = mutations.run {
        syncWriteGates.requireEditable()
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

    internal val sync: SyncKeyedStore = object : SyncKeyedStore {
        override val syncKind = SyncKeyedStoreKind.VALUES
        override fun bindSyncWriteGate(gate: SyncRecoveryGate) = mutations.run { syncWriteGates.bind(gate) }

        override fun prepareSyncMigration(source: PromptIdentity, destination: PromptIdentity,
                                          rebindingHeadTo: ByteArray?, originalBytes: ByteArray?): List<SyncKeyedMigration> = mutations.run {
            if (source == destination) return@run emptyList()
            val payload = read()
            val fields = payload[source.storageKey] ?: return@run emptyList()
            if (destination.storageKey in payload) throw LibraryError.KeyedStateConflict
            listOf(SyncKeyedMigration(syncKind, SyncKeyedMigration.Change.Values(source.storageKey, destination.storageKey, fields)))
        }

        override fun applySyncMigration(migration: SyncKeyedMigration, operations: SyncFileFlushing) = mutations.run {
            val change = checkedChange(migration)
            val payload = read().toMutableMap()
            if (payload[change.source] == null && payload[change.destination] == change.fields) {
                SyncDurability.flushFileAndParents("values.json", operations)
                return@run
            }
            if (payload[change.source] != change.fields || change.destination in payload) throw LibraryError.KeyedStateConflict
            payload.remove(change.source)
            payload[change.destination] = change.fields
            write(payload)
            SyncDurability.flushFileAndParents("values.json", operations)
        }

        override fun isSyncMigrationUnstarted(migration: SyncKeyedMigration): Boolean = mutations.run {
            val change = checkedChange(migration)
            val payload = read()
            payload[change.source] == change.fields && change.destination !in payload
        }

        private fun checkedChange(migration: SyncKeyedMigration): SyncKeyedMigration.Change.Values {
            migration.validate()
            if (migration.store != syncKind) throw SyncError.InvalidState
            return migration.change as? SyncKeyedMigration.Change.Values ?: throw SyncError.InvalidState
        }
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
