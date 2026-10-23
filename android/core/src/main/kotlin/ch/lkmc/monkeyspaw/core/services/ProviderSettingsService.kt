package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import ch.lkmc.monkeyspaw.core.sync.ProviderSyncPayload
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** B23/J9 credential rules. The injected executor owns all IO; no settings intent sends HTTP. */
class ProviderSettingsService(private val store: ProviderSettingsStore, private val secrets: SecretStore,
                              private val io: CoroutineDispatcher) {
    val snapshot: ProviderSettingsSnapshot get() = store.snapshot

    /** §26 S10: remote applies and committed edits notify; the token removes the observer. */
    fun observeChanges(observer: () -> Unit): Long = store.observeChanges(observer)
    fun removeObserver(token: Long) = store.removeObserver(token)

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

    /** §26 S4/S6: the stored object verbatim, plus the persisted bound envelope
     * for each referenced account. A missing persisted value falls back to the
     * last decrypted remote document. */
    internal suspend fun exportSyncPayload(remoteSecrets: Map<String, String>): ProviderSyncPayload = withContext(io) {
        store.withDocument { objectValue, settings ->
            val stored = if (objectValue.isEmpty()) defaultObject else objectValue
            val secrets = mutableMapOf<String, String>()
            for (profile in settings.profiles) {
                val account = profile.secretReference ?: continue
                if (account.namespace != "provider") continue
                val persisted = readSecret(account, SecretReadSource.PERSISTED)
                if (persisted != null) persisted.value.withValue { secrets[account.rawValue] = it }
                else remoteSecrets[account.rawValue]?.let { secrets[account.rawValue] = it }
            }
            ProviderSyncPayload(stored, secrets)
        }
    }

    /** §26 S7: write the payload's secrets for referenced provider accounts and
     * drop local provider secrets the remote metadata no longer references,
     * then commit the metadata object verbatim. A metadata failure restores
     * every mutated account through the same rollback contract as edits. */
    internal suspend fun applySynced(objectValue: JsonObject, payload: Map<String, String>) = withContext(io) {
        val undo = ArrayDeque<suspend () -> Unit>()
        store.applySynced(objectValue, mutate = { current, remote ->
            val referenced = remote.profiles.mapNotNull { it.secretReference }
                .filter { it.namespace == "provider" }.toSet()
            for (account in referenced) {
                val envelope = payload[account.rawValue] ?: continue
                undo.addLast(editSecret(account, SecretValue(envelope)))
            }
            val previous = current.profiles.mapNotNull { it.secretReference }
                .filter { it.namespace == "provider" }.toSet()
            for (account in previous - referenced) {
                undo.addLast(editSecret(account, null))
            }
        }, rollback = { for (restore in undo.reversed()) restore() })
    }

    /** A missing file exports the canonical empty settings document. */
    internal val defaultObject: JsonObject get() = JsonObject(linkedMapOf(
        "version" to JsonPrimitive(ProviderSettings.currentVersion),
        "profiles" to JsonArray(emptyList()),
        "selectedProfileID" to JsonNull,
    ))

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
    catch (_: Exception) { throw ProviderSettingsError.Secret(SecretStoreError.Locked) }

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
        var unreadable = false
        val previous = try { readSecret(account, SecretReadSource.PERSISTED) }
        catch (error: ProviderSettingsError.Secret) {
            // Android reserves these for permanent key loss/corruption; transient reads report Locked.
            if (error.error != SecretStoreError.Unavailable && error.error != SecretStoreError.ReadFailed) throw error
            unreadable = true
            null
        }
        if (value == null && previous == null && !unreadable) return {}
        try {
            // Explicit recovery discards only this account; an unreadable payload cannot be restored.
            if (unreadable || value == null) secrets.delete(account)
            if (value != null) secrets.write(value, account)
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            System.err.println("Provider secret update failed.")
            throw ProviderSettingsError.Secret(error as? SecretStoreError
                ?: if (value == null) SecretStoreError.DeleteFailed else SecretStoreError.WriteFailed)
        }
        // Restore the exact opaque payload, including legacy/unknown fields and whitespace.
        return {
            if (previous != null) secrets.write(previous.value, account)
            else if (value != null) secrets.delete(account)
        }
    }

    override fun toString(): String = "<provider settings service>"
}
