package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.ULIDGenerationError
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import java.util.UUID
import kotlinx.coroutines.*
import kotlin.time.Duration.Companion.nanoseconds

enum class AssistantEditorAvailability { AVAILABLE, BUSY, CONFLICTED }

/** An owned raw buffer, including unavailable source and the checked load's identity hint. */
data class AssistantEditorSnapshot(
    val source: String?,
    val relativePath: String,
    val revision: Long,
    val session: Long,
    val stamp: FileStamp?,
    val loadedID: ULID? = null,
    val availability: AssistantEditorAvailability = AssistantEditorAvailability.AVAILABLE,
    val readOnlyReason: SourceReadOnlyReason? = null,
    val isNew: Boolean = false,
) {
    val sourceBytes: ByteArray? get() = source?.toByteArray(Charsets.UTF_8)
    internal fun document(): PromptDocument = PromptCodec.parse(source ?: throw AssistantFailure.NoEditor,
        relativePath.substringAfterLast('/'))

    internal fun matchesCandidate(other: AssistantEditorSnapshot): Boolean =
        availability != AssistantEditorAvailability.CONFLICTED && other.availability != AssistantEditorAvailability.CONFLICTED &&
            copy(availability = AssistantEditorAvailability.AVAILABLE) == other.copy(availability = AssistantEditorAvailability.AVAILABLE)

    override fun toString(): String = "<assistant editor snapshot redacted>"
}

/** Composition supplies authoritative access; folder names never imply a role. */
enum class AssistantAccessState(val mutationAccess: AssistantMutationAccess) {
    PRIVATE_PROMPT(AssistantMutationAccess.CURRENT_SCOPE),
    GROUP_EDITOR(AssistantMutationAccess.CURRENT_SCOPE),
    GROUP_OWNER(AssistantMutationAccess.CURRENT_SCOPE),
    GROUP_VIEWER(AssistantMutationAccess.PRIVATE_COPY),
    UNAVAILABLE(AssistantMutationAccess.UNAVAILABLE),
}

enum class AssistantMutationAccess { CURRENT_SCOPE, PRIVATE_COPY, UNAVAILABLE }

/** Forward every transition, including away and back and credential-only edits. No secrets. */
data class AssistantContext(
    val libraryID: UUID,
    val profile: ProviderProfile?,
    val editor: AssistantEditorSnapshot? = null,
    val access: AssistantAccessState = AssistantAccessState.PRIVATE_PROMPT,
    val credentialGeneration: Long = 0,
) {
    internal fun sameSession(other: AssistantContext): Boolean = libraryID == other.libraryID &&
        profile == other.profile && credentialGeneration == other.credentialGeneration &&
        editor?.session == other.editor?.session && access == other.access

    fun matchesCandidate(other: AssistantContext): Boolean = sameSession(other) && when {
        editor == null -> other.editor == null
        other.editor == null -> false
        else -> editor.matchesCandidate(other.editor)
    }

    override fun toString(): String = "<assistant context redacted>"
}

sealed class AssistantCommand {
    data class Write(val brief: String) : AssistantCommand()
    data object Review : AssistantCommand()
    @ConsistentCopyVisibility
    data class Improve private constructor(val instruction: String, val selectedFindings: List<LlmReview.Finding>) : AssistantCommand() {
        companion object {
            operator fun invoke(instruction: String, selectedFindings: List<LlmReview.Finding> = emptyList()): Improve =
                Improve(instruction, selectedFindings.immutableCopy())
        }
    }

    internal fun action(context: AssistantContext): AssistantAction = when (this) {
        is Write -> AssistantAction.Write(brief)
        Review -> AssistantAction.Review(source(context))
        is Improve -> AssistantAction.Improve(source(context), instruction, selectedFindings)
    }

    private fun source(context: AssistantContext): String {
        val editor = context.editor ?: throw AssistantFailure.NoEditor
        editor.source?.let { return it }
        when (editor.availability) {
            AssistantEditorAvailability.BUSY -> throw AssistantFailure.EditorBusy
            AssistantEditorAvailability.CONFLICTED -> throw AssistantFailure.EditorConflict
            AssistantEditorAvailability.AVAILABLE -> Unit
        }
        editor.readOnlyReason?.let { throw AssistantFailure.ReadOnly(it) }
        throw AssistantFailure.NoEditor
    }

    final override fun toString(): String = "<assistant command redacted>"
}

sealed class AssistantFailure : Exception(null, null, false, true) {
    data class Assistant(val error: AssistantError) : AssistantFailure()
    data class Settings(val error: ProviderSettingsError) : AssistantFailure()
    @ConsistentCopyVisibility
    data class Invalid private constructor(val issues: List<PromptIssue>) : AssistantFailure() {
        companion object { operator fun invoke(issues: List<PromptIssue>): Invalid = Invalid(issues.immutableCopy()) }
    }
    data class ReadOnly(val reason: SourceReadOnlyReason) : AssistantFailure()
    data class Write(val error: PromptWriteError) : AssistantFailure()
    data class Identity(val error: ULIDGenerationError) : AssistantFailure()
    data class Diff(val error: LineDiffError) : AssistantFailure()
    data object NoEditor : AssistantFailure()
    data object EditorBusy : AssistantFailure()
    data object EditorConflict : AssistantFailure()
    data object StaleContext : AssistantFailure()

    final override fun toString(): String = "<assistant failure>"

    internal companion object {
        fun sanitized(error: Exception): AssistantFailure = when (error) {
            is AssistantFailure -> error
            is AssistantError -> Assistant(error)
            is HttpTransportError -> Assistant(AssistantError.Transport(error))
            is ProviderSettingsError -> Settings(error)
            is PromptWriteError -> Write(error)
            is ULIDGenerationError -> Identity(error)
            is LineDiffError -> Diff(error)
            is CancellationException -> Assistant(AssistantError.Transport(error.cause as? HttpTransportError ?: HttpTransportError.Cancelled))
            else -> Assistant(AssistantError.Transport(HttpTransportError.NetworkFailure))
        }
    }
}

class AssistantCandidate internal constructor(
    val content: ArtifactMergeCandidate,
    val diff: ArtifactDiff,
    val context: AssistantContext,
    val mutationAccess: AssistantMutationAccess,
) {
    val issues: List<PromptIssue> = content.document.issues.immutableCopy()
    override fun toString(): String = "<assistant candidate redacted>"
}

class AssistantActionResult internal constructor(val response: AssistantResponse, issues: List<PromptIssue>) {
    val issues: List<PromptIssue> = issues.immutableCopy()
    override fun toString(): String = "<assistant action result redacted>"
}

/** Completion wins once. Cancelling never joins a blocked native credential read. */
class AssistantOperation<T> internal constructor() {
    private val result = CompletableDeferred<Result<T>>()
    private val lifetime = SupervisorJob()

    init { result.invokeOnCompletion { lifetime.cancel() } }

    internal fun start(io: CoroutineDispatcher, timer: CoroutineDispatcher,
                       remainingNanos: (() -> Long)? = null, work: suspend () -> T) {
        val scope = CoroutineScope(lifetime + io)
        if (remainingNanos != null) scope.launch(timer) {
            val remaining = remainingNanos()
            if (remaining > 0) delay(remaining.nanoseconds)
            finish(Result.failure(AssistantFailure.Assistant(AssistantError.Transport(HttpTransportError.DeadlineExceeded))))
        }
        scope.launch {
            try {
                ensureActive()
                finish(Result.success(work()))
            } catch (error: Exception) { finish(Result.failure(AssistantFailure.sanitized(error))) }
        }
    }

    suspend fun await(): T = try { result.await().getOrThrow() }
    catch (error: CancellationException) { cancel(); throw error }

    fun cancel() = finish(Result.failure(AssistantFailure.Assistant(AssistantError.Transport(HttpTransportError.Cancelled))))

    private fun finish(value: Result<T>) { result.complete(value) }
    override fun toString(): String = "<assistant operation>"
}
