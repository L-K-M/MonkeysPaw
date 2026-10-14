package ch.lkmc.monkeyspaw.core.ports

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import java.nio.charset.CharacterCodingException

/**
 * Synchronous rooted IO, called off the UI thread behind LibraryService's mutation boundary.
 * Drivers reject symlinked components and nonregular files and never follow symlinks when listing.
 * Reads return owned bytes. Writes finish a same-directory temporary file before publication;
 * failure leaves the destination intact. Atomic publication does not promise crash durability.
 */
interface PromptStore {
    fun listFiles(): List<StoredFile>
    fun stamp(path: String): FileStamp?
    fun read(path: String): ByteArray
    fun write(bytes: ByteArray, path: String)
    /** Exclusive publication: any occupied leaf throws AlreadyExists without reading or replacing it. */
    fun create(bytes: ByteArray, path: String)
    fun delete(path: String)
    /**
     * Move a regular file, creating parents; an occupied destination is never replaced.
     * A failed rollback of partial publication throws RecoveryRequired.
     */
    fun move(source: String, destination: String)
}

/** Equality only; include the file incarnation so deletion/recreation changes the stamp. */
class FileStamp(private val token: String) {
    override fun equals(other: Any?): Boolean = other is FileStamp && token == other.token
    override fun hashCode(): Int = token.hashCode()
    override fun toString(): String = "<file stamp>"

    /** Private journal representation only; never include it in diagnostics. */
    internal fun journalToken(): String = checkedToken(token)

    companion object {
        internal fun fromJournalToken(token: String): FileStamp = FileStamp(checkedToken(token))

        private fun checkedToken(token: String): String {
            val bytes = try { token.encodeToByteArray(throwOnInvalidSequence = true) }
            catch (_: CharacterCodingException) { throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE) }
            if (bytes.isEmpty() || bytes.size > Limits.syncStampMaxBytes) {
                throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE)
            }
            return token
        }
    }
}

data class StoredFile(val relativePath: String, val stamp: FileStamp)

sealed class StoreError private constructor(message: String) : Exception(message) {
    object InvalidPath : StoreError("Invalid relative path.")
    object OutsideRoot : StoreError("Path is outside the store root.")
    object InvalidRoot : StoreError("Store root is unavailable.")
    object NotFound : StoreError("File is missing.")
    object NotRegularFile : StoreError("File is not a regular file.")
    object AlreadyExists : StoreError("Destination is occupied.")
    object IOFailure : StoreError("File operation failed.")
    object RecoveryRequired : StoreError("File move rollback failed. Reload and recover before retrying.")

    final override fun toString(): String = message.orEmpty()
}

/** Local POSIX paths stay byte exact. Sync normalization/reserved folders do not apply in M8. */
object StorePath {
    fun validate(path: String) {
        val bytes = try { path.encodeToByteArray(throwOnInvalidSequence = true) }
        catch (_: CharacterCodingException) { throw StoreError.InvalidPath }
        if (bytes.isEmpty() || bytes.size > Limits.maxRootedPathBytes || '\\' in path ||
            path.codePoints().anyMatch(UnicodeText::isControlOrFormat) ||
            path.split('/').any { it.isEmpty() || it == "." || it == ".." }) throw StoreError.InvalidPath
    }
}
