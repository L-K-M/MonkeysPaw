package ch.lkmc.monkeyspaw.core.domain.llm

import java.net.URI

@ConsistentCopyVisibility
data class ProviderSettings private constructor(val profiles: List<ProviderProfile>, val selectedProfileID: ProviderProfileID?) {
    val version: Int get() = currentVersion

    override fun toString(): String = "<provider settings>"

    companion object {
        const val currentVersion = 1

        operator fun invoke(profiles: List<ProviderProfile> = emptyList(), selectedProfileID: ProviderProfileID? = null): ProviderSettings {
            val snapshot = profiles.immutableCopy()
            if (snapshot.map { it.id }.toSet().size != snapshot.size) throw ProviderSettingsError.DuplicateProfile
            if (selectedProfileID != null && snapshot.none { it.id == selectedProfileID }) throw ProviderSettingsError.ProfileNotFound
            return ProviderSettings(snapshot, selectedProfileID)
        }

        fun normalizeBaseURL(input: String, kind: ProviderKind): URI = ProviderURLs.normalize(input, kind)

        /** Literal classification only; callers supply a lowercase host with one trailing dot removed. */
        fun isLoopbackHost(host: String): Boolean = ProviderURLs.isLoopback(host)

        /** Normalized scheme, host and effective port, excluding the path/model. */
        fun credentialOrigin(baseURL: URI): String = ProviderURLs.credentialOrigin(baseURL)
    }
}

data class ProviderSettingsSnapshot(val settings: ProviderSettings, val readOnlyError: ProviderSettingsError? = null) {
    val isReadOnly: Boolean get() = readOnlyError != null

    override fun toString(): String = "<provider settings snapshot>"
}
