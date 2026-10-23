package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.llm.SecretReadSource
import ch.lkmc.monkeyspaw.core.domain.llm.SecretStoreError
import ch.lkmc.monkeyspaw.core.domain.llm.SecretTier
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.llm.StoredSecret
import ch.lkmc.monkeyspaw.core.ports.Entropy
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import ch.lkmc.monkeyspaw.core.sync.Base64URL
import kotlinx.coroutines.CancellationException

/** Fixed reasons only; the key text never enters errors or diagnostics. */
sealed class ProviderSyncKeyError private constructor() : Exception("Sync key operation failed.", null, false, true) {
    data object InvalidKey : ProviderSyncKeyError()
    class Secret(val error: SecretStoreError) : ProviderSyncKeyError()

    final override fun toString(): String = "<provider sync key error>"
}

/** §26 S3/S12: the dedicated AES-256 key is generated on one device and entered
 * on the others as 43 unpadded base64url characters. It lives in the platform
 * SecretStore under `provider-sync:<user ULID>` and is never uploaded. */
class ProviderSyncKeyService(private val secrets: SecretStore, private val entropy: Entropy) {
    /** UI receives the provisioning tier, never the stored key. */
    suspend fun tier(userID: ULID): SecretTier? = read(SecretAccount.providerSync(userID))?.tier

    /** Generates, stores and returns the key text for one explicit display/copy. */
    suspend fun generateKey(userID: ULID): String {
        val bytes = try { entropy.bytes(Limits.providerSyncKeyBytes) }
        catch (_: Exception) { throw ProviderSyncKeyError.Secret(SecretStoreError.WriteFailed) }
        return enterKey(userID, Base64URL.encode(bytes))
    }

    /** Accepts the key text; stores it under the persisted tier. */
    suspend fun enterKey(userID: ULID, text: String): String {
        val bytes = Base64URL.decode(text)
        if (bytes == null || bytes.size != Limits.providerSyncKeyBytes) throw ProviderSyncKeyError.InvalidKey
        val normalized = Base64URL.encode(bytes)
        try { secrets.write(SecretValue(normalized), SecretAccount.providerSync(userID)) }
        catch (error: CancellationException) { throw error }
        catch (error: SecretStoreError) { throw ProviderSyncKeyError.Secret(error) }
        catch (_: Exception) { throw ProviderSyncKeyError.Secret(SecretStoreError.WriteFailed) }
        return normalized
    }

    /** Idempotent removal of every persisted copy for this account. */
    suspend fun removeKey(userID: ULID) {
        try { secrets.delete(SecretAccount.providerSync(userID)) }
        catch (error: CancellationException) { throw error }
        catch (error: SecretStoreError) { throw ProviderSyncKeyError.Secret(error) }
        catch (_: Exception) { throw ProviderSyncKeyError.Secret(SecretStoreError.DeleteFailed) }
    }

    /** Persisted raw key bytes for the sync step; null when unprovisioned. */
    internal suspend fun keyBytes(userID: ULID): ByteArray? =
        read(SecretAccount.providerSync(userID))?.value?.withValue { Base64URL.decode(it) }

    private suspend fun read(account: SecretAccount): StoredSecret? = try {
        secrets.read(account, SecretReadSource.PERSISTED)
    } catch (error: CancellationException) { throw error }
    catch (error: SecretStoreError) { throw ProviderSyncKeyError.Secret(error) }
    catch (_: Exception) { throw ProviderSyncKeyError.Secret(SecretStoreError.ReadFailed) }

    override fun toString(): String = "<provider sync key service>"
}
