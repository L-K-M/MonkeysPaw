package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*

sealed interface EditResult {
    data class Saved(val commit: LibrarySaveResult) : EditResult
    data object Deleted : EditResult
    data object Missing : EditResult
    data class Conflict(val currentStamp: FileStamp) : EditResult
    data object DestinationOccupied : EditResult
    data class Invalid(val issues: List<PromptIssue>) : EditResult
    data class ReadOnly(val reason: SourceReadOnlyReason) : EditResult
    /** The revision's original bytes remain available even when they cannot be restored as a prompt. */
    data class ForensicRestoreBlocked(val error: PromptWriteError) : EditResult
    data class Relocated(val baseline: LibraryEntry, val current: PromptLoadResult) : EditResult
    data class Failed(val error: Exception) : EditResult
}

class PromptHistorySnapshot internal constructor(val revision: HistoryRevision, bytes: ByteArray, filename: String) {
    private val bytes = bytes.copyOf()
    val sourceBytes: ByteArray get() = bytes.copyOf()
    val document = PromptCodec.parseFile(this.bytes, filename)
}

/**
 * Synchronous editor commands with stamped outcomes. ViewModels own session drafts, scheduling,
 * cancellation and stale replies. No UI callback, watcher or filesystem driver lives here.
 */
class EditingService(private val library: LibraryService) {
    fun load(path: String): PromptLoadResult = library.mutations.run { library.checkedLoad(path) }

    fun create(source: String, path: String): EditResult = writeSource(source, path) { EditResult.Saved(library.create(it, path)) }

    fun save(source: String, path: String, expectedStamp: FileStamp?): EditResult = writeSource(source, path) { document ->
        val current = library.checkedLoad(path)
        when (current) {
            is PromptLoadResult.Loaded -> {
                if (expectedStamp != null && current.prompt.entry.stamp != expectedStamp) {
                    return@writeSource EditResult.Conflict(current.prompt.entry.stamp)
                }
                current.prompt.readOnlyReason?.let { return@writeSource EditResult.ReadOnly(it) }
            }
            PromptLoadResult.Missing -> if (expectedStamp != null) return@writeSource EditResult.Missing
            is PromptLoadResult.Failed -> return@writeSource EditResult.Failed(current.error)
        }
        EditResult.Saved(library.save(document, path, expectedStamp))
    }

    fun rename(path: String, filename: String, expectedStamp: FileStamp): EditResult = command(path, expectedStamp) {
        if (filename.isEmpty() || '/' in filename) throw StoreError.InvalidPath
        val folder = path.substringBeforeLast('/', "")
        moved(path, (if (folder.isEmpty()) "" else "$folder/") + filename, expectedStamp)
    }

    fun move(path: String, folder: String, expectedStamp: FileStamp): EditResult = command(path, expectedStamp) {
        if (folder.isNotEmpty()) StorePath.validate(folder)
        moved(path, (if (folder.isEmpty()) "" else "$folder/") + LibraryPath.filename(path), expectedStamp)
    }

    fun delete(path: String, expectedStamp: FileStamp): EditResult = command(path, expectedStamp) {
        library.delete(path, expectedStamp)
        EditResult.Deleted
    }

    fun restore(revision: HistoryRevision, path: String, expectedStamp: FileStamp): EditResult = command(path, expectedStamp) {
        try { EditResult.Saved(library.restore(revision, path, expectedStamp)) }
        catch (error: PromptWriteError) { EditResult.ForensicRestoreBlocked(error) }
    }

    /** Captured original bytes for preview/forensics; history reads never sample the clipboard. */
    fun history(identity: PromptIdentity, filename: String): List<PromptHistorySnapshot> = library.mutations.run {
        library.history.revisions(identity).map { PromptHistorySnapshot(it, library.history.read(it), filename) }
    }

    private fun moved(source: String, destination: String, stamp: FileStamp): EditResult =
        when (val move = library.move(source, destination, stamp)) {
            is LibraryMoveResult.Moved -> EditResult.Saved(LibrarySaveResult(move.entry))
            is LibraryMoveResult.Relocated -> EditResult.Relocated(move.baseline, move.current)
        }

    private fun command(path: String, stamp: FileStamp, perform: () -> EditResult): EditResult = library.mutations.run {
        val current = library.checkedLoad(path)
        when (current) {
            PromptLoadResult.Missing -> return@run EditResult.Missing
            is PromptLoadResult.Failed -> return@run EditResult.Failed(current.error)
            is PromptLoadResult.Loaded -> {
                if (current.prompt.entry.stamp != stamp) return@run EditResult.Conflict(current.prompt.entry.stamp)
                current.prompt.readOnlyReason?.let { return@run EditResult.ReadOnly(it) }
            }
        }
        try { perform() } catch (error: Exception) { outcome(error, path, stamp) }
    }

    private fun writeSource(source: String, path: String, write: (PromptDocument) -> EditResult): EditResult = library.mutations.run {
        val document = PromptCodec.parse(source, LibraryPath.filename(path))
        if (document.isReadOnly) return@run EditResult.ReadOnly(SourceReadOnlyReason.FUTURE_FORMAT)
        if (document.issues.any { it.severity == PromptIssueSeverity.ERROR }) return@run EditResult.Invalid(document.issues)
        try { write(document) }
        catch (_: PromptWriteError.SourceTooLarge) { EditResult.Invalid(listOf(PromptIssue(PromptIssueCode.SOURCE_TOO_LARGE))) }
        catch (_: PromptWriteError.UnsupportedFormat) { EditResult.ReadOnly(SourceReadOnlyReason.FUTURE_FORMAT) }
        catch (error: Exception) { outcome(error, path, null) }
    }

    private fun outcome(error: Exception, path: String, expectedStamp: FileStamp?): EditResult {
        if (error is LibraryError.DestinationOccupied) return EditResult.DestinationOccupied
        if (error is LibraryError.Conflict || error is StoreError.NotFound) {
            return when (val current = library.checkedLoad(path)) {
                PromptLoadResult.Missing -> EditResult.Missing
                is PromptLoadResult.Loaded -> if (error is LibraryError.Conflict ||
                    expectedStamp != null && current.prompt.entry.stamp != expectedStamp) {
                    EditResult.Conflict(current.prompt.entry.stamp)
                } else EditResult.Failed(sanitized(error))
                is PromptLoadResult.Failed -> EditResult.Failed(current.error)
            }
        }
        return EditResult.Failed(sanitized(error))
    }
}
