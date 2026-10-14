package ch.lkmc.monkeyspaw.core.domain.llm

import java.net.URI
import java.util.Locale
import java.util.UUID

enum class ProviderKind(val rawValue: String, val defaultDisplayName: String, val defaultBaseURL: String, val defaultModelID: String) {
    ANTHROPIC("anthropic", "Anthropic", "https://api.anthropic.com", "claude-opus-5-5"),
    OPENAI_COMPATIBLE("openaiCompatible", "OpenAI-compatible", "https://api.openai.com/v1", ""),
}

data class ProviderProfileID(private val value: UUID = UUID.randomUUID()) {
    val rawValue: String get() = value.toString().lowercase(Locale.ROOT)

    override fun toString(): String = rawValue

    companion object {
        private val uuidPattern = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

        fun parse(value: String): ProviderProfileID {
            // UUID.fromString also accepts shortened groups, unlike Swift UUID.
            if (!uuidPattern.matches(value)) throw ProviderSettingsError.InvalidProfile
            return ProviderProfileID(UUID.fromString(value))
        }
    }
}

@ConsistentCopyVisibility
data class ProviderProfile private constructor(
    val id: ProviderProfileID,
    val displayName: String,
    val kind: ProviderKind,
    val baseURL: URI,
    val modelID: String,
    val secretReference: SecretAccount?,
) {
    val completionURL: URI get() = baseURL.endpoint(kind, ProviderEndpoint.COMPLETION)
    val modelsURL: URI get() = baseURL.endpoint(kind, ProviderEndpoint.MODELS)
    val cacheKey: ProviderCacheKey get() = ProviderCacheKey(id, kind, baseURL, modelID)
    val credentialOrigin: String get() = ProviderSettings.credentialOrigin(baseURL)

    override fun toString(): String = "<provider profile>"

    companion object {
        operator fun invoke(id: ProviderProfileID, displayName: String, kind: ProviderKind, baseURL: String,
                            modelID: String, secretReference: SecretAccount? = null): ProviderProfile {
            if (displayName.trimProviderWhitespace().isEmpty() || modelID.trimProviderWhitespace().isEmpty() ||
                displayName.hasControls() || modelID.hasControls() ||
                (secretReference != null && secretReference != SecretAccount.provider(id))) {
                throw ProviderSettingsError.InvalidProfile
            }
            return ProviderProfile(id, displayName, kind, ProviderSettings.normalizeBaseURL(baseURL, kind), modelID, secretReference)
        }
    }
}

data class ProviderCacheKey(val profileID: ProviderProfileID, val kind: ProviderKind, val baseURL: URI, val modelID: String) {
    override fun toString(): String = "<provider cache key>"
}

sealed interface ProviderKeyEdit {
    data object Keep : ProviderKeyEdit
    data class Replace(val value: SecretValue) : ProviderKeyEdit {
        override fun toString(): String = "<provider key edit redacted>"
    }
    data object Clear : ProviderKeyEdit

    companion object {
        fun typed(value: String): ProviderKeyEdit = value.trimProviderWhitespace().let {
            if (it.isEmpty()) Keep else Replace(SecretValue(it))
        }
    }
}

/** Immutable staged input, never serialized or persisted. */
data class ProviderDraft(
    val id: ProviderProfileID = ProviderProfileID(),
    val kind: ProviderKind = ProviderKind.ANTHROPIC,
    val displayName: String = kind.defaultDisplayName,
    val baseURL: String = kind.defaultBaseURL,
    val modelID: String = kind.defaultModelID,
    val key: ProviderKeyEdit = ProviderKeyEdit.Keep,
) {
    constructor(profile: ProviderProfile) : this(profile.id, profile.kind, profile.displayName,
        profile.baseURL.toASCIIString(), profile.modelID)

    override fun toString(): String = "<provider draft redacted>"
}

data class ModelDescriptor(val id: String, val displayName: String? = null) {
    override fun toString(): String = "<model descriptor>"
}

/** Services resolve credentials; presentation never receives a connection. */
class ProviderConnection internal constructor(
    val profileID: ProviderProfileID,
    val kind: ProviderKind,
    val baseURL: URI,
    val modelID: String,
    val key: SecretValue?,
) {
    val completionURL: URI get() = baseURL.endpoint(kind, ProviderEndpoint.COMPLETION)
    val modelsURL: URI get() = baseURL.endpoint(kind, ProviderEndpoint.MODELS)

    override fun toString(): String = "<provider connection redacted>"
}

internal enum class ProviderEndpoint { COMPLETION, MODELS }

internal fun URI.endpoint(kind: ProviderKind, endpoint: ProviderEndpoint): URI = URI(toASCIIString() + when (kind) {
    ProviderKind.ANTHROPIC -> if (endpoint == ProviderEndpoint.MODELS) "/v1/models" else "/v1/messages"
    ProviderKind.OPENAI_COMPATIBLE -> if (endpoint == ProviderEndpoint.MODELS) "/models" else "/chat/completions"
})

sealed class ProviderSettingsError private constructor(code: String) : Exception(code, null, false, true) {
    data class FutureVersion(val version: Int) : ProviderSettingsError("futureVersion")
    data class UnsupportedVersion(val version: Int) : ProviderSettingsError("unsupportedVersion")
    data object CorruptFile : ProviderSettingsError("corruptFile")
    data object ReadFailed : ProviderSettingsError("readFailed")
    data object WriteFailed : ProviderSettingsError("writeFailed")
    data object InvalidBaseURL : ProviderSettingsError("invalidBaseURL")
    data object InsecureBaseURL : ProviderSettingsError("insecureBaseURL")
    data object CredentialsInURL : ProviderSettingsError("credentialsInURL")
    data object QueryOrFragmentInURL : ProviderSettingsError("queryOrFragmentInURL")
    data object InvalidProfile : ProviderSettingsError("invalidProfile")
    data object InvalidKey : ProviderSettingsError("invalidKey")
    data object DuplicateProfile : ProviderSettingsError("duplicateProfile")
    data object ProfileNotFound : ProviderSettingsError("profileNotFound")
    data object KeyRequiredForChangedDestination : ProviderSettingsError("keyRequiredForChangedDestination")
    data class Secret(val error: SecretStoreError) : ProviderSettingsError("secret")
    data object SecretRollbackFailed : ProviderSettingsError("secretRollbackFailed")

    final override fun toString(): String = message.orEmpty()
}
