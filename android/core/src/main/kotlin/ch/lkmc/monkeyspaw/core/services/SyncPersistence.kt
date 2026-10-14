package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncFileFlushing
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.serialization.json.*
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal data class SyncStoreSnapshot<T>(val value: T?, val error: SyncError?)

/** One instance per document. The lock owns IO/cache/latches; edit closures must not reenter. */
internal class SyncPersistence<T>(
    private val files: StateStore,
    private val operations: SyncFileFlushing,
    private val path: String,
    private val codec: SyncDocumentCodec<T>,
) {
    private enum class FlushMode { PUBLICATION, DELETION }
    private data class Loaded<T>(val document: T?, val objectValue: SyncObject)
    private val lock = ReentrantLock()
    private var cached = SyncStoreSnapshot<T>(null, null)
    private var hasDocument = false
    private var uncertainFlush: FlushMode? = null

    init { try { load() } catch (_: SyncError) { /* load latched a sanitized error */ } }

    val snapshot: SyncStoreSnapshot<T> get() = lock.withLock { cached }

    fun blockForRecovery(retaining: T?) = lock.withLock {
        cached = SyncStoreSnapshot(retaining, SyncError.DurabilityUncertain)
        uncertainFlush = FlushMode.PUBLICATION
    }

    fun load(): T? = lock.withLock {
        val loaded = loadCurrent()
        cached = SyncStoreSnapshot(loaded.document, null)
        hasDocument = loaded.document != null
        loaded.document
    }

    /** Only explicit replay can revalidate and reflush uncertain publication/deletion. */
    fun recover(validate: (T?) -> Unit = {}): T? = lock.withLock {
        if (cached.error != SyncError.DurabilityUncertain) {
            val loaded = loadCurrent()
            validate(loaded.document)
            cached = SyncStoreSnapshot(loaded.document, null)
            hasDocument = loaded.document != null
            return@withLock loaded.document
        }
        val loaded = try {
            read().also {
                if (uncertainFlush == FlushMode.PUBLICATION && it.document == null) throw SyncError.ReadFailed(StoreError.NotFound)
            }
        } catch (error: SyncError) {
            if (error == SyncError.ReadFailed(StoreError.NotFound) && uncertainFlush == FlushMode.DELETION) {
                Loaded(null, syncObject())
            } else {
                // A transient read or replaced document must not erase the uncertain-durability latch.
                throw error
            }
        }
        validate(loaded.document)
        flush(if (loaded.document == null) FlushMode.DELETION else FlushMode.PUBLICATION)
        cached = SyncStoreSnapshot(loaded.document, null)
        hasDocument = loaded.document != null
        loaded.document
    }

    fun update(change: (T?) -> T): Unit = lock.withLock {
        val loaded = loadCurrent()
        val next = change(loaded.document)
        write(next, loaded.objectValue)
        cached = SyncStoreSnapshot(next, null)
        hasDocument = true
    }

    /** Explicit reset only, after journal/ownership preparation. Never reads an unreadable old file. */
    fun reset(next: T?): Unit = lock.withLock {
        if (next != null) write(next, syncObject())
        else {
            val deleted = try { files.delete(path); true }
            catch (_: StoreError.NotFound) { false }
            catch (error: Exception) { throw SyncError.WriteFailed(error as? StoreError ?: StoreError.IOFailure) }
            if (deleted || hasDocument || cached.error == SyncError.DurabilityUncertain) flush(FlushMode.DELETION)
        }
        cached = SyncStoreSnapshot(next, null)
        hasDocument = next != null
    }

    private fun loadCurrent(): Loaded<T> {
        cached.error?.let { throw it }
        return try { read() } catch (error: SyncError) {
            cached = SyncStoreSnapshot(null, error)
            throw error
        }
    }

    private fun read(): Loaded<T> {
        val bytes = try { files.read(path) }
        catch (_: StoreError.NotFound) {
            if (hasDocument) throw SyncError.ReadFailed(StoreError.NotFound)
            return Loaded(null, syncObject())
        } catch (error: Exception) { throw SyncError.ReadFailed(error as? StoreError ?: StoreError.IOFailure) }
        if (bytes.size > Limits.syncRecordMaxBytes) throw SyncError.CorruptFile
        return try {
            val value = WireJson.parse(bytes).objectValue()
            SyncIdentifiers.version(WireObject(value).long("version"), codec.version)
            Loaded(codec.decode(value), value)
        } catch (error: SyncError) {
            when (error) {
                is SyncError.FutureVersion, is SyncError.UnsupportedVersion -> throw error
                else -> throw SyncError.CorruptFile
            }
        } catch (_: Exception) { throw SyncError.CorruptFile }
    }

    private fun write(next: T, original: SyncObject) {
        val bytes = try {
            val objectValue = merge(codec.encode(next), original)
            val encoded = encode(objectValue)
            if (encoded.size > Limits.syncRecordMaxBytes) throw SyncError.InvalidState
            codec.decode(WireJson.parse(encoded).objectValue())
            encoded
        } catch (_: Exception) { throw SyncError.InvalidState }

        try { files.writePrivate(bytes, path) }
        catch (error: Exception) { throw SyncError.WriteFailed(error as? StoreError ?: StoreError.IOFailure) }
        flush(FlushMode.PUBLICATION)
    }

    private fun flush(mode: FlushMode) {
        try {
            if (mode == FlushMode.PUBLICATION) operations.flushFile(path)
            operations.flushDirectory("sync")
            operations.flushDirectory(null)
        } catch (_: Exception) {
            cached = SyncStoreSnapshot(cached.value, SyncError.DurabilityUncertain)
            uncertainFlush = mode
            throw SyncError.DurabilityUncertain
        }
        uncertainFlush = null
    }

    /** Dynamic maps replace membership; array records retain extensions by exact lexical identity. */
    private fun merge(next: SyncObject, original: SyncObject): SyncObject {
        val maps = setOf("cursors", "groups", "prompts", "favorites", "managed_folders")
        val arrays = mapOf("libraries" to "library_root", "holds" to "path")
        val result = original.fields.toMutableMap()
        next.fields.forEach { (key, value) ->
            val previous = original.fields[key]
            result[key] = when {
                value is SyncObject -> {
                    val old = previous as? SyncObject ?: syncObject()
                    if (key in maps) SyncObject(value.fields.mapValues { (id, item) ->
                        if (item is SyncObject) merge(item, old.fields[id] as? SyncObject ?: syncObject()) else item
                    })
                    else {
                        val retained = if (key == "origin" && value.fields["kind"] == wireString("rescued")) {
                            SyncObject(old.fields - "prompt_id")
                        } else old
                        merge(value, retained)
                    }
                }
                key in arrays && value is WireValue.ArrayValue -> {
                    val identity = arrays.getValue(key)
                    val old = (previous as? WireValue.ArrayValue)?.values.orEmpty().filterIsInstance<SyncObject>()
                    WireValue.ArrayValue(value.values.map { item ->
                        val record = item.objectValue()
                        merge(record, old.firstOrNull { it.fields[identity] == record.fields[identity] } ?: syncObject())
                    })
                }
                else -> value
            }
        }
        return SyncObject(result)
    }

    private fun encode(value: WireValue): ByteArray {
        fun json(item: WireValue): JsonElement = when (item) {
            is WireValue.Text -> JsonPrimitive(item.value.also(WireValidation::scalarCount))
            is WireValue.Number -> JsonPrimitive(item.token.toBigDecimal())
            is WireValue.BooleanValue -> JsonPrimitive(item.value)
            WireValue.Null -> JsonNull
            is WireValue.ArrayValue -> JsonArray(item.values.map(::json))
            is SyncObject -> StateJson.objectOf(item.fields.mapValues { json(it.value) })
        }
        // Foundation JSONSerialization .sortedKeys: compact UTF-8, escaped slashes, no terminal newline.
        return json(value).toString().replace("/", "\\/").encodeToByteArray(throwOnInvalidSequence = true)
    }
}
