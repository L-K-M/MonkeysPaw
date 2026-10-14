package ch.lkmc.monkeyspaw.data

import android.os.Looper
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.UUID

/** Provider records live in the existing settings DataStore. Other state stays in filesDir/state.
 * K11's synchronous port requires a background-only bridge; DataStore runs in its own IO scope.
 * Blocking provider access asserts the worker contract, including Core store construction.
 * Callers and DataStore must not share a single-thread executor.
 * Moves across the two backends are rejected rather than pretending to be atomic.
 */
internal class AndroidStateStore private constructor(private val files: StateStore,
    private val settings: AndroidSettingsStore?, private val isMainThread: () -> Boolean) : StateStore by files {
    constructor(root: File, publication: AtomicPublication = AtomicPublication(), settings: AndroidSettingsStore? = null,
        isMainThread: () -> Boolean = { Looper.myLooper() == Looper.getMainLooper() }) :
        this(RootedFileStore(root, RootedFileStore.Scan.STATE, publication), settings, isMainThread)

    override fun read(path: String): ByteArray {
        val name = providerRecordPaths[path] ?: return files.read(path)
        return records()[name]?.payload?.encodeToByteArray(throwOnInvalidSequence = true) ?: throw StoreError.NotFound
    }

    override fun stamp(path: String): FileStamp? {
        val name = providerRecordPaths[path] ?: return files.stamp(path)
        return records()[name]?.let { FileStamp(it.stamp) }
    }

    override fun listFiles(): List<StoredFile> {
        val local = files.listFiles().filter { it.relativePath !in providerRecordPaths }
        if (settings == null) return local
        val records = records()
        return local + providerRecordPaths.mapNotNull { (path, name) -> records[name]?.let { StoredFile(path, FileStamp(it.stamp)) } }
    }

    override fun write(bytes: ByteArray, path: String) {
        val name = providerRecordPaths[path] ?: return files.write(bytes, path)
        val next = record(bytes)
        update { it + (name to next) }
    }

    override fun writePrivate(bytes: ByteArray, path: String) {
        if (path !in providerRecordPaths) return files.writePrivate(bytes, path)
        write(bytes, path)
    }

    override fun create(bytes: ByteArray, path: String) {
        val name = providerRecordPaths[path] ?: return files.create(bytes, path)
        val next = record(bytes)
        update { current ->
            if (name in current) throw StoreError.AlreadyExists
            current + (name to next)
        }
    }

    override fun delete(path: String) {
        val name = providerRecordPaths[path] ?: return files.delete(path)
        update { current ->
            if (name !in current) throw StoreError.NotFound
            current - name
        }
    }

    override fun move(source: String, destination: String) {
        val from = providerRecordPaths[source]
        val to = providerRecordPaths[destination]
        if (from == null && to == null) return files.move(source, destination)
        if (from == null || to == null) throw StoreError.InvalidPath
        update { current ->
            val value = current[from] ?: throw StoreError.NotFound
            if (to in current) throw StoreError.AlreadyExists
            current - from + (to to value)
        }
    }

    private fun records(): Map<String, SettingsRecord> {
        assertBackgroundThread()
        return runBlocking { requireSettings().read().records }
    }

    private fun update(change: (Map<String, SettingsRecord>) -> Map<String, SettingsRecord>) {
        assertBackgroundThread()
        runBlocking { requireSettings().updateRecords(change) }
    }

    private fun assertBackgroundThread() {
        // Programmer misuse must escape Core's recoverable storage-error handling.
        if (isMainThread()) throw AssertionError("Provider state IO must run off the main thread.")
    }

    private fun requireSettings() = settings ?: throw StoreError.IOFailure

    private fun record(bytes: ByteArray): SettingsRecord = try {
        SettingsRecord(bytes.decodeToString(throwOnInvalidSequence = true), UUID.randomUUID().toString())
    } catch (_: Exception) { throw StoreError.IOFailure }
}
