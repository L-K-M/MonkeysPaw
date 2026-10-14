package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.Collections

internal enum class SyncKeyedStoreKind(val rawValue: String) { HISTORY("history"), USAGE("usage"), VALUES("values") }

internal interface SyncKeyedStore {
    val syncKind: SyncKeyedStoreKind
    fun bindSyncWriteGate(gate: SyncRecoveryGate)
    fun prepareSyncMigration(source: PromptIdentity, destination: PromptIdentity,
                             rebindingHeadTo: ByteArray? = null, originalBytes: ByteArray? = null): List<SyncKeyedMigration>
    fun applySyncMigration(migration: SyncKeyedMigration, operations: SyncFileFlushing)
    fun isSyncMigrationUnstarted(migration: SyncKeyedMigration): Boolean
}

internal class SyncKeyedMigration(val store: SyncKeyedStoreKind, val change: Change) {
    sealed interface Change {
        class File(val move: SyncKeyedFileMove) : Change
        class Values(val source: String, val destination: String, fields: Map<String, String>) : Change {
            val fields: Map<String, String> = Collections.unmodifiableMap(fields.toMap())
            override fun toString(): String = "<sync values migration>"
        }
    }

    fun validate() {
        when (val change = change) {
            is Change.File -> {
                if (store == SyncKeyedStoreKind.VALUES) throw SyncError.InvalidState
                val move = change.move
                move.validate()
                val prefix = store.rawValue + "/"
                if (!move.source.startsWith(prefix) || !move.destination.startsWith(prefix)) throw SyncError.InvalidState
                val source = move.source.removePrefix(prefix)
                val destination = move.destination.removePrefix(prefix)
                if (store == SyncKeyedStoreKind.HISTORY) {
                    if ('/' !in source || '/' !in destination || source.substringBefore('/') == destination.substringBefore('/') ||
                        source.substringAfter('/') != destination.substringAfter('/')) throw SyncError.InvalidState
                    SyncIdentifiers.promptIdentity(source.substringBefore('/'))
                    SyncIdentifiers.promptIdentity(destination.substringBefore('/'))
                } else {
                    SyncIdentifiers.promptIdentity(source)
                    SyncIdentifiers.promptIdentity(destination)
                    syncValidated { UsageStore.decodeEvents(move.bytes); UsageStore.decodeEvents(move.destinationBytes) }
                }
            }
            is Change.Values -> {
                if (store != SyncKeyedStoreKind.VALUES || change.source == change.destination) throw SyncError.InvalidState
                SyncIdentifiers.promptIdentity(change.source)
                SyncIdentifiers.promptIdentity(change.destination)
            }
        }
    }

    override fun toString(): String = "<sync keyed migration>"
}

/** Destination copy is flushed before source deletion; replay verifies and reflushes both. */
internal class SyncKeyedFileMove(
    val source: String,
    val destination: String,
    bytes: ByteArray,
    destinationBytes: ByteArray = bytes,
    val hash: SyncHash = SyncHash.of(bytes),
    val destinationHash: SyncHash = SyncHash.of(destinationBytes),
) {
    private val saved = SyncBytes(bytes)
    private val savedDestination = SyncBytes(destinationBytes)
    val bytes: ByteArray get() = saved.copyBytes()
    val destinationBytes: ByteArray get() = savedDestination.copyBytes()

    fun validate() {
        syncValidated { StorePath.validate(source); StorePath.validate(destination) }
        if (source == destination || hash != SyncHash.of(bytes) || destinationHash != SyncHash.of(destinationBytes)) throw SyncError.InvalidState
    }

    fun apply(files: StateStore, operations: SyncFileFlushing) {
        validate()
        val old = SyncDurability.readIfPresent(source, files)
        val new = SyncDurability.readIfPresent(destination, files)
        if (old != null && !old.contentEquals(bytes) || new != null && !new.contentEquals(destinationBytes) ||
            old == null && new == null) throw LibraryError.KeyedStateConflict
        if (new == null) files.writePrivate(destinationBytes, destination)
        SyncDurability.flushFileAndParents(destination, operations)
        if (old != null) {
            if (SyncDurability.readIfPresent(source, files)?.contentEquals(bytes) != true) throw LibraryError.KeyedStateConflict
            SyncDurability.flushParents(source, operations)
            files.delete(source)
        }
        SyncDurability.flushParents(source, operations)
    }

    fun isUnstarted(files: StateStore): Boolean {
        validate()
        return SyncDurability.readIfPresent(source, files)?.contentEquals(bytes) == true &&
            SyncDurability.readIfPresent(destination, files) == null
    }

    override fun toString(): String = "<sync keyed file move>"
}

internal object SyncDurability {
    fun readIfPresent(path: String, files: PromptStore): ByteArray? =
        try { files.read(path) } catch (_: StoreError.NotFound) { null }

    fun flushFileAndParents(path: String, operations: SyncFileFlushing) {
        operations.flushFile(path)
        flushParents(path, operations)
    }

    fun flushParents(path: String, operations: SyncFileFlushing) {
        var parent = path.substringBeforeLast('/', "")
        while (parent.isNotEmpty()) {
            operations.flushDirectory(parent)
            parent = parent.substringBeforeLast('/', "")
        }
        operations.flushDirectory(null)
    }
}
