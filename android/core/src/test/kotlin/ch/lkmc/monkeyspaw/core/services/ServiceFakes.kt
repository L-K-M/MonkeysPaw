package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Collections

/** Keyed stores have independent locks; protect shared fake state without locking callbacks. */
internal class MemoryStore : StateStore {
    enum class Operation { LIST, STAMP, READ, WRITE, CREATE, PRIVATE_WRITE, MOVE, DELETE }
    private data class File(val bytes: ByteArray, val stamp: FileStamp, val private: Boolean)
    private val files = linkedMapOf<String, File>()
    private val lock = Any()
    private var sequence = 0
    private var accessCount = 0
    val accesses: Int get() = synchronized(lock) { accessCount }
    val reads = Collections.synchronizedList(mutableListOf<String>())
    val writes = Collections.synchronizedList(mutableListOf<String>())
    var onRead: ((String) -> Unit)? = null
    var onWrite: ((String) -> Unit)? = null
    var onCreate: ((String) -> Unit)? = null
    var onMove: ((String, String) -> Unit)? = null
    var onDelete: ((String) -> Unit)? = null
    var onStamp: ((String) -> Unit)? = null
    var fault: ((Operation, String) -> Exception?)? = null

    fun put(text: String, path: String) = put(text.encodeToByteArray(), path)
    fun put(bytes: ByteArray, path: String) = synchronized(lock) {
        files[path] = File(bytes.copyOf(), FileStamp((++sequence).toString()), false)
    }
    fun text(path: String): String = read(path).decodeToString(throwOnInvalidSequence = true)
    fun isPrivate(path: String): Boolean = synchronized(lock) { files[path]?.private == true }
    fun bytesSnapshot(): Map<String, List<Byte>> = synchronized(lock) { files.mapValues { it.value.bytes.toList() } }

    override fun listFiles(): List<StoredFile> {
        access(Operation.LIST, "")
        return synchronized(lock) { files.map { StoredFile(it.key, it.value.stamp) } }
    }
    override fun stamp(path: String): FileStamp? {
        access(Operation.STAMP, path)
        onStamp?.invoke(path)
        return synchronized(lock) { files[path]?.stamp }
    }
    override fun read(path: String): ByteArray {
        access(Operation.READ, path)
        reads.add(path)
        onRead?.invoke(path)
        return synchronized(lock) { files[path]?.bytes?.copyOf() ?: throw StoreError.NotFound }
    }
    override fun write(bytes: ByteArray, path: String) {
        access(Operation.WRITE, path)
        onWrite?.invoke(path)
        publish(bytes, path, false)
    }
    override fun create(bytes: ByteArray, path: String) {
        access(Operation.CREATE, path)
        onCreate?.invoke(path)
        synchronized(lock) { if (path in files) throw StoreError.AlreadyExists }
        onWrite?.invoke(path)
        synchronized(lock) {
            if (path in files) throw StoreError.AlreadyExists
            publish(bytes, path, false)
        }
    }
    override fun writePrivate(bytes: ByteArray, path: String) {
        access(Operation.PRIVATE_WRITE, path)
        onWrite?.invoke(path)
        publish(bytes, path, true)
    }
    override fun delete(path: String) {
        access(Operation.DELETE, path)
        onDelete?.invoke(path)
        synchronized(lock) { if (files.remove(path) == null) throw StoreError.NotFound }
    }
    override fun move(source: String, destination: String) {
        access(Operation.MOVE, source)
        StorePath.validate(destination)
        onMove?.invoke(source, destination)
        synchronized(lock) {
            val moved = files[source] ?: throw StoreError.NotFound
            if (destination in files) throw StoreError.AlreadyExists
            files.remove(source)
            files[destination] = moved
        }
    }
    private fun publish(bytes: ByteArray, path: String, private: Boolean) = synchronized(lock) {
        writes.add(path)
        files[path] = File(bytes.copyOf(), FileStamp((++sequence).toString()), private)
    }
    private fun access(operation: Operation, path: String) {
        synchronized(lock) { accessCount++ }
        if (path.isNotEmpty()) StorePath.validate(path)
        fault?.invoke(operation, path)?.let { throw it }
    }
}

internal class TestClock(var date: Instant = Instant.ofEpochMilli(1234)) : Clock {
    var samples = 0
    override fun now(): Instant { samples++; return date }
}

internal class TestEntropy : Entropy {
    val requests = mutableListOf<Int>()
    var value = ByteArray(10) { it.toByte() }
    var error: Exception? = null
    override fun bytes(count: Int): ByteArray {
        requests.add(count)
        error?.let { throw it }
        return value.copyOf()
    }
}

internal class TestClipboard : Clipboard {
    var reads = 0
    var text: String? = null
    var deferred = false
    var readFailure = false
    var writeFailure = false
    var writeError: Exception? = null
    var pending: ((String?) -> Unit)? = null
    override fun writeText(text: String) {
        if (writeFailure) throw StoreError.IOFailure
        writeError?.let { throw it }
        this.text = text
    }
    override fun readText(completion: (String?) -> Unit) {
        reads++
        if (readFailure) throw StoreError.IOFailure
        if (deferred) pending = completion else completion(text)
    }
}

internal class ServiceHarness(zone: ZoneId = ZoneOffset.UTC, val prompts: MemoryStore = MemoryStore(), val state: MemoryStore = MemoryStore()) {
    val clock = TestClock()
    val entropy = TestEntropy()
    val library = LibraryService(prompts, state, clock, entropy)
    val values get() = library.values
    val usage get() = library.usage
    val history get() = library.history
    val index get() = library.index
    val editing = EditingService(library)
    val clipboard = TestClipboard()
    val fill = FillService(library, clipboard) { zone }
    fun put(source: String, path: String = "a.md"): LibraryEntry {
        prompts.put(source, path)
        return library.load(path)
    }
    fun draft(source: String) = PromptCodec.parse(source, "a.md")
    fun statePath(revision: HistoryRevision) = "history/${revision.identity.storageKey}/${revision.filename}"
}
