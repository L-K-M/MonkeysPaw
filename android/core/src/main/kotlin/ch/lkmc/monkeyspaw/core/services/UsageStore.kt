package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.serialization.json.JsonArray
import java.time.Instant

/** Unix-second JSON events stay in recording order, including repeated and earlier timestamps. */
class UsageStore internal constructor(
    private val files: StateStore,
    private val clock: Clock,
    private val mutations: MutationBoundary,
) : PromptKeyedStore {
    private val cached = mutableMapOf<PromptIdentity, List<Instant>>()
    private val syncWriteGates = SyncKeyedWriteGates()
    internal var onRecord: (PromptIdentity, List<Instant>) -> Unit = { _, _ -> }

    fun useEvents(identity: PromptIdentity): List<Instant> = mutations.run {
        read(path(identity)).also { cached[identity] = it }.toList()
    }

    fun recordUse(identity: PromptIdentity, at: Instant? = null): List<Instant> {
        val events = mutations.run {
            syncWriteGates.requireEditable()
            val path = path(identity)
            val events = (read(path) + (at ?: clock.now())).takeLast(Limits.usageEventCap)
            files.write(StateJson.encode("events", JsonArray(events.map(StateJson::number))), path)
            cached[identity] = events
            events.toList()
        }
        // No store lock enters the index/library boundary, avoiding lock inversion.
        onRecord(identity, events.toList())
        return events
    }

    internal fun cachedEvents(identity: PromptIdentity): List<Instant>? = mutations.run { cached[identity]?.toList() }

    override fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration = mutations.run {
        syncWriteGates.requireEditable()
        val sourcePath = path(source)
        val targetPath = path(destination)
        if (source == destination || files.stamp(sourcePath) == null) return@run KeyMigration.UNCHANGED
        if (files.stamp(targetPath) != null) throw LibraryError.KeyedStateConflict
        try { files.move(sourcePath, targetPath) }
        catch (_: StoreError.AlreadyExists) { throw LibraryError.KeyedStateConflict }
        val events = cached.remove(source)
        if (events != null) cached[destination] = events else cached.remove(destination)
        KeyMigration.MIGRATED
    }

    private fun path(identity: PromptIdentity): String = "usage/" + identity.storageKey

    private fun read(path: String): List<Instant> {
        val bytes = try { files.read(path) } catch (_: StoreError.NotFound) { return emptyList() }
        return decodeEvents(bytes)
    }

    internal val sync: SyncKeyedStore = object : SyncKeyedStore {
        override val syncKind = SyncKeyedStoreKind.USAGE
        override fun bindSyncWriteGate(gate: SyncRecoveryGate) = mutations.run { syncWriteGates.bind(gate) }

        override fun prepareSyncMigration(source: PromptIdentity, destination: PromptIdentity,
                                          rebindingHeadTo: ByteArray?, originalBytes: ByteArray?): List<SyncKeyedMigration> = mutations.run {
            if (source == destination) return@run emptyList()
            val bytes = SyncDurability.readIfPresent(path(source), files) ?: return@run emptyList()
            decodeEvents(bytes)
            if (files.stamp(path(destination)) != null) throw LibraryError.KeyedStateConflict
            listOf(SyncKeyedMigration(syncKind, SyncKeyedMigration.Change.File(
                SyncKeyedFileMove(path(source), path(destination), bytes))))
        }

        override fun applySyncMigration(migration: SyncKeyedMigration, operations: SyncFileFlushing) = mutations.run {
            val move = checkedMove(migration)
            val source = SyncIdentifiers.promptIdentity(move.source.removePrefix("usage/"))
            val destination = SyncIdentifiers.promptIdentity(move.destination.removePrefix("usage/"))
            val events = decodeEvents(move.destinationBytes)
            move.apply(files, operations)
            cached.remove(source)
            cached[destination] = events
        }

        override fun isSyncMigrationUnstarted(migration: SyncKeyedMigration): Boolean = mutations.run {
            checkedMove(migration).isUnstarted(files)
        }

        private fun checkedMove(migration: SyncKeyedMigration): SyncKeyedFileMove {
            migration.validate()
            if (migration.store != syncKind) throw SyncError.InvalidState
            return (migration.change as? SyncKeyedMigration.Change.File)?.move ?: throw SyncError.InvalidState
        }
    }

    internal companion object {
        fun decodeEvents(bytes: ByteArray): List<Instant> {
            if (bytes.size > Limits.syncRecordMaxBytes) throw LibraryError.OperationFailed
            val events = StateJson.read(bytes)["events"] as? JsonArray ?: throw LibraryError.OperationFailed
            if (events.size > Limits.usageEventCap) throw LibraryError.OperationFailed
            return events.map(StateJson::instant)
        }
    }
}
