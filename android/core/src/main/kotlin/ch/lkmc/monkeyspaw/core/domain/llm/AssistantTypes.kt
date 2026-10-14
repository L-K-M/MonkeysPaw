package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.ports.HttpTransportError

/** User intent and the template snapshot, never rendered or remembered Fill values. */
sealed class AssistantAction {
    data class Write(val brief: String) : AssistantAction()
    data class Review(val source: String) : AssistantAction()
    @ConsistentCopyVisibility
    data class Improve private constructor(val source: String, val instruction: String, val selectedFindings: List<LlmReview.Finding>) : AssistantAction() {
        companion object {
            operator fun invoke(source: String, instruction: String, selectedFindings: List<LlmReview.Finding> = emptyList()): Improve =
                Improve(source, instruction, selectedFindings.immutableCopy())
        }
    }

    final override fun toString(): String = "<assistant action redacted>"
}

enum class AssistantEffort(val rawValue: String) { LOW("low"), MEDIUM("medium"), HIGH("high"), XHIGH("xhigh"), MAX("max") }

/** Session-only content; no persistence serializer. */
data class AssistantMessage(val role: Role, val content: String) {
    enum class Role(val rawValue: String) { USER("user"), ASSISTANT("assistant") }

    override fun toString(): String = "<assistant message redacted>"
}

@ConsistentCopyVisibility
data class AssistantRequest private constructor(
    val action: AssistantAction,
    val effort: AssistantEffort?,
    val transcript: List<AssistantMessage>,
    val feedback: String?,
) {
    override fun toString(): String = "<assistant request redacted>"

    companion object {
        operator fun invoke(action: AssistantAction, effort: AssistantEffort? = null,
                            transcript: List<AssistantMessage> = emptyList(), feedback: String? = null): AssistantRequest =
            AssistantRequest(action, effort, transcript.immutableCopy(), feedback)
    }
}

sealed class AssistantOutput {
    data class Artifact(val value: LlmArtifact) : AssistantOutput()
    data class Review(val value: LlmReview) : AssistantOutput()

    final override fun toString(): String = "<assistant output redacted>"
}

data class AssistantTokenUsage(val inputTokens: Long, val outputTokens: Long)

data class AssistantResponse(val output: AssistantOutput, val usage: AssistantTokenUsage? = null) {
    override fun toString(): String = "<assistant response redacted>"
}

@ConsistentCopyVisibility
data class AssistantModelPage private constructor(val models: List<ModelDescriptor>, val hasMore: Boolean, val firstID: String?, val lastID: String?) {
    override fun toString(): String = "<assistant model page redacted>"

    companion object {
        operator fun invoke(models: List<ModelDescriptor>, hasMore: Boolean = false, firstID: String? = null, lastID: String? = null): AssistantModelPage =
            AssistantModelPage(models.immutableCopy(), hasMore, firstID, lastID)
    }
}

/** Diagnostics contain only static codes, never provider content, headers or causes. */
sealed class AssistantError private constructor(code: String) : Exception(code, null, false, true) {
    data object NotConfigured : AssistantError("notConfigured")
    data object AccessDenied : AssistantError("accessDenied")
    data object PrivatePrompt : AssistantError("privatePrompt")
    data class Transport(val error: HttpTransportError) : AssistantError("transportFailure")
    data object Authentication : AssistantError("authentication")
    data object ModelNotFound : AssistantError("modelNotFound")
    data class RateLimited(val retryAfterSeconds: Double?) : AssistantError("rateLimited")
    data object Overloaded : AssistantError("overloaded")
    data class ProviderFailure(val statusCode: Int) : AssistantError("providerFailure")
    data object ProviderState : AssistantError("providerState")
    data object Truncated : AssistantError("truncated")
    data object Declined : AssistantError("declined")
    data object EmptyResponse : AssistantError("emptyResponse")
    data class UnexpectedStop(val reason: String) : AssistantError("unexpectedStop")
    data object InvalidOutput : AssistantError("invalidOutput")

    final override fun toString(): String = message.orEmpty()
}

sealed class ConnectionTestResult(private val code: String) {
    @ConsistentCopyVisibility
    data class Ok private constructor(val models: List<ModelDescriptor>) : ConnectionTestResult("ok") {
        companion object {
            operator fun invoke(models: List<ModelDescriptor>): Ok = Ok(models.immutableCopy())
        }
    }
    data object Authentication : ConnectionTestResult("authentication")
    data object NotFound : ConnectionTestResult("notFound")
    data class RateLimited(val retryAfterSeconds: Double?) : ConnectionTestResult("rateLimited")
    data object Network : ConnectionTestResult("network")
    data object Timeout : ConnectionTestResult("timeout")
    data object UnsupportedListing : ConnectionTestResult("unsupportedListing")
    data object InvalidResponse : ConnectionTestResult("invalidResponse")
    data object Cancelled : ConnectionTestResult("cancelled")
    data class Settings(val error: ProviderSettingsError) : ConnectionTestResult("settings")
    data class ProviderFailure(val statusCode: Int) : ConnectionTestResult("providerFailure")

    final override fun toString(): String = code
}
