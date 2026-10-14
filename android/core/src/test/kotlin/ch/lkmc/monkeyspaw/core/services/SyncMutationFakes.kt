package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.ports.*

/** Fault/race capability only; it does not prove native fsync, modes, containment or crash recovery. */
internal class SyncMutationFiles(val files: MemoryStore) : SyncFileOperations {
    val calls = mutableListOf<String>()
    val modes = mutableMapOf<String, SyncFileMode>()
    private val directoryStamps = linkedMapOf<String, FileStamp>()
    private var sequence = 0
    var failAt: Int? = null
    var beforePublish: (() -> Unit)? = null
    var afterCheck: (() -> Unit)? = null
    var afterPublish: (() -> Unit)? = null
    var beforeTrash: (() -> Unit)? = null
    var onOperation: ((String) -> Unit)? = null
    var inventory: (() -> List<StoredFile>)? = null

    fun putDirectory(path: String) {
        StorePath.validate(path)
        directoryStamps[path] = FileStamp("directory-${++sequence}")
        parents(path)
    }

    override fun publish(bytes: ByteArray, path: String, expecting: SyncFileExpectation, mode: SyncFileMode): SyncFilePublication {
        StorePath.validate(path)
        call("publish-check:$path")
        beforePublish?.invoke()
        check(path, expecting)
        afterCheck?.invoke()
        val displaced = SyncDurability.readIfPresent(path, files)
        call("publish-install:$path")
        files.write(bytes, path)
        parents(path)
        modes[path] = mode
        afterPublish?.invoke()
        try {
            call("publish-file-flush:$path", SyncFileMutationEffect.APPLIED, displaced)
            var parent = path.substringBeforeLast('/', "")
            while (parent.isNotEmpty()) {
                call("publish-directory-flush:$parent", SyncFileMutationEffect.APPLIED, displaced)
                parent = parent.substringBeforeLast('/', "")
            }
            call("publish-root-flush", SyncFileMutationEffect.APPLIED, displaced)
        } catch (error: SyncFileOperationError) { throw error }
        return SyncFilePublication(displaced)
    }

    override fun trash(path: String, expecting: SyncFileExpectation) {
        call("trash-check:$path")
        beforeTrash?.invoke()
        check(path, expecting)
        val bytes = files.read(path)
        call("trash-unlink:$path")
        files.delete(path)
        call("trash-parent-flush:$path", SyncFileMutationEffect.APPLIED, bytes)
    }

    override fun setMode(mode: SyncFileMode, path: String) {
        call("mode:$path")
        if (files.stamp(path) == null) throw SyncFileOperationError(SyncFileFailureCode.NOT_FOUND)
        modes[path] = mode
        call("mode-flush:$path", SyncFileMutationEffect.APPLIED)
    }

    override fun flushFile(path: String) {
        call("file:$path")
        if (files.stamp(path) == null) throw SyncFileOperationError(SyncFileFailureCode.NOT_FOUND)
    }
    override fun flushDirectory(path: String?) { call("directory:${path ?: "<root>"}") }
    override fun listFiles(): List<StoredFile> { call("inventory"); return inventory?.invoke() ?: files.listFiles() }
    override fun directories(path: String?): List<String> {
        call("directories:${path ?: "<root>"}")
        files.listFiles().forEach { parents(it.relativePath) }
        return directoryStamps.keys.filter { it.substringBeforeLast('/', "").ifEmpty { null } == path }
    }
    override fun directoryIdentity(path: String): FileStamp? { call("directory-identity:$path"); return directoryStamps[path] }
    override fun createDirectory(path: String) {
        call("create-directory:$path")
        if (path in directoryStamps || files.stamp(path) != null) throw SyncFileOperationError(SyncFileFailureCode.OCCUPIED)
        putDirectory(path)
        flushDirectory(path.substringBeforeLast('/', "").ifEmpty { null })
    }
    override fun renameDirectory(source: String, destination: String) {
        call("rename-directory:$source")
        if (destination in directoryStamps || files.stamp(destination) != null) throw SyncFileOperationError(SyncFileFailureCode.OCCUPIED)
        if (directoryStamps[source] == null) throw SyncFileOperationError(SyncFileFailureCode.NOT_FOUND)
        val directories = directoryStamps.filterKeys { it == source || it.startsWith("$source/") }
        for ((path, stamp) in directories) {
            directoryStamps.remove(path)
            directoryStamps[destination + path.removePrefix(source)] = stamp
        }
        files.listFiles().filter { it.relativePath.startsWith("$source/") }.forEach {
            files.move(it.relativePath, destination + it.relativePath.removePrefix(source))
        }
        flushDirectory(source.substringBeforeLast('/', "").ifEmpty { null })
        flushDirectory(destination.substringBeforeLast('/', "").ifEmpty { null })
    }
    override fun removeEmptyDirectory(path: String, expecting: FileStamp) {
        call("remove-directory:$path")
        if (directoryStamps[path] != expecting) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        if (directoryStamps.keys.any { it.startsWith("$path/") } || files.listFiles().any { it.relativePath.startsWith("$path/") }) {
            throw SyncFileOperationError(SyncFileFailureCode.OCCUPIED)
        }
        directoryStamps.remove(path)
        flushDirectory(path.substringBeforeLast('/', "").ifEmpty { null })
    }

    private fun check(path: String, expecting: SyncFileExpectation) {
        val stamp = files.stamp(path)
        when (expecting) {
            SyncFileExpectation.Absent -> if (stamp != null || path in directoryStamps) throw SyncFileOperationError(SyncFileFailureCode.OCCUPIED)
            is SyncFileExpectation.Matching -> if (stamp != expecting.stamp ||
                !files.read(path).contentEquals(expecting.bytes) || files.stamp(path) != stamp) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        }
    }

    private fun parents(path: String) {
        var parent = path.substringBeforeLast('/', "")
        while (parent.isNotEmpty()) {
            directoryStamps.putIfAbsent(parent, FileStamp("directory-${++sequence}"))
            parent = parent.substringBeforeLast('/', "")
        }
    }

    private fun call(name: String, effect: SyncFileMutationEffect = SyncFileMutationEffect.UNCHANGED, bytes: ByteArray? = null) {
        calls.add(name)
        onOperation?.invoke(name)
        if (calls.size == failAt) throw SyncFileOperationError(
            if (effect == SyncFileMutationEffect.APPLIED) SyncFileFailureCode.DURABILITY_FAILED else SyncFileFailureCode.IO_FAILURE, effect, bytes)
    }
}

internal class SyncMutationHarness {
    val local = ServiceHarness()
    val operations = SyncMutationFiles(local.prompts)
    val mutations = SyncLibraryMutations(local.library, operations)
    fun put(source: String, path: String = "a.md"): SyncLibraryFile {
        local.prompts.put(source, path)
        return mutations.read(path)!!
    }
}
