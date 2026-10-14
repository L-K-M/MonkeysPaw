package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** B23/J9 credential rules. The injected executor owns all IO; no settings intent sends HTTP. */
class ProviderSettingsService(private val store: ProviderSettingsStore, private val secrets: SecretStore,
                              private val io: CoroutineDispatcher) {
    val snapshot: ProviderSettingsSnapshot get() = store.snapshot

    suspend fun save(draft: ProviderDraft): Unit = withContext(io) {
        var undo: (suspend () -> Unit)? = null
        store.update({ settings ->
            val previous = settings.profiles.firstOrNull { it.id == draft.id }
            val candidate = ProviderProfile(draft.id, draft.displayName, draft.kind, draft.baseURL, draft.modelID)
            checkDestination(draft, candidate.baseURL, previous)
            validateKey(draft.key)
            val reference = when (val edit = draft.key) {
                ProviderKeyEdit.Keep -> previous?.secretReference
                is ProviderKeyEdit.Replace -> SecretAccount.provider(draft.id).also { account ->
                    undo = editSecret(account, bindSecret(edit.value, candidate.kind, candidate.baseURL))
                }
                ProviderKeyEdit.Clear -> {
                    undo = editSecret(SecretAccount.provider(draft.id), null)
                    null
                }
            }
            val profile = ProviderProfile(candidate.id, candidate.displayName, candidate.kind,
                candidate.baseURL, candidate.modelID, reference)
            val profiles = settings.profiles.toMutableList()
            val index = profiles.indexOfFirst { it.id == profile.id }
            if (index >= 0) profiles[index] = profile else profiles.add(profile)
            ProviderSettings(profiles, settings.selectedProfileID ?: profile.id)
        }, rollback = { undo?.invoke() })
    }

    suspend fun selectProfile(id: ProviderProfileID?): Unit = withContext(io) {
        store.update(change = { ProviderSettings(it.profiles, id) })
    }

    suspend fun deleteProfile(id: ProviderProfileID): Unit = withContext(io) {
        var undo: (suspend () -> Unit)? = null
        store.update({ settings ->
            if (settings.profiles.none { it.id == id }) throw ProviderSettingsError.ProfileNotFound
            undo = editSecret(SecretAccount.provider(id), null)
            ProviderSettings(settings.profiles.filter { it.id != id }, settings.selectedProfileID?.takeUnless { it == id })
        }, rollback = { undo?.invoke() })
    }

    /** Typed unsaved input is resolved only in memory, using this draft's own account. */
    suspend fun resolveForTesting(draft: ProviderDraft): ProviderConnection = withContext(io) {
        store.withSettings { settings ->
            val previous = settings.profiles.firstOrNull { it.id == draft.id }
            val base = ProviderSettings.normalizeBaseURL(draft.baseURL, draft.kind)
            checkDestination(draft, base, previous)
            validateKey(draft.key)
            val key = when (val edit = draft.key) {
                is ProviderKeyEdit.Replace -> edit.value
                ProviderKeyEdit.Clear -> null
                ProviderKeyEdit.Keep -> previous?.secretReference?.let { resolveSecret(it, draft.kind, base) }
            }
            ProviderConnection(draft.id, draft.kind, base, draft.modelID, key)
        }
    }

    suspend fun connection(id: ProviderProfileID): ProviderConnection = withContext(io) {
        store.withSettings { settings ->
            val profile = settings.profiles.firstOrNull { it.id == id } ?: throw ProviderSettingsError.ProfileNotFound
            val key = profile.secretReference?.let { resolveSecret(it, profile.kind, profile.baseURL) }
            ProviderConnection(id, profile.kind, profile.baseURL, profile.modelID, key)
        }
    }

    /** Presentation receives the tier, never the stored value. */
    suspend fun secretTier(id: ProviderProfileID): SecretTier? = withContext(io) {
        store.withSettings { settings ->
            val profile = settings.profiles.firstOrNull { it.id == id } ?: throw ProviderSettingsError.ProfileNotFound
            profile.secretReference?.let { readSecret(it, SecretReadSource.EFFECTIVE)?.tier }
        }
    }

    private fun checkDestination(draft: ProviderDraft, base: String, previous: ProviderProfile?) {
        if (previous == null || draft.key != ProviderKeyEdit.Keep) return
        if (previous.kind != draft.kind || previous.credentialOrigin != ProviderSettings.credentialOrigin(base)) {
            throw ProviderSettingsError.KeyRequiredForChangedDestination
        }
    }

    private fun validateKey(edit: ProviderKeyEdit) {
        if (edit !is ProviderKeyEdit.Replace) return
        if (edit.value.withValue { it.trimProviderWhitespace().isEmpty() || it.hasControls() }) {
            throw ProviderSettingsError.InvalidKey
        }
    }

    private suspend fun readSecret(account: SecretAccount, source: SecretReadSource): StoredSecret? = try {
        secrets.read(account, source)
    } catch (error: CancellationException) { throw error }
    catch (error: SecretStoreError) { throw ProviderSettingsError.Secret(error) }
    catch (_: Exception) { throw ProviderSettingsError.Secret(SecretStoreError.ReadFailed) }

    private fun bindSecret(value: SecretValue, kind: ProviderKind, base: String): SecretValue = try {
        value.withValue { key -> SecretValue(ProviderSettingsJson.encode(JsonObject(mapOf(
            "version" to JsonPrimitive(1), "origin" to JsonPrimitive(ProviderSettings.credentialOrigin(base)),
            "kind" to JsonPrimitive(kind.rawValue), "key" to JsonPrimitive(key),
        ))).decodeToString()) }
    } catch (_: Exception) { throw ProviderSettingsError.Secret(SecretStoreError.WriteFailed) }

    private suspend fun resolveSecret(account: SecretAccount, kind: ProviderKind, base: String): SecretValue? {
        val stored = readSecret(account, SecretReadSource.EFFECTIVE) ?: return null
        val key = try {
            stored.value.withValue { value ->
                val bytes = value.encodeToByteArray(throwOnInvalidSequence = true)
                ProviderSettingsJson.read(bytes)
                val credential = ProviderSettingsJson.firstFields(bytes, "version", "kind", "origin", "key")
                if (ProviderSettingsJson.version(credential["version"]) != 1L ||
                    ProviderSettingsJson.text(credential["kind"]) != kind.rawValue ||
                    ProviderSettingsJson.text(credential["origin"]) != ProviderSettings.credentialOrigin(base)) {
                    throw ProviderSettingsError.KeyRequiredForChangedDestination
                }
                SecretValue(ProviderSettingsJson.text(credential["key"]))
            }
        } catch (_: Exception) { throw ProviderSettingsError.KeyRequiredForChangedDestination }
        validateKey(ProviderKeyEdit.Replace(key))
        return key
    }

    private suspend fun editSecret(account: SecretAccount, value: SecretValue?): suspend () -> Unit {
        val previous = readSecret(account, SecretReadSource.PERSISTED)
        if (value == null && previous == null) return {}
        try {
            if (value != null) secrets.write(value, account) else secrets.delete(account)
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            System.err.println("Provider secret update failed.")
            throw ProviderSettingsError.Secret(error as? SecretStoreError
                ?: if (value == null) SecretStoreError.DeleteFailed else SecretStoreError.WriteFailed)
        }
        // Restore the exact opaque payload, including legacy/unknown fields and whitespace.
        return { if (previous != null) secrets.write(previous.value, account) else secrets.delete(account) }
    }

    override fun toString(): String = "<provider settings service>"
}
