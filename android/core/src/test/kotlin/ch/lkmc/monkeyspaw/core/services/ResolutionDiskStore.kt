package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.ports.*
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.READ
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

/** Temp-root JVM port for persisted reconstruction tests, not Android durability proof. */
internal class ResolutionDiskStore(val root: Path) : StateStore, SyncFileOperations {
    val trashed = mutableMapOf<String, ByteArray>()
    var onOperation: ((String) -> Unit)? = null
    var beforeWrite: ((String) -> Unit)? = null
    var beforePublish: ((String) -> Unit)? = null
    var beforeTrash: ((String) -> Unit)? = null
    init { Files.createDirectories(root) }

    private fun path(value: String): Path { StorePath.validate(value); return root.resolve(value) }
    override fun listFiles(): List<StoredFile> = Files.walk(root).use { paths ->
        paths.filter { Files.isRegularFile(it) }.map { file ->
            val relative = root.relativize(file).toString()
            StoredFile(relative, stamp(relative)!!)
        }.toList()
    }
    override fun stamp(path: String): FileStamp? {
        val file = path(path)
        if (!Files.exists(file)) return null
        val attrs = Files.readAttributes(file, BasicFileAttributes::class.java)
        if (!attrs.isRegularFile) throw StoreError.NotRegularFile
        return FileStamp("${attrs.fileKey()}:${attrs.lastModifiedTime()}:${attrs.size()}")
    }
    override fun read(path: String): ByteArray {
        if (stamp(path) == null) throw StoreError.NotFound
        return Files.readAllBytes(path(path))
    }
    override fun write(bytes: ByteArray, path: String) {
        beforeWrite?.invoke(path)
        val target = path(path)
        Files.createDirectories(target.parent)
        val temporary = target.resolveSibling(".${UUID.randomUUID()}")
        try {
            Files.createFile(temporary, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
            Files.write(temporary, bytes)
            Files.move(temporary, target, ATOMIC_MOVE, REPLACE_EXISTING)
        } finally { Files.deleteIfExists(temporary) }
    }
    override fun create(bytes: ByteArray, path: String) {
        beforeWrite?.invoke(path)
        val target = path(path)
        Files.createDirectories(target.parent)
        if (Files.exists(target)) throw StoreError.AlreadyExists
        Files.createFile(target, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        Files.write(target, bytes)
    }
    override fun writePrivate(bytes: ByteArray, path: String) = write(bytes, path)
    override fun delete(path: String) {
        if (!Files.deleteIfExists(path(path))) throw StoreError.NotFound
    }
    override fun move(source: String, destination: String) {
        val target = path(destination)
        Files.createDirectories(target.parent)
        if (Files.exists(target)) throw StoreError.AlreadyExists
        Files.move(path(source), target, ATOMIC_MOVE)
    }
    private fun check(path: String, expecting: SyncFileExpectation) {
        val stamp = stamp(path)
        when (expecting) {
            SyncFileExpectation.Absent -> if (stamp != null) throw SyncFileOperationError(SyncFileFailureCode.OCCUPIED)
            is SyncFileExpectation.Matching -> if (stamp != expecting.stamp || !read(path).contentEquals(expecting.bytes)) {
                throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
            }
        }
    }
    override fun publish(bytes: ByteArray, path: String, expecting: SyncFileExpectation, mode: SyncFileMode): SyncFilePublication {
        beforePublish?.invoke(path)
        check(path, expecting)
        val previous = if (stamp(path) == null) null else read(path)
        write(bytes, path)
        try {
            setMode(mode, path)
            onOperation?.invoke("published:$path")
            flushFile(path)
            flushParents(path)
        } catch (_: Exception) {
            throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED, previous)
        }
        return SyncFilePublication(previous)
    }
    override fun trash(path: String, expecting: SyncFileExpectation) {
        beforeTrash?.invoke(path)
        check(path, expecting)
        trashed[path] = read(path)
        delete(path)
        onOperation?.invoke("trashed:$path")
        flushParents(path)
    }
    override fun setMode(mode: SyncFileMode, path: String) {
        Files.setPosixFilePermissions(path(path), PosixFilePermissions.fromString(if (mode == SyncFileMode.READ_ONLY) "r--r--r--" else "rw-------"))
    }
    override fun flushFile(path: String) { FileChannel.open(path(path), READ).use { it.force(true) } }
    override fun flushDirectory(path: String?) {
        onOperation?.invoke("flush:${path ?: "<root>"}")
        FileChannel.open(path?.let(::path) ?: root, READ).use { it.force(true) }
    }
    private fun flushParents(path: String) {
        var parent = path.substringBeforeLast('/', "")
        while (parent.isNotEmpty()) {
            flushDirectory(parent)
            parent = parent.substringBeforeLast('/', "")
        }
        flushDirectory(null)
    }
    override fun createDirectory(path: String) { Files.createDirectory(path(path)) }
    override fun renameDirectory(source: String, destination: String) = move(source, destination)
    override fun directories(path: String?): List<String> = Files.list(path?.let(::path) ?: root).use { paths ->
        paths.filter { Files.isDirectory(it) }.map { root.relativize(it).toString() }.toList()
    }
    override fun directoryIdentity(path: String): FileStamp? = path(path).let {
        if (Files.isDirectory(it)) FileStamp(Files.readAttributes(it, BasicFileAttributes::class.java).fileKey().toString()) else null
    }
    override fun removeEmptyDirectory(path: String, expecting: FileStamp) {
        if (directoryIdentity(path) != expecting) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        Files.delete(path(path))
    }
}
