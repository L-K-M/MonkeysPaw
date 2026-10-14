package ch.lkmc.monkeyspaw.data

import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.UserNotAuthenticatedException
import androidx.datastore.core.DataStore
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.security.InvalidKeyException

/** One process-scoped driver owns the separate secrets DataStore and serializes all key access. */
internal class AndroidKeystoreSecretStore(
    private val store: DataStore<SecretRecords>,
    private val keys: SecretKeyProvider,
    private val io: CoroutineDispatcher,
) : SecretStore {
    private val mutex = Mutex()

    override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? =
        operation(SecretStoreError.ReadFailed) {
            val envelope = store.data.first().entries[account.rawValue] ?: return@operation null
            val key = keys.read() ?: throw SecretStoreError.Unavailable
            StoredSecret(SecretEnvelope.open(envelope, account, key), SecretTier.KEYSTORE)
        }

    override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier =
        operation(SecretStoreError.WriteFailed) {
            store.updateData { current ->
                SecretRecords(current.entries + (account.rawValue to sealForWrite(value, account, current)))
            }
            SecretTier.KEYSTORE
        }

    override suspend fun delete(account: SecretAccount) = operation(SecretStoreError.DeleteFailed) {
        // Clear needs neither the alias nor successful authentication/decryption.
        store.updateData { current ->
            if (account.rawValue !in current.entries) current else SecretRecords(current.entries - account.rawValue)
        }
        Unit
    }

    private fun sealForWrite(value: SecretValue, account: SecretAccount, current: SecretRecords): SecretEnvelope {
        val key = try { keys.read() }
        catch (error: SecretStoreError) {
            if (error != SecretStoreError.Unavailable || current.entries.isNotEmpty()) throw error
            return SecretEnvelope.seal(value, account, keys.replace())
        }
        if (key == null) {
            if (current.entries.isNotEmpty()) throw SecretStoreError.Unavailable
            return SecretEnvelope.seal(value, account, keys.create())
        }

        // Save cannot silently replace a damaged or differently bound credential.
        current.entries[account.rawValue]?.let { SecretEnvelope.open(it, account, key) }
        return try { SecretEnvelope.seal(value, account, key) }
        catch (error: UserNotAuthenticatedException) { throw error }
        catch (error: InvalidKeyException) {
            // Replacing the shared alias would orphan any retained account's ciphertext.
            if (current.entries.isNotEmpty()) throw error
            SecretEnvelope.seal(value, account, keys.replace())
        }
    }

    private suspend fun <T> operation(failure: SecretStoreError, work: suspend () -> T): T = withContext(io) {
        mutex.withLock {
            try { work() }
            catch (error: CancellationException) { throw error }
            catch (error: SecretStoreError) { throw error }
            catch (_: UserNotAuthenticatedException) { throw SecretStoreError.Locked }
            catch (_: KeyPermanentlyInvalidatedException) { throw SecretStoreError.Unavailable }
            catch (_: Exception) { throw failure }
        }
    }
}
