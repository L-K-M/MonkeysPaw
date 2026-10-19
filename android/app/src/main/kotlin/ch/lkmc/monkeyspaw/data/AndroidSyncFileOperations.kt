package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*
import java.nio.file.*
import java.util.UUID

/** Checked capability over the associated store, serialized by the caller's library boundary.
 * Rechecks protect cooperating writers, not a malicious process racing the final native call.
 */
internal class AndroidSyncFileOperations(
    private val files: RootedFileStore,
    private val io: CheckedSyncIO,
) : SyncFileOperations {
    private var rootIdentity: FileStamp? = null
    private class DirectoryIdentity(val stamp: FileStamp, val created: Boolean) {
        val effect get() = if (created) SyncFileMutationEffect.APPLIED else SyncFileMutationEffect.UNCHANGED
    }

    override fun publish(bytes: ByteArray, path: String, expecting: SyncFileExpectation,
                         mode: SyncFileMode): SyncFilePublication = checked { effect ->
        val intended = bytes.copyOf()
        StorePath.validate(path)
        requireRoot()
        check(path, expecting)
        val destination = files.syncPath(path, RootedFileStore.Parents.CREATE) { effect.applied = true }
            ?: throw StoreError.NotFound
        files.staged(intended, destination) { temporary ->
            io.setMode(temporary, mode)
            durable { io.flushFile(temporary) }
            io.beforeMutation(CheckedSyncIO.Mutation.PUBLISH, path)
            requireRoot()
            requirePath(path, destination)
            effect.displaced = check(path, expecting)
            val stagedIdentity = files.nodeIdentity(temporary)
            try {
                when (expecting) {
                    SyncFileExpectation.Absent -> files.publication.create(temporary, destination)
                    is SyncFileExpectation.Matching -> files.publication.replace(temporary, destination)
                }
                effect.applied = true
            } catch (error: Exception) {
                effect.observeFailure {
                    // Both publication modes consume staging, even if a later writer removes the result.
                    files.attributes(temporary) == null ||
                        files.attributes(destination)?.isRegularFile == true && files.nodeIdentity(destination) == stagedIdentity
                }
                throw error
            }
            if (!readStable(path).contentEquals(intended)) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
            // A consumed staging name makes cleanup a no-op after either publication mode.
            files.publication.removeTemporary(temporary)
            flushFile(path)
        }
        flushParents(path)
        SyncFilePublication(effect.displaced)
    }

    override fun flushFile(path: String) = checked {
        StorePath.validate(path)
        requireRoot()
        val destination = regular(path)
        durable { io.flushFile(destination) }
    }

    override fun flushDirectory(path: String?) = checked {
        path?.let(StorePath::validate)
        requireRoot()
        val directory = files.syncDirectory(path)
        durable { io.flushDirectory(directory) }
    }

    override fun setMode(mode: SyncFileMode, path: String) = checked { effect ->
        StorePath.validate(path)
        requireRoot()
        regular(path)
        val stamp = files.stamp(path)
        io.beforeMutation(CheckedSyncIO.Mutation.MODE, path)
        requireRoot()
        if (files.stamp(path) != stamp) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        io.setMode(regular(path), mode)
        effect.applied = true
        flushFile(path)
    }

    override fun trash(path: String, expecting: SyncFileExpectation) = checked { effect ->
        StorePath.validate(path)
        requireRoot()
        check(path, expecting) ?: throw StoreError.NotFound
        io.beforeMutation(CheckedSyncIO.Mutation.TRASH, path)
        requireRoot()
        // The journal owns durable raw retention before admission to this checked unlink.
        effect.displaced = check(path, expecting) ?: throw StoreError.NotFound
        val destination = regular(path)
        try { files.publication.unlink(destination); effect.applied = true }
        catch (error: Exception) {
            effect.observeFailure { files.attributes(destination) == null }
            throw error
        }
        flushParents(path)
    }

    override fun listFiles(): List<StoredFile> = checked {
        requireRoot()
        files.fullInventory().also { requireRoot() }
    }

    override fun createDirectory(path: String) = checked { effect ->
        StorePath.validate(path)
        requireRoot()
        if (files.syncPath(path)?.let(files::attributes) != null) throw StoreError.AlreadyExists
        io.beforeMutation(CheckedSyncIO.Mutation.CREATE_DIRECTORY, path)
        requireRoot()
        val destination = files.syncPath(path, RootedFileStore.Parents.CREATE) { effect.applied = true }
            ?: throw StoreError.NotFound
        Files.createDirectory(destination)
        effect.applied = true
        directoryStamp(path)
        flushParents(path)
    }

    override fun renameDirectory(source: String, destination: String) = checked { effect ->
        StorePath.validate(source)
        StorePath.validate(destination)
        if (destination.startsWith("$source/")) throw StoreError.InvalidPath
        requireRoot()
        val identity = directoryStamp(source) ?: throw StoreError.NotFound
        val from = files.syncDirectory(source)
        // Existing parents only. Files.move without REPLACE_EXISTING refuses occupied leaves.
        vacant(destination)
        io.beforeMutation(CheckedSyncIO.Mutation.RENAME_DIRECTORY, destination)
        requireRoot()
        if (directoryStamp(source) != identity) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        val to = vacant(destination)
        try { files.publication.renameDirectory(from, to); effect.applied = true }
        catch (error: Exception) {
            effect.observeFailure { files.attributes(from) == null }
            throw error
        }
        if (directoryStamp(destination) != identity) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        flushParents(source)
        flushParents(destination)
    }

    override fun directories(path: String?): List<String> = checked {
        path?.let(StorePath::validate)
        requireRoot()
        val directory = files.syncDirectory(path)
        val identity = files.nodeIdentity(directory)
        val result = mutableListOf<String>()
        Files.newDirectoryStream(directory).use { children ->
            for (child in children) {
                val relative = if (path == null) child.fileName.toString() else "$path/${child.fileName}"
                StorePath.validate(relative)
                val attributes = files.attributes(child) ?: throw StoreError.NotFound
                if (attributes.isSymbolicLink) throw StoreError.OutsideRoot
                if (attributes.isDirectory) result.add(relative) else files.requireRegular(attributes)
            }
        }
        requireRoot()
        if (files.nodeIdentity(files.syncDirectory(path)) != identity) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        result.sortedWith(files::comparePaths)
    }

    override fun directoryIdentity(path: String): FileStamp? = checked {
        StorePath.validate(path)
        requireRoot()
        directoryStamp(path)
    }

    override fun removeEmptyDirectory(path: String, expecting: FileStamp) = checked { effect ->
        StorePath.validate(path)
        requireRoot()
        if (directoryStamp(path) != expecting) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        io.beforeMutation(CheckedSyncIO.Mutation.REMOVE_DIRECTORY, path)
        requireRoot()
        if (directoryStamp(path) != expecting) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        Files.delete(files.syncDirectory(path)) // rmdir is empty-only, including hidden/unowned entries.
        effect.applied = true
        flushParents(path)
    }

    @Synchronized private fun requireRoot() {
        val root = files.syncDirectory(null)
        val identity = identity(root)
        if (rootIdentity != null && rootIdentity != identity.stamp) throw StoreError.InvalidRoot
        if (rootIdentity == null) {
            // Establish the marker before an inventory can authorize deletion inference.
            durable(identity.effect) { files.rootDurabilityDirectories().forEach(io::flushDirectory) }
            rootIdentity = identity.stamp
        }
    }

    private fun directoryStamp(path: String): FileStamp? {
        val directory = files.syncPath(path) ?: return null
        if (files.attributes(directory) == null) return null
        files.syncDirectory(path)
        val identity = identity(directory)
        durable(identity.effect) { io.flushDirectory(directory) }
        if (files.syncDirectory(path) != directory || identity(directory).stamp != identity.stamp) {
            throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        }
        return identity.stamp
    }

    private fun identity(directory: Path): DirectoryIdentity {
        val before = files.nodeIdentity(directory)
        val token = io.directoryToken(directory)
        val valid = try { UUID.fromString(token.value).toString() == token.value } catch (_: IllegalArgumentException) { false }
        if (!valid) throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE)
        if (files.nodeIdentity(directory) != before) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        return DirectoryIdentity(files.nodeIdentity(directory, token.value), token.created)
    }

    private fun regular(path: String): Path {
        val destination = files.syncPath(path) ?: throw StoreError.NotFound
        files.requireRegular(files.attributes(destination) ?: throw StoreError.NotFound)
        return destination
    }

    private fun vacant(path: String): Path {
        val destination = files.syncPath(path) ?: throw StoreError.NotFound
        if (files.attributes(destination) != null) throw StoreError.AlreadyExists
        return destination
    }

    private fun requirePath(path: String, expected: Path) {
        if (files.syncPath(path) != expected) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
    }

    private fun check(path: String, expecting: SyncFileExpectation): ByteArray? {
        val destination = files.syncPath(path)
        val attributes = destination?.let(files::attributes)
        if (expecting == SyncFileExpectation.Absent) {
            if (attributes != null) throw StoreError.AlreadyExists
            return null
        }
        expecting as SyncFileExpectation.Matching
        if (attributes == null) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        files.requireRegular(attributes)
        if (files.stamp(path) != expecting.stamp) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        val bytes = readStable(path)
        if (!bytes.contentEquals(expecting.bytes) || files.stamp(path) != expecting.stamp) {
            throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        }
        return bytes
    }

    private fun readStable(path: String): ByteArray {
        val before = files.stamp(path) ?: throw StoreError.NotFound
        val bytes = files.read(path)
        if (files.stamp(path) != before) throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
        return bytes
    }

    private fun flushParents(path: String) {
        var parent = path.substringBeforeLast('/', "").ifEmpty { null }
        while (true) {
            flushDirectory(parent)
            parent = parent?.substringBeforeLast('/', "")?.ifEmpty { null } ?: break
        }
        // A nested operation must also reflush a root left uncertain by an earlier attempt.
        if ('/' in path) flushDirectory(null)
    }

    private class Effect {
        var applied = false
        var displaced: ByteArray? = null

        fun observeFailure(probe: () -> Boolean) {
            // Failed inspection cannot establish unchanged state or replace the original failure.
            if (!applied) applied = try { probe() } catch (_: Exception) { true }
        }
    }

    private fun <T> checked(work: (Effect) -> T): T {
        val effect = Effect()
        try { return work(effect) }
        catch (error: Exception) {
            val code = when (error) {
                is SyncFileOperationError -> error.code
                StoreError.InvalidPath, StoreError.OutsideRoot, StoreError.InvalidRoot, StoreError.NotRegularFile -> SyncFileFailureCode.INVALID_PATH
                StoreError.NotFound, is NoSuchFileException -> SyncFileFailureCode.NOT_FOUND
                StoreError.AlreadyExists, is FileAlreadyExistsException, is DirectoryNotEmptyException -> SyncFileFailureCode.OCCUPIED
                else -> SyncFileFailureCode.IO_FAILURE
            }
            throw SyncFileOperationError(code,
                if (effect.applied || (error as? SyncFileOperationError)?.effect == SyncFileMutationEffect.APPLIED)
                    SyncFileMutationEffect.APPLIED else SyncFileMutationEffect.UNCHANGED,
                (error as? SyncFileOperationError)?.displacedBytes ?: effect.displaced)
        }
    }

    private fun durable(effect: SyncFileMutationEffect = SyncFileMutationEffect.UNCHANGED, work: () -> Unit) {
        try { work() }
        catch (_: Exception) { throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED, effect) }
    }
}
