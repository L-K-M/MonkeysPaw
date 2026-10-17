package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.security.MessageDigest

/** JVM-only disposable plaintext secrets, persisted at 0600 for graph/process restart. */
internal class FixtureSecretStore(private val files: DiskSyncFiles) : SecretStore {
    override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? = try {
        val path = path(account)
        if (files.stamp(path) == null) null else StoredSecret(SecretValue(files.read(path).decodeToString(throwOnInvalidSequence = true)), SecretTier.KEYSTORE)
    } catch (_: Exception) { throw SecretStoreError.ReadFailed }
    override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier = try {
        val path = path(account)
        files.writePrivate(value.withValue { it.encodeToByteArray(throwOnInvalidSequence = true) }, path)
        files.operations.flushFile(path)
        files.operations.flushDirectory(null)
        SecretTier.KEYSTORE
    } catch (_: Exception) { throw SecretStoreError.WriteFailed }
    override suspend fun delete(account: SecretAccount) {
        try {
            val path = path(account)
            if (files.stamp(path) != null) files.delete(path)
            files.operations.flushDirectory(null)
        } catch (_: Exception) { throw SecretStoreError.DeleteFailed }
    }
    private fun path(account: SecretAccount): String = MessageDigest.getInstance("SHA-256")
        .digest(account.rawValue.encodeToByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
}
