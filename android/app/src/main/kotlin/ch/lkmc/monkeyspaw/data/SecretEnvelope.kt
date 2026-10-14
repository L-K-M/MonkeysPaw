package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Immutable ciphertext only; neither the key nor the credential payload is metadata. */
internal data class SecretEnvelope(val iv: String, val ciphertext: String) {
    init {
        require(Base64.getDecoder().decode(iv).size == IV_BYTES)
        require(Base64.getDecoder().decode(ciphertext).size >= TAG_BITS / 8)
    }

    override fun toString(): String = "<encrypted secret redacted>"

    companion object {
        const val VERSION = 1
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        fun seal(value: SecretValue, account: SecretAccount, key: SecretKey): SecretEnvelope {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            // AndroidKeyStore rejects caller-supplied encryption IVs for randomized keys.
            cipher.init(Cipher.ENCRYPT_MODE, key)
            require(cipher.parameters.getParameterSpec(GCMParameterSpec::class.java).tLen == TAG_BITS)
            cipher.updateAAD(aad(account))
            val plaintext = value.withValue { it.encodeToByteArray(throwOnInvalidSequence = true) }
            return try {
                SecretEnvelope(Base64.getEncoder().encodeToString(cipher.iv),
                    Base64.getEncoder().encodeToString(cipher.doFinal(plaintext)))
            } finally { plaintext.fill(0) }
        }

        fun open(envelope: SecretEnvelope, account: SecretAccount, key: SecretKey): SecretValue {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key,
                GCMParameterSpec(TAG_BITS, Base64.getDecoder().decode(envelope.iv)))
            cipher.updateAAD(aad(account))
            val plaintext = cipher.doFinal(Base64.getDecoder().decode(envelope.ciphertext))
            return try {
                SecretValue(plaintext.decodeToString(throwOnInvalidSequence = true))
            } finally { plaintext.fill(0) }
        }

        // Domain separation and account grammar make the record's destination unambiguous.
        private fun aad(account: SecretAccount): ByteArray =
            "ch.lkmc.monkeyspaw:secrets:v$VERSION:${account.rawValue}".encodeToByteArray()
    }
}
