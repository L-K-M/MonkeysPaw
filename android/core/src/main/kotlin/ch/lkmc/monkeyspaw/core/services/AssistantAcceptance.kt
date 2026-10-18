package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantTokenUsage
import ch.lkmc.monkeyspaw.core.domain.llm.immutableCopy
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class AssistantCommittedPrompt internal constructor(val entry: LibraryEntry, val historyMaintenanceFailed: Boolean)

sealed interface AssistantAcceptanceConflict {
    data object ChangedBuffer : AssistantAcceptanceConflict
    data class Modified(val currentStamp: FileStamp) : AssistantAcceptanceConflict
    data object Deleted : AssistantAcceptanceConflict
}

sealed interface AssistantAcceptanceFailure {
    data object NotReady : AssistantAcceptanceFailure
    data object Cancelled : AssistantAcceptanceFailure
    data object Inactive : AssistantAcceptanceFailure
    data object StaleContext : AssistantAcceptanceFailure
    data object AccessDenied : AssistantAcceptanceFailure
    data object EditorBusy : AssistantAcceptanceFailure
    class Editing(val error: Exception) : AssistantAcceptanceFailure
    class Invalid internal constructor(issues: List<PromptIssue>) : AssistantAcceptanceFailure {
        val issues = issues.immutableCopy()
    }
    data class ReadOnly(val reason: SourceReadOnlyReason) : AssistantAcceptanceFailure
}

/** Both committed cases are authoritative. Maintenance warnings never invite another file write. */
sealed class AssistantAcceptanceOutcome {
    data class Saved(val commit: AssistantCommittedPrompt) : AssistantAcceptanceOutcome()
    data class Conflict(val reason: AssistantAcceptanceConflict) : AssistantAcceptanceOutcome()
    data class Failed(val reason: AssistantAcceptanceFailure) : AssistantAcceptanceOutcome()
    data class CommittedWithProvenanceWarning(val commit: AssistantCommittedPrompt) : AssistantAcceptanceOutcome()

    val committed: AssistantCommittedPrompt? get() = when (this) {
        is Saved -> commit
        is CommittedWithProvenanceWarning -> commit
        else -> null
    }

    final override fun toString(): String = "<assistant acceptance outcome>"

    internal companion object {
        fun saved(result: LibrarySaveResult): AssistantAcceptanceOutcome {
            val commit = AssistantCommittedPrompt(result.entry, result.historyMaintenanceFailed)
            return if (result.provenanceMaintenanceFailed) CommittedWithProvenanceWarning(commit) else Saved(commit)
        }
    }
}

enum class AssistantSaveDestination { NEW_PROMPT, IMPROVE, PRIVATE_COPY }

/** Issued once by the session. Even duplicate editor/worker submissions cannot publish this token twice. */
class AssistantAcceptance internal constructor(
    val candidate: AssistantCandidate,
    val destination: AssistantSaveDestination,
    val usage: AssistantTokenUsage?,
) {
    val id: UUID = UUID.randomUUID()
    private val claimed = AtomicBoolean()
    internal fun claim(): Boolean = claimed.compareAndSet(false, true)
    override fun toString(): String = "<assistant acceptance redacted>"
}

/** UI invalidation and the worker's last check share a short lock, never held during file IO. */
class AssistantSavePermit internal constructor(private val profileIsCurrent: () -> Boolean = { true }) {
    private val lock = Any()
    private var invalidation: AssistantAcceptanceOutcome? = null
    val refusal: AssistantAcceptanceOutcome? get() = synchronized(lock) { invalidation }

    fun invalidate(outcome: AssistantAcceptanceOutcome) {
        require(outcome.committed == null)
        synchronized(lock) { if (invalidation == null) invalidation = outcome }
    }

    internal fun check() {
        val current = profileIsCurrent()
        synchronized(lock) {
            invalidation?.let { throw AssistantSaveRefusal(it) }
            if (!current) throw AssistantSaveRefusal(
                AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.StaleContext))
        }
    }
}

internal class AssistantSaveRefusal(val outcome: AssistantAcceptanceOutcome) : Exception(null, null, false, false)

/** M8 owns guards and adoption; no app type or UI callback is sampled on the worker. */
interface AssistantAcceptanceEditor {
    fun acceptAssistant(acceptance: AssistantAcceptance, permit: AssistantSavePermit,
        validate: () -> AssistantAcceptanceOutcome?, completion: (AssistantAcceptanceOutcome) -> Unit)
    fun cancelAssistantAcceptance(permit: AssistantSavePermit)
}

/** Cached local roles authorize both request context and checked publication. */
fun interface AssistantAccess {
    fun current(relativePath: String?): AssistantAccessState
    fun current(relativePath: String?, identity: PromptIdentity?): AssistantAccessState = current(relativePath)

    companion object {
        val LOCAL = AssistantAccess { AssistantAccessState.PRIVATE_PROMPT }
    }
}
