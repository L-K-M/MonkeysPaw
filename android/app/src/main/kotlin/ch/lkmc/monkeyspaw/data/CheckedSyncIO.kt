package ch.lkmc.monkeyspaw.data

import android.os.Build
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import ch.lkmc.monkeyspaw.core.ports.*
import java.nio.charset.CharacterCodingException
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFileAttributeView
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

/** Native durability and deterministic race/failure injection; never selects a JVM fallback. */
internal abstract class CheckedSyncIO {
    enum class Mutation { PUBLISH, MODE, TRASH, CREATE_DIRECTORY, RENAME_DIRECTORY, REMOVE_DIRECTORY }
    class DirectoryToken(val value: String, val created: Boolean)

    open fun beforeMutation(mutation: Mutation, path: String) { }
    abstract fun flushFile(path: Path)
    abstract fun flushDirectory(path: Path)
    /** Persistent per-directory UUID. Inodes alone can be reused after deletion. */
    abstract fun directoryToken(path: Path): DirectoryToken

    protected fun decodeDirectoryToken(bytes: ByteArray, created: Boolean): DirectoryToken {
        val token = try { bytes.decodeToString(throwOnInvalidSequence = true) }
        catch (_: CharacterCodingException) { throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE) }
        val valid = try { UUID.fromString(token).toString() == token } catch (_: IllegalArgumentException) { false }
        if (!valid) throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE)
        return DirectoryToken(token, created)
    }

    open fun setMode(path: Path, mode: SyncFileMode) {
        Files.getFileAttributeView(path, PosixFileAttributeView::class.java, NOFOLLOW_LINKS)
            .setPermissions(PosixFilePermissions.fromString(if (mode == SyncFileMode.READ_ONLY) "r--r--r--" else "rw-------"))
    }
}

internal class AndroidCheckedSyncIO : CheckedSyncIO() {
    override fun flushFile(path: Path) = withDescriptor(path, Kind.FILE) { Os.fsync(it) }
    override fun flushDirectory(path: Path) = withDescriptor(path, Kind.DIRECTORY) { Os.fsync(it) }

    override fun setMode(path: Path, mode: SyncFileMode) {
        var applied = false
        try {
            withDescriptor(path, Kind.FILE) {
                Os.fchmod(it, if (mode == SyncFileMode.READ_ONLY) 0x124 else 0x180) // 0444 / 0600
                applied = true
            }
        } catch (_: Exception) {
            throw SyncFileOperationError(SyncFileFailureCode.IO_FAILURE,
                if (applied) SyncFileMutationEffect.APPLIED else SyncFileMutationEffect.UNCHANGED)
        }
    }

    override fun directoryToken(path: Path): DirectoryToken {
        val name = path.toString()
        var created = false
        try {
            val bytes = try { Os.getxattr(name, incarnationAttribute) }
            catch (error: ErrnoException) {
                if (error.errno != OsConstants.ENODATA) throw error
                val candidate = UUID.randomUUID().toString().encodeToByteArray()
                try {
                    Os.setxattr(name, incarnationAttribute, candidate, xattrCreate)
                    created = true
                }
                catch (race: ErrnoException) { if (race.errno != OsConstants.EEXIST) throw race }
                Os.getxattr(name, incarnationAttribute)
            }
            return decodeDirectoryToken(bytes, created)
        } catch (error: Exception) {
            throw SyncFileOperationError((error as? SyncFileOperationError)?.code ?: SyncFileFailureCode.IO_FAILURE,
                if (created) SyncFileMutationEffect.APPLIED else SyncFileMutationEffect.UNCHANGED)
        }
    }

    private enum class Kind { FILE, DIRECTORY }

    private fun withDescriptor(path: Path, kind: Kind, work: (java.io.FileDescriptor) -> Unit) {
        // O_NONBLOCK also prevents a raced FIFO from hanging before fstat rejects it.
        val closeOnExec = if (Build.VERSION.SDK_INT >= 27) OsConstants.O_CLOEXEC else api26CloseOnExec
        val descriptor = Os.open(path.toString(), OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or
            OsConstants.O_NONBLOCK or closeOnExec, 0)
        try {
            val mode = Os.fstat(descriptor).st_mode
            if (if (kind == Kind.FILE) !OsConstants.S_ISREG(mode) else !OsConstants.S_ISDIR(mode)) {
                throw SyncFileOperationError(SyncFileFailureCode.INVALID_PATH)
            }
            work(descriptor)
        } finally { Os.close(descriptor) }
    }

    private companion object {
        const val incarnationAttribute = "user.monkeyspaw.sync-incarnation"
        const val xattrCreate = 1 // Linux XATTR_CREATE; absent from the public Android OsConstants.
        const val api26CloseOnExec = 0x80000 // Linux O_CLOEXEC predates the API-27 public SDK field.
    }
}
