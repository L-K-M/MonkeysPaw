package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.*
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermissions

/** No fallback to a non-atomic replacement. This seam also exercises flush/publication failures. */
internal open class AtomicPublication {
    open fun flush(channel: FileChannel) = channel.force(true)

    open fun replace(temporary: Path, destination: Path) {
        Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    open fun create(temporary: Path, destination: Path) {
        Files.createLink(destination, temporary)
    }

    open fun removeTemporary(temporary: Path) {
        Files.deleteIfExists(temporary)
    }

    open fun unlink(path: Path) {
        Files.delete(path)
    }
}

/**
 * Like the Swift driver, component checks defend accidents, not a racing local adversary.
 * All publication stays on one filesystem; there is no cross-root crash transaction.
 * NIO's Unix view supplies inode/device and nanosecond ctime on Android API 26 and the host JVM.
 */
internal class RootedFileStore(
    root: File,
    private val scan: Scan,
    private val publication: AtomicPublication = AtomicPublication(),
) : StateStore {
    enum class Scan { LIBRARY, STATE }
    private enum class Parents { EXISTING, CREATE }

    private val requestedRoot = root.toPath()
    // Resolve trusted system aliases once, off the UI thread, then recheck canonical ancestors.
    private val root: Path by lazy { canonicalRoot() }
    @Volatile private var rootPrepared = false

    fun prepareRoot() = sanitized {
        rootExists(Parents.CREATE)
        rootPrepared = true
    }

    fun requireRoot() = sanitized {
        if (!rootExists(Parents.EXISTING)) throw StoreError.NotFound
    }

    override fun listFiles(): List<StoredFile> = sanitized {
        if (!rootExists(Parents.EXISTING)) {
            if (rootPrepared) throw StoreError.NotFound
            return@sanitized emptyList()
        }
        val result = mutableListOf<StoredFile>()
        collect(root, "", result)
        // Fail before Core commits its rebuilt index, including loss during directory traversal.
        if (rootPrepared) requireRoot()
        result.sortedWith { a, b -> comparePaths(a.relativePath, b.relativePath) }
    }

    override fun stamp(path: String): FileStamp? = sanitized {
        val destination = locate(path, Parents.EXISTING) ?: return@sanitized null
        val attributes = attributes(destination) ?: return@sanitized null
        requireRegular(attributes)
        fileStamp(destination)
    }

    override fun read(path: String): ByteArray = sanitized {
        val destination = locate(path, Parents.EXISTING) ?: throw StoreError.NotFound
        requireRegular(attributes(destination) ?: throw StoreError.NotFound)
        Files.newByteChannel(destination, setOf(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)).use { channel ->
            // Do not decode or normalize here, including invalid UTF-8 and oversized forensic files.
            java.nio.channels.Channels.newInputStream(channel).use { it.readBytes() }
        }
    }

    override fun write(bytes: ByteArray, path: String) = replace(bytes, path)

    override fun writePrivate(bytes: ByteArray, path: String) = replace(bytes, path)

    private fun replace(bytes: ByteArray, path: String) = sanitized {
        val destination = locate(path, Parents.CREATE) ?: throw StoreError.InvalidRoot
        attributes(destination)?.let(::requireRegular)
        stage(bytes, destination) { temporary ->
            attributes(destination)?.let(::requireRegular)
            publication.replace(temporary, destination)
        }
    }

    override fun create(bytes: ByteArray, path: String) = sanitized {
        val destination = locate(path, Parents.CREATE) ?: throw StoreError.InvalidRoot
        // Any occupied leaf, even a dangling link, is a collision. Never open its bytes.
        if (attributes(destination) != null) throw StoreError.AlreadyExists
        stage(bytes, destination) { temporary -> publication.create(temporary, destination) }
    }

    override fun delete(path: String) = sanitized {
        val destination = locate(path, Parents.EXISTING) ?: throw StoreError.NotFound
        requireRegular(attributes(destination) ?: throw StoreError.NotFound)
        Files.delete(destination)
    }

    override fun move(source: String, destination: String) = sanitized {
        StorePath.validate(source)
        StorePath.validate(destination)
        val from = locate(source, Parents.EXISTING) ?: throw StoreError.NotFound
        requireRegular(attributes(from) ?: throw StoreError.NotFound)
        val to = locate(destination, Parents.CREATE) ?: throw StoreError.InvalidRoot
        if (attributes(to) != null) throw StoreError.AlreadyExists
        // ATOMIC_MOVE may replace an occupied leaf, so publish with an exclusive link.
        // A crash before unlink can leave both names for manual recovery.
        publication.create(from, to)
        try {
            publication.unlink(from)
        } catch (error: Exception) {
            try { publication.unlink(to) }
            catch (_: Exception) { throw StoreError.RecoveryRequired }
            throw error
        }
        syncDirectory(from.parent)
        if (from.parent != to.parent) syncDirectory(to.parent)
    }

    private fun stage(bytes: ByteArray, destination: Path, publish: (Path) -> Unit) {
        // Every file is app-private; ordinary prompt/state writes deliberately use 0600 too.
        val permissions = PosixFilePermissions.fromString("rw-------")
        val temporary = Files.createTempFile(destination.parent, ".monkeyspaw-", ".tmp",
            PosixFilePermissions.asFileAttribute(permissions))
        try {
            // Pin 0600 before private bytes, including under a restrictive umask.
            Files.setPosixFilePermissions(temporary, permissions)
            FileChannel.open(temporary, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS).use { channel ->
                val buffer = ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) channel.write(buffer)
                publication.flush(channel)
            }
            publish(temporary)
            syncDirectory(destination.parent)
        } finally {
            // Like Swift's deferred unlink, cleanup cannot report a committed write as failed.
            try { publication.removeTemporary(temporary) } catch (_: Exception) { }
        }
    }

    private fun syncDirectory(directory: Path) {
        // Best effort, like Swift: some filesystems reject directory fsync.
        try { FileChannel.open(directory, StandardOpenOption.READ).use { it.force(true) } }
        catch (_: Exception) { }
    }

    private fun canonicalRoot(): Path {
        if (!requestedRoot.isAbsolute) throw StoreError.InvalidRoot
        val normalized = requestedRoot.normalize()
        if (normalized == normalized.root) throw StoreError.InvalidRoot
        var directory = normalized.root
        normalized.forEachIndexed { index, component ->
            directory = directory.resolve(component)
            val existing = attributes(directory) ?: return@forEachIndexed
            if (index == normalized.nameCount - 1 && existing.isSymbolicLink) throw StoreError.OutsideRoot
            directory = directory.toRealPath()
            if (!attributes(directory)!!.isDirectory) throw StoreError.InvalidRoot
        }
        return directory
    }

    private fun rootExists(parents: Parents): Boolean {
        var directory = root.root
        for (component in root) {
            directory = directory.resolve(component)
            if (!ensureDirectory(directory, parents)) return false
        }
        return true
    }

    private fun locate(path: String, parents: Parents): Path? {
        StorePath.validate(path)
        if (!rootExists(parents)) return null
        val parts = path.split('/')
        var directory = root
        for (part in parts.dropLast(1)) {
            directory = directory.resolve(part)
            if (!ensureDirectory(directory, parents)) return null
        }
        return directory.resolve(parts.last())
    }

    private fun ensureDirectory(directory: Path, parents: Parents): Boolean {
        val existing = attributes(directory)
        if (existing != null) {
            if (existing.isSymbolicLink) throw StoreError.OutsideRoot
            if (!existing.isDirectory) throw StoreError.InvalidRoot
            return true
        }
        if (parents == Parents.EXISTING) return false
        try { Files.createDirectory(directory) }
        catch (_: FileAlreadyExistsException) {
            // Another store can create a shared ancestor; recheck instead of trusting it.
            return ensureDirectory(directory, Parents.EXISTING)
        }
        return true
    }

    private fun collect(directory: Path, prefix: String, result: MutableList<StoredFile>) {
        Files.newDirectoryStream(directory).use { children ->
            for (child in children) {
                val name = child.fileName.toString()
                if (scan == Scan.LIBRARY && name.startsWith('_')) continue
                val attributes = attributes(child) ?: continue
                val path = prefix + name
                when {
                    attributes.isSymbolicLink -> continue
                    attributes.isDirectory -> {
                        if (scan == Scan.LIBRARY && name.startsWith('.')) continue
                        collect(child, "$path/", result)
                    }
                    attributes.isRegularFile -> {
                        if (scan == Scan.LIBRARY && (!name.endsWith(".md") || path == "README.md")) continue
                        StorePath.validate(path)
                        result += StoredFile(path, fileStamp(child))
                    }
                }
            }
        }
    }

    private fun attributes(path: Path): BasicFileAttributes? = try {
        Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    } catch (_: NoSuchFileException) { null }

    private fun requireRegular(attributes: BasicFileAttributes) {
        if (attributes.isSymbolicLink) throw StoreError.OutsideRoot
        if (!attributes.isRegularFile) throw StoreError.NotRegularFile
    }

    private fun fileStamp(path: Path): FileStamp {
        val attributes = Files.readAttributes(path,
            "unix:dev,ino,size,lastModifiedTime,ctime,isRegularFile,isSymbolicLink", LinkOption.NOFOLLOW_LINKS)
        if (attributes.getValue("isSymbolicLink") == true) throw StoreError.OutsideRoot
        if (attributes.getValue("isRegularFile") != true) throw StoreError.NotRegularFile
        return FileStamp(listOf("dev", "ino", "size", "lastModifiedTime", "ctime")
            .joinToString(":") { attributes.getValue(it).toString() })
    }

    private fun comparePaths(left: String, right: String): Int {
        val a = left.encodeToByteArray()
        val b = right.encodeToByteArray()
        for (index in 0 until minOf(a.size, b.size)) {
            val order = (a[index].toInt() and 255) - (b[index].toInt() and 255)
            if (order != 0) return order
        }
        return a.size.compareTo(b.size)
    }

    private fun <T> sanitized(work: () -> T): T = try { work() }
    catch (error: StoreError) { throw error }
    catch (_: FileAlreadyExistsException) { throw StoreError.AlreadyExists }
    catch (_: NoSuchFileException) { throw StoreError.NotFound }
    catch (_: Exception) { throw StoreError.IOFailure }
}
