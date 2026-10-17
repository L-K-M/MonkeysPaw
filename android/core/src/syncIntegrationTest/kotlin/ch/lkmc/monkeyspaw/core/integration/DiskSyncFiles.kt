package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.SyncHash
import ch.lkmc.monkeyspaw.core.services.LibraryPath
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.data.RootedFileStore
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.*
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.PosixFilePermissions
import java.nio.file.attribute.UserDefinedFileAttributeView
import java.util.UUID

internal fun privateDirectory(path: Path) {
    if (!Files.exists(path, NOFOLLOW_LINKS)) Files.createDirectory(path, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
    scenarioCheck(!Files.isSymbolicLink(path) && Files.isDirectory(path, NOFOLLOW_LINKS), "invalid private directory")
    Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rwx------"))
}

/** Real NIO disk and checked fsync; this does not prove Android Os or power-loss behavior. */
internal class DiskSyncFiles(val root: Path, library: Boolean = false) : StateStore {
    var checkpoint: ((String, String?) -> Unit)? = null
    private val files = RootedFileStore(root.toFile(), if (library) RootedFileStore.Scan.LIBRARY else RootedFileStore.Scan.STATE)
    private val lock = Any()
    var writes = 0
        private set
    var trashCount = 0
        private set
    private val unsafeRetirements = mutableSetOf<String>()
    val unprotectedTrashIDs: Set<String> get() = synchronized(lock) { unsafeRetirements.toSet() }
    private val receipts = mutableMapOf<String, Pair<FileStamp?, SyncHash>>()

    init { privateDirectory(root); files.requireRoot() }
    fun resetMetrics() = synchronized(lock) { writes = 0; trashCount = 0; unsafeRetirements.clear() }
    override fun listFiles(): List<StoredFile> = synchronized(lock) { files.listFiles() }
    override fun stamp(path: String): FileStamp? = synchronized(lock) { files.stamp(path) }
    override fun read(path: String): ByteArray = synchronized(lock) { files.read(path) }
    override fun write(bytes: ByteArray, path: String): Unit = synchronized(lock) { files.write(bytes, path); writes++ }
    override fun writePrivate(bytes: ByteArray, path: String) {
        checkpoint?.invoke("before_private_write", path)
        write(bytes, path)
    }
    override fun create(bytes: ByteArray, path: String): Unit = synchronized(lock) { files.create(bytes, path); writes++ }
    override fun delete(path: String) = synchronized(lock) { checkpoint?.invoke("before_delete", path); files.delete(path) }
    override fun move(source: String, destination: String) = synchronized(lock) { files.move(source, destination) }

    // External fixture writes are independent of the engine's publication metrics.
    fun externalWrite(bytes: ByteArray, path: String) = synchronized(lock) { files.write(bytes, path) }
    fun symlink(path: String, outside: Path) = synchronized(lock) {
        val destination = files.syncPath(path, RootedFileStore.Parents.CREATE) ?: throw StoreError.InvalidPath
        Files.createSymbolicLink(destination, outside)
    }
    // Test-only watcher adapter: match the real publication incarnation and reread its bytes.
    fun ownsChange(path: String, stamp: FileStamp?, hash: SyncHash?): Boolean = synchronized(lock) {
        val receipt = receipts[path] ?: return@synchronized false
        receipt.first == stamp && receipt.second == hash && files.stamp(path) == stamp &&
            SyncHash.of(files.read(path)) == hash
    }
    fun mode(path: String): Set<java.nio.file.attribute.PosixFilePermission> = synchronized(lock) {
        Files.getPosixFilePermissions(regular(path), NOFOLLOW_LINKS)
    }

    val operations: SyncFileOperations = object : SyncFileOperations {
        override fun publish(bytes: ByteArray, path: String, expecting: SyncFileExpectation, mode: SyncFileMode): SyncFilePublication = checked { effect ->
            checkExpected(path, expecting)
            val destination = files.syncPath(path, RootedFileStore.Parents.CREATE) { effect.applied = true } ?: throw StoreError.InvalidPath
            val intended = bytes.copyOf()
            files.staged(intended, destination) { temporary ->
                setPermissions(temporary, mode)
                durable { force(temporary) }
                files.requireRoot()
                effect.displaced = checkExpected(path, expecting)
                when (expecting) {
                    SyncFileExpectation.Absent -> files.publication.create(temporary, destination)
                    is SyncFileExpectation.Matching -> files.publication.replace(temporary, destination)
                }
                effect.applied = true
                writes++
                files.publication.removeTemporary(temporary)
                scenarioCheck(files.read(path).contentEquals(intended), "publication bytes changed")
                flushFile(path)
            }
            flushParents(path)
            receipts[path] = files.stamp(path) to SyncHash.of(intended)
            checkpoint?.invoke("published", path)
            SyncFilePublication(effect.displaced)
        }

        override fun flushFile(path: String) = checked {
            checkpoint?.invoke("before_file_flush", path)
            durable { force(regular(path)) }
        }
        override fun flushDirectory(path: String?) = checked {
            checkpoint?.invoke("before_directory_flush", path)
            durable { force(files.syncDirectory(path)) }
        }
        override fun setMode(mode: SyncFileMode, path: String) = checked { effect ->
            setPermissions(regular(path), mode)
            effect.applied = true
            flushFile(path)
        }
        override fun trash(path: String, expecting: SyncFileExpectation) = checked { effect ->
            effect.displaced = checkExpected(path, expecting) ?: throw StoreError.NotFound
            val id = PromptCodec.parseFile(effect.displaced!!, LibraryPath.filename(path)).frontMatter.id?.rawValue
            if (id != null && files.fullInventory().none { file -> file.relativePath != path &&
                    PromptCodec.parseFile(files.read(file.relativePath), LibraryPath.filename(file.relativePath)).frontMatter.id?.rawValue == id }) {
                unsafeRetirements.add(id)
            }
            Files.delete(regular(path))
            effect.applied = true
            trashCount++
            flushParents(path)
        }
        override fun listFiles(): List<StoredFile> = checked { files.fullInventory() }
        override fun createDirectory(path: String) = checked { effect ->
            val destination = files.syncPath(path, RootedFileStore.Parents.CREATE) { effect.applied = true } ?: throw StoreError.InvalidPath
            Files.createDirectory(destination, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
            effect.applied = true
            directoryIdentity(path)
            flushParents(path)
        }
        override fun renameDirectory(source: String, destination: String) = checked { effect ->
            StorePath.validate(source); StorePath.validate(destination)
            if (destination.startsWith("$source/")) throw StoreError.InvalidPath
            val from = files.syncDirectory(source)
            val to = files.syncPath(destination) ?: throw StoreError.NotFound
            if (Files.exists(to, NOFOLLOW_LINKS)) throw StoreError.AlreadyExists
            files.publication.renameDirectory(from, to)
            effect.applied = true
            flushParents(source); flushParents(destination)
        }
        override fun directories(path: String?): List<String> = checked {
            val directory = files.syncDirectory(path)
            Files.newDirectoryStream(directory).use { children -> children.mapNotNull { child ->
                val attributes = files.attributes(child) ?: throw StoreError.NotFound
                if (attributes.isSymbolicLink) throw StoreError.OutsideRoot
                if (attributes.isDirectory) (path?.plus("/") ?: "") + child.fileName
                else { files.requireRegular(attributes); null }
            }.sortedWith { a, b -> Utf8Order.compare(a.encodeToByteArray(), b.encodeToByteArray()) } }
        }
        override fun directoryIdentity(path: String): FileStamp? = checked {
            val candidate = files.syncPath(path) ?: return@checked null
            if (!Files.exists(candidate, NOFOLLOW_LINKS)) return@checked null
            val directory = files.syncDirectory(path)
            val view = Files.getFileAttributeView(directory, UserDefinedFileAttributeView::class.java, NOFOLLOW_LINKS)
                ?: throw SyncFileOperationError(SyncFileFailureCode.IO_FAILURE)
            val name = "monkeyspaw.sync-incarnation"
            if (name !in view.list()) {
                view.write(name, ByteBuffer.wrap(UUID.randomUUID().toString().encodeToByteArray()))
                durable { force(directory) }
            }
            if (view.size(name) != 36) throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE)
            val buffer = ByteBuffer.allocate(36)
            view.read(name, buffer)
            val token = buffer.array().decodeToString(throwOnInvalidSequence = true)
            if (UUID.fromString(token).toString() != token) throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE)
            FileStamp(token)
        }
        override fun removeEmptyDirectory(path: String, expecting: FileStamp) = checked { effect ->
            if (directoryIdentity(path) != expecting) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
            Files.delete(files.syncDirectory(path))
            effect.applied = true
            flushParents(path)
        }
    }

    private fun checkExpected(path: String, expecting: SyncFileExpectation): ByteArray? {
        val stamp = files.stamp(path)
        when (expecting) {
            SyncFileExpectation.Absent -> if (stamp != null) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
            is SyncFileExpectation.Matching -> if (stamp != expecting.stamp || !files.read(path).contentEquals(expecting.bytes)) {
                throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
            }
        }
        return stamp?.let { files.read(path) }
    }
    private fun regular(path: String): Path {
        files.requireRoot()
        val result = files.syncPath(path) ?: throw StoreError.NotFound
        files.requireRegular(files.attributes(result) ?: throw StoreError.NotFound)
        return result
    }
    private fun setPermissions(path: Path, mode: SyncFileMode) = Files.setPosixFilePermissions(path,
        PosixFilePermissions.fromString(if (mode == SyncFileMode.READ_ONLY) "r--r--r--" else "rw-------"))
    private fun force(path: Path) { FileChannel.open(path, StandardOpenOption.READ, NOFOLLOW_LINKS).use { it.force(true) } }
    private fun flushParents(path: String) {
        var parent = path.substringBeforeLast('/', "").ifEmpty { null }
        while (true) {
            operations.flushDirectory(parent)
            if (parent == null) break
            parent = parent.substringBeforeLast('/', "").ifEmpty { null }
        }
    }
    private class Effect { var applied = false; var displaced: ByteArray? = null }
    private fun <T> checked(block: (Effect) -> T): T = synchronized(lock) {
        val effect = Effect()
        try { files.requireRoot(); block(effect) }
        catch (error: Exception) {
            val code = when (error) {
                is SyncFileOperationError -> error.code
                StoreError.InvalidPath, StoreError.OutsideRoot, StoreError.NotRegularFile -> SyncFileFailureCode.INVALID_PATH
                StoreError.NotFound -> SyncFileFailureCode.NOT_FOUND
                StoreError.AlreadyExists, is FileAlreadyExistsException, is DirectoryNotEmptyException -> SyncFileFailureCode.OCCUPIED
                else -> SyncFileFailureCode.IO_FAILURE
            }
            throw SyncFileOperationError(code,
                if (effect.applied || (error as? SyncFileOperationError)?.effect == SyncFileMutationEffect.APPLIED) SyncFileMutationEffect.APPLIED else SyncFileMutationEffect.UNCHANGED,
                effect.displaced ?: (error as? SyncFileOperationError)?.displacedBytes)
        }
    }
    private fun durable(block: () -> Unit) {
        try { block() } catch (_: Exception) { throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED) }
    }
}
