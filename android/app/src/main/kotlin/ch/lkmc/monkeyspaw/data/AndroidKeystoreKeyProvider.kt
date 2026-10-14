package ch.lkmc.monkeyspaw.data

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import androidx.annotation.RequiresApi
import ch.lkmc.monkeyspaw.core.domain.llm.SecretStoreError
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

internal interface SecretKeyProvider {
    /** Lookup only. A missing key must never cause implicit generation. */
    fun read(): SecretKey?
    /** Only called after the complete ciphertext store is known to be empty. */
    fun create(): SecretKey
    /** Delete an unusable alias and create a key only when no ciphertext remains. */
    fun replace(): SecretKey
}

internal enum class KeystoreBacking { STRONGBOX, KEYSTORE }
internal class StrongBoxUnavailable : Exception("strongBoxUnavailable", null)

/** The native boundary translates only StrongBoxUnavailableException into this retry signal. */
internal object StrongBoxPolicy {
    fun generate(api: Int, hasStrongBox: Boolean, generate: (KeystoreBacking) -> SecretKey): SecretKey {
        if (api < 28 || !hasStrongBox) return generate(KeystoreBacking.KEYSTORE)

        return try { generate(KeystoreBacking.STRONGBOX) }
        catch (_: StrongBoxUnavailable) { generate(KeystoreBacking.KEYSTORE) }
    }
}

internal class AndroidKeystoreKeyProvider(private val context: Context) : SecretKeyProvider {
    override fun read(): SecretKey? = sanitized {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        if (!store.containsAlias(ALIAS)) return@sanitized null
        store.getKey(ALIAS, null) as? SecretKey ?: throw SecretStoreError.Unavailable
    }

    override fun create(): SecretKey = sanitized {
        // A failed DataStore publication can leave a key behind. Reuse it on retry.
        read() ?: StrongBoxPolicy.generate(Build.VERSION.SDK_INT,
            Build.VERSION.SDK_INT >= 28 && context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE),
            ::generate)
    }

    override fun replace(): SecretKey = sanitized {
        KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS)
        create()
    }

    private fun generate(backing: KeystoreBacking): SecretKey {
        val builder = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(false)
        if (Build.VERSION.SDK_INT >= 28 && backing == KeystoreBacking.STRONGBOX) builder.setIsStrongBoxBacked(true)

        return try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).run {
                init(builder.build())
                generateKey()
            }
        } catch (error: Exception) {
            if (Build.VERSION.SDK_INT >= 28 && causedByStrongBox(error)) throw StrongBoxUnavailable()
            throw error
        }
    }

    // Some keystores wrap the StrongBox failure in a ProviderException.
    @RequiresApi(28)
    private fun causedByStrongBox(error: Throwable): Boolean =
        generateSequence(error) { it.cause }.any { it is StrongBoxUnavailableException }

    private fun <T> sanitized(work: () -> T): T = try { work() }
    catch (_: UserNotAuthenticatedException) { throw SecretStoreError.Locked }
    catch (error: SecretStoreError) { throw error }
    catch (_: Exception) { throw SecretStoreError.Unavailable }

    companion object {
        private const val PROVIDER = "AndroidKeyStore"
        private const val ALIAS = "ch.lkmc.monkeyspaw.secrets.v1"
    }
}
