package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.ULIDGenerationError
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssue
import ch.lkmc.monkeyspaw.core.domain.sync.SyncError
import ch.lkmc.monkeyspaw.core.domain.sync.SyncPromptOrigin
import ch.lkmc.monkeyspaw.core.sync.SyncConflictMetadata
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.security.MessageDigest
import java.nio.charset.CharacterCodingException
import java.time.Instant
import java.util.concurrent.CancellationException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Library commands share one boundary; each keyed store also owns a separate boundary. */
internal class MutationBoundary {
    private val lock = ReentrantLock()

    fun <T> run(work: () -> T): T = lock.withLock {
        try { work() } catch (error: Exception) { throw sanitized(error) }
    }
}

internal fun sanitized(error: Exception): Exception = when (error) {
    is InterruptedException -> error.also { Thread.currentThread().interrupt() }
    is SyncPathIssue -> StoreError.InvalidPath
    StoreError.RecoveryRequired -> LibraryError.RecoveryRequired
    is StoreError, is LibraryError, is SyncError, is SyncFileOperationError, is PromptWriteError, is ULIDGenerationError,
    is AssistantSaveRefusal, is CancellationException -> error
    else -> LibraryError.OperationFailed
}

sealed class LibraryError private constructor(message: String) : Exception(message) {
    object InvalidPromptPath : LibraryError("Choose an eligible Markdown path.")
    object InvalidIdentity : LibraryError("Invalid prompt identity.")
    object IdentityMismatch : LibraryError("The saved prompt identity must be preserved.")
    object KeyedStateConflict : LibraryError("Destination already has prompt state.")
    object Conflict : LibraryError("Prompt changed. Reload before saving.")
    object DestinationOccupied : LibraryError("Destination is occupied.")
    object RecoveryRequired : LibraryError("Local recovery is required before reading or editing.")
    object InvalidTimestamp : LibraryError("Timestamp is outside the supported range.")
    object HistoryCollisionLimitReached : LibraryError("History sequence is exhausted.")
    object RevisionNotFound : LibraryError("History revision is unavailable.")
    object InvalidProvenance : LibraryError("Prompt attribution is corrupt or unsupported.")
    object CommitUnverified : LibraryError("File committed but could not be verified. Reload before retrying.")
    object PreviewMismatch : LibraryError("Saved bytes must match the assistant preview.")
    object CopyLimitReached : LibraryError("No available prompt name within the creation limit.")
    object AccessDenied : LibraryError("This group prompt is read-only or unavailable.")
    object AccessChanged : LibraryError("Access changed. Review the action again.")
    object OperationFailed : LibraryError("Local operation failed.")

    final override fun toString(): String = message.orEmpty()
}

/** Local identity hashes raw path UTF-8, without normalization or a library-root prefix. */
sealed class PromptIdentity {
    data class Local(val hash: String) : PromptIdentity()
    data class Assigned(val id: ULID) : PromptIdentity()

    val storageKey: String
        get() = when (this) {
            is Assigned -> id.rawValue
            is Local -> hash.also {
                if (it.length != 64 || it.any { character -> character !in '0'..'9' && character !in 'a'..'f' }) {
                    throw LibraryError.InvalidIdentity
                }
            }
        }

    final override fun toString(): String = "<prompt identity>"

    companion object {
        fun at(path: String, id: ULID? = null): PromptIdentity {
            if (id != null) return Assigned(id)
            val bytes = try { path.encodeToByteArray(throwOnInvalidSequence = true) }
            catch (_: CharacterCodingException) { throw StoreError.InvalidPath }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            return Local(digest.joinToString("") { "%02x".format(it.toInt() and 255) })
        }
    }
}

@ConsistentCopyVisibility
data class LibraryEntry internal constructor(
    val relativePath: String, val document: PromptDocument, val stamp: FileStamp,
    val access: PromptAccessState = PromptAccessState.Local, val accessGeneration: Long = 0,
    val favorite: Boolean = document.frontMatter.favorite,
) {
    val identity: PromptIdentity = PromptIdentity.at(relativePath, document.frontMatter.id)
    val folder: String get() = relativePath.substringBeforeLast('/', "")
    val issues: List<PromptIssue> get() = document.issues
    /** Private marker-derived lineage follows copies across folders and devices. */
    val syncOrigin: SyncPromptOrigin? get() = if (access == PromptAccessState.Local) {
        runCatching { SyncConflictMetadata.origin(document) }.getOrNull()
    } else null

    internal fun projected(snapshot: GroupAccessSnapshot): LibraryEntry = copy(
        access = snapshot.access(relativePath, identity), accessGeneration = snapshot.generation, favorite = snapshot.favorite(this))
}

data class HistoryRevision(val identity: PromptIdentity, val filename: String, val timestamp: Instant)

/** Both maintenance flags describe an already committed file; callers adopt it without retrying. */
data class LibrarySaveResult(val entry: LibraryEntry, val historyMaintenanceFailed: Boolean = false,
    val provenanceMaintenanceFailed: Boolean = false)

enum class SourceReadOnlyReason { FUTURE_FORMAT, INVALID_UTF8, SOURCE_TOO_LARGE, GROUP_VIEWER, GROUP_UNAVAILABLE }

class LoadedPrompt internal constructor(bytes: ByteArray, val entry: LibraryEntry) {
    private val bytes = bytes.copyOf()
    val sourceBytes: ByteArray get() = bytes.copyOf()
    private val sourceReadOnlyReason: SourceReadOnlyReason? = when {
        entry.document.isReadOnly -> SourceReadOnlyReason.FUTURE_FORMAT
        entry.issues.any { it.code == PromptIssueCode.INVALID_UTF8 } -> SourceReadOnlyReason.INVALID_UTF8
        entry.issues.any { it.code == PromptIssueCode.SOURCE_TOO_LARGE } -> SourceReadOnlyReason.SOURCE_TOO_LARGE
        else -> null
    }
    val readOnlyReason: SourceReadOnlyReason? = sourceReadOnlyReason ?: entry.access.readOnlyReason
    val source: String? get() = if (sourceReadOnlyReason == SourceReadOnlyReason.INVALID_UTF8 ||
        sourceReadOnlyReason == SourceReadOnlyReason.SOURCE_TOO_LARGE) null else entry.document.source
}

sealed interface PromptLoadResult {
    data class Loaded(val prompt: LoadedPrompt) : PromptLoadResult
    data object Missing : PromptLoadResult
    data class Failed(val error: Exception) : PromptLoadResult
}

sealed interface LibraryMoveResult {
    data class Moved(val entry: LibraryEntry) : LibraryMoveResult
    /** The move committed. Bind to baseline.relativePath and reconcile the destination observation.
     * The baseline carries the source stamp; reload before using it as an expected stamp. */
    data class Relocated(val baseline: LibraryEntry, val current: PromptLoadResult) : LibraryMoveResult
}

enum class KeyMigration { UNCHANGED, MIGRATED }

internal interface PromptKeyedStore {
    /** Move the whole key or fail unchanged; completed moves are reversible.
     * UNCHANGED means an equal identity or absent source, and destination collisions throw KeyedStateConflict. */
    fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration
}

internal object LibraryPath {
    fun validate(path: String) {
        StorePath.validate(path)
        if (!isPrompt(path)) throw LibraryError.InvalidPromptPath
    }

    fun isPrompt(path: String): Boolean {
        val parts = path.split('/')
        return path.endsWith(".md") && path != "README.md" &&
            parts.none { it.startsWith('_') } && parts.dropLast(1).none { it.startsWith('.') }
    }

    fun filename(path: String): String = path.substringAfterLast('/')
}
