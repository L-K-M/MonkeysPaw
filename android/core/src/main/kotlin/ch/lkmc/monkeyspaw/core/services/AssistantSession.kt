package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.messages
import ch.lkmc.monkeyspaw.core.llm.transcriptMessage
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import java.util.Collections
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.time.Duration.Companion.nanoseconds

enum class AssistantPhase { IDLE, WORKING, DRAFT, READY, SAVED, FAILED }

/** In-memory state only. No saved-state or persistence representation. */
@ConsistentCopyVisibility
data class AssistantState internal constructor(
    val phase: AssistantPhase = AssistantPhase.IDLE,
    val artifact: LlmArtifact? = null,
    val review: LlmReview? = null,
    val issues: List<PromptIssue> = emptyList(),
    val selectedFindings: Set<Int> = emptySet(),
    val instruction: String = "",
    val candidate: AssistantCandidate? = null,
    val failure: AssistantFailure? = null,
    val usage: AssistantTokenUsage? = null,
    val elapsedSeconds: Double = 0.0,
    val isStale: Boolean = false,
    val providerHost: String? = null,
    val modelID: String? = null,
    val mutationAccess: AssistantMutationAccess = AssistantMutationAccess.UNAVAILABLE,
    val transcript: List<AssistantMessage> = emptyList(),
) {
    val diff: ArtifactDiff? get() = candidate?.diff
    override fun toString(): String = "<assistant state redacted>"
}

/** One UI-confined reducer. The owner forwards context changes and deactivates on departure. */
class AssistantSession(
    private val service: AssistantService,
    ownerScope: CoroutineScope,
    private val currentContext: () -> AssistantContext,
    private val monotonic: MonotonicClock = MonotonicClock(System::nanoTime),
) {
    private data class Attempt(val command: AssistantCommand, val context: AssistantContext,
        val request: AssistantRequest, val contextGeneration: Long)

    private val scope = CoroutineScope(ownerScope.coroutineContext + SupervisorJob(ownerScope.coroutineContext[Job]))
    private var context = currentContext()
    private val mutableState = MutableStateFlow(footer(AssistantState()))
    val state = mutableState.asStateFlow()
    private var active = true
    private var generation = 0L
    private var contextGeneration = 0L
    private var attempt: Attempt? = null
    private var reviewContext: AssistantContext? = null
    private var retainedID: ULID? = null
    private var operation: AssistantOperation<*>? = null
    private var started: Long? = null
    private var elapsedJob: Job? = null

    val canRetry: Boolean get() = active && attempt != null && state.value.phase != AssistantPhase.WORKING
    val canShowDiff: Boolean get() = active && state.value.artifact != null && attempt != null &&
        attempt?.command != AssistantCommand.Review && state.value.phase != AssistantPhase.WORKING

    /** L16 can recheck this seam before starting its checked publication path. */
    val isCandidateCurrent: Boolean get() {
        val current = state.value
        val candidate = current.candidate ?: return false
        val latest = currentContext()
        return active && current.phase == AssistantPhase.READY && !current.isStale &&
            current.issues.none { it.severity == PromptIssueSeverity.ERROR } &&
            candidate.context.matchesCandidate(latest) && service.isCurrent(latest)
    }

    fun contextChanged() {
        if (!active) return
        val latest = currentContext()
        if (latest == context) return
        val previous = context
        context = latest
        if (previous.matchesCandidate(latest)) {
            // A guard can become busy without changing the already displayed candidate.
            return
        }
        if (!previous.sameSession(latest)) reset()
        else {
            contextGeneration++
            val current = state.value
            publish(current.copy(candidate = null, selectedFindings = emptySet(), isStale = true,
                phase = if (current.phase in listOf(AssistantPhase.READY, AssistantPhase.SAVED)) AssistantPhase.DRAFT else current.phase))
        }
        publish(footer(state.value))
    }

    /** Credential edits retire a conversation even when the profile is byte-identical. */
    fun profileChanged() {
        if (!active) return
        reset()
        context = currentContext()
        publish(footer(state.value))
    }

    fun write(brief: String, effort: AssistantEffort? = null) = begin(AssistantCommand.Write(brief), effort)
    fun review(effort: AssistantEffort? = null) = begin(AssistantCommand.Review, effort)

    fun editInstruction(instruction: String) {
        if (active) publish(state.value.copy(instruction = instruction))
    }

    fun toggleFinding(index: Int) {
        contextChanged()
        if (!active || reviewContext != context || state.value.phase == AssistantPhase.WORKING ||
            state.value.review?.findings?.indices?.contains(index) != true) return
        val selected = state.value.selectedFindings.toMutableSet()
        if (!selected.add(index)) selected.remove(index)
        publish(state.value.copy(selectedFindings = Collections.unmodifiableSet(selected)))
    }

    /** UTF-8 ranges belong exclusively to the exact reviewed source and revision. */
    fun highlightFinding(index: Int): LlmReview.QuoteMatch.Matched? {
        contextChanged()
        if (!active || reviewContext != context) return null
        return state.value.review?.findings?.getOrNull(index)?.quoteMatch as? LlmReview.QuoteMatch.Matched
    }

    fun improve(effort: AssistantEffort? = null) {
        contextChanged()
        val findings = if (reviewContext == context) state.value.selectedFindings.sorted().mapNotNull {
            state.value.review?.findings?.getOrNull(it)
        } else emptyList()
        begin(AssistantCommand.Improve(state.value.instruction, findings), effort)
    }

    fun retryWithFeedback(feedback: String) {
        contextChanged()
        if (!canRetry) return
        val previous = attempt ?: return
        val command = when (val command = previous.command) {
            is AssistantCommand.Improve -> AssistantCommand.Improve(state.value.instruction,
                if (previous.context == context && previous.contextGeneration == contextGeneration) command.selectedFindings else emptyList())
            else -> command
        }
        begin(command, previous.request.effort, state.value.transcript, feedback)
    }

    /** Explicitly revalidate and merge against a fresh snapshot, without another provider call. */
    fun showDiff() {
        contextChanged()
        if (!canShowDiff) return
        val artifact = state.value.artifact ?: return
        val command = attempt?.command ?: return
        invalidateWork()
        val token = generation
        publish(state.value.copy(phase = AssistantPhase.DRAFT, failure = null, candidate = null))
        if (active && generation == token) prepare(artifact, command, context, contextGeneration, token)
    }

    fun updateElapsed() {
        val start = started ?: return
        if (active) publish(state.value.copy(elapsedSeconds = ((monotonic.nowNanos() - start) / 1e9).coerceAtLeast(0.0)))
    }

    fun cancel() {
        if (!active) return
        reset()
    }

    fun reject() = cancel()
    fun close() = cancel()

    fun deactivate() {
        if (!active) return
        cancel()
        active = false
        scope.cancel()
    }

    private fun begin(command: AssistantCommand, effort: AssistantEffort?,
                      transcript: List<AssistantMessage> = emptyList(), feedback: String? = null) {
        contextChanged()
        if (!active) return
        invalidateWork()
        if (feedback == null) retainedID = null
        attempt = null
        reviewContext = null
        stopElapsed()
        val token = generation
        val cleared = footer(AssistantState(instruction = state.value.instruction))
        val captured = context
        try {
            val request = AssistantRequest(command.action(captured), effort, transcript, feedback)
            attempt = Attempt(command, captured, request, contextGeneration)
            started = monotonic.nowNanos()
            val work = service.perform(command, captured, effort, transcript, feedback)
            operation = work
            publish(cleared.copy(phase = AssistantPhase.WORKING, transcript = request.messages))
            if (!active || generation != token) { work.cancel(); return }
            elapsedJob = scope.launch {
                while (isActive && generation == token) {
                    delay(Limits.assistantElapsedTickNanos.nanoseconds)
                    updateElapsed()
                }
            }
            scope.launch {
                val result = try { Result.success(work.await()) }
                catch (error: CancellationException) { work.cancel(); return@launch }
                catch (error: AssistantFailure) { Result.failure(error) }
                received(result, token)
            }
        } catch (error: CancellationException) {
            stopElapsed()
            throw error
        } catch (error: Exception) {
            if (active && generation == token) {
                stopElapsed()
                publish(cleared.copy(phase = AssistantPhase.FAILED, failure = AssistantFailure.sanitized(error)))
            }
        }
    }

    private fun received(result: Result<AssistantActionResult>, token: Long) {
        if (!active || generation != token) return
        contextChanged()
        if (!active || generation != token) return
        val captured = attempt ?: return
        if (!service.isCurrent(context)) { profileChanged(); return }
        operation = null
        val elapsed = started?.let { ((monotonic.nowNanos() - it) / 1e9).coerceAtLeast(0.0) } ?: state.value.elapsedSeconds
        stopElapsed()
        val failure = result.exceptionOrNull() as? AssistantFailure
        if (failure != null) {
            val failedStart = when (failure) {
                is AssistantFailure.Invalid, is AssistantFailure.ReadOnly, is AssistantFailure.Settings,
                AssistantFailure.NoEditor, AssistantFailure.EditorBusy, AssistantFailure.EditorConflict, AssistantFailure.StaleContext -> true
                is AssistantFailure.Assistant -> failure.error in listOf(AssistantError.NotConfigured, AssistantError.AccessDenied, AssistantError.PrivatePrompt)
                else -> false
            }
            publish(state.value.copy(phase = AssistantPhase.FAILED, failure = failure,
                elapsedSeconds = if (failedStart) 0.0 else elapsed,
                transcript = if (failedStart) emptyList() else state.value.transcript))
            return
        }
        val completed = result.getOrThrow()
        val response = completed.response
        val stale = captured.context != context || captured.contextGeneration != contextGeneration
        publish(state.value.copy(phase = AssistantPhase.DRAFT, usage = response.usage, isStale = stale,
            issues = completed.issues, elapsedSeconds = elapsed,
            transcript = state.value.transcript + response.transcriptMessage()))
        if (!active || generation != token) return
        when (val output = response.output) {
            is AssistantOutput.Review -> {
                if (captured.command != AssistantCommand.Review) { failOutput(); return }
                reviewContext = captured.context
                publish(state.value.copy(review = output.value))
            }
            is AssistantOutput.Artifact -> {
                if (captured.command == AssistantCommand.Review) { failOutput(); return }
                publish(state.value.copy(artifact = output.value))
                if (active && generation == token && !stale) {
                    prepare(output.value, captured.command, captured.context, captured.contextGeneration, token)
                }
            }
        }
    }

    private fun prepare(artifact: LlmArtifact, command: AssistantCommand, captured: AssistantContext,
                        capturedGeneration: Long, token: Long) {
        val work = service.prepare(artifact, command, captured, retainedID)
        operation = work
        scope.launch {
            val result = try { Result.success(work.await()) }
            catch (error: CancellationException) { work.cancel(); return@launch }
            catch (error: AssistantFailure) { Result.failure(error) }
            if (!active || generation != token) return@launch
            contextChanged()
            if (!active || generation != token) return@launch
            operation = null
            if (captured != context || capturedGeneration != contextGeneration || !service.isCurrent(context)) {
                publish(state.value.copy(isStale = true))
                return@launch
            }
            val candidate = result.getOrNull()
            if (candidate != null) {
                retainedID = candidate.content.document.frontMatter.id
                publish(state.value.copy(candidate = candidate, issues = candidate.issues,
                    isStale = false, phase = AssistantPhase.READY))
            } else when (val failure = result.exceptionOrNull() as AssistantFailure) {
                is AssistantFailure.Invalid -> publish(state.value.copy(issues = failure.issues, phase = AssistantPhase.DRAFT))
                else -> publish(state.value.copy(failure = failure, phase = AssistantPhase.FAILED))
            }
        }
    }

    private fun failOutput() = publish(state.value.copy(phase = AssistantPhase.FAILED,
        failure = AssistantFailure.Assistant(AssistantError.InvalidOutput)))

    private fun stopElapsed() { started = null; elapsedJob?.cancel(); elapsedJob = null }

    private fun invalidateWork() {
        generation++
        val previous = operation
        operation = null
        previous?.cancel()
    }

    private fun reset() {
        invalidateWork()
        stopElapsed()
        attempt = null
        reviewContext = null
        retainedID = null
        publish(footer(AssistantState()))
    }

    private fun footer(state: AssistantState): AssistantState = state.copy(
        providerHost = providerHost(), modelID = context.profile?.modelID,
        mutationAccess = context.access.mutationAccess)

    private fun providerHost(): String? {
        // Validated URLs include Foundation spellings java.net.URI cannot represent.
        val authority = context.profile?.baseURL?.substringAfter("://")?.substringBefore('/') ?: return null
        return if (authority.startsWith('[')) authority.substringBefore(']') + "]" else authority.substringBefore(':')
    }

    private fun publish(state: AssistantState) {
        mutableState.value = state.copy(issues = state.issues.immutableCopy(), transcript = state.transcript.immutableCopy())
    }

    override fun toString(): String = "<assistant session redacted>"
}
