package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.sync.SyncAccountIdentity
import ch.lkmc.monkeyspaw.core.domain.sync.SyncHash
import ch.lkmc.monkeyspaw.core.domain.sync.SyncIdentifiers
import ch.lkmc.monkeyspaw.core.domain.sync.ProviderSyncOutcome
import ch.lkmc.monkeyspaw.core.ports.Entropy
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.SyncFileFlushing
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsService
import ch.lkmc.monkeyspaw.core.services.ProviderSyncKeyService
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsJson
import ch.lkmc.monkeyspaw.core.services.SyncDocumentCodec
import ch.lkmc.monkeyspaw.core.services.SyncPersistence
import ch.lkmc.monkeyspaw.core.syncapi.PutProviderSettingsRequest
import ch.lkmc.monkeyspaw.core.syncapi.WireObject
import ch.lkmc.monkeyspaw.core.syncapi.WireValue
import ch.lkmc.monkeyspaw.core.syncapi.wireLong
import ch.lkmc.monkeyspaw.core.syncapi.wireString
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** §26 S4/S5: typed failures only; payloads, keys and ciphertext never enter
 * error values or diagnostics. */
sealed class ProviderSyncError private constructor() : Exception("Provider sync failed.", null, false, true) {
    data object InvalidKey : ProviderSyncError()
    data object InvalidDocument : ProviderSyncError()
    data object Authentication : ProviderSyncError()
    data object UnsupportedVersion : ProviderSyncError()
    data object Oversized : ProviderSyncError()

    final override fun toString(): String = "<provider sync error>"
}

/** Strict unpadded base64url, used by both the wire document and the key text. */
internal object Base64URL {
    private val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".encodeToByteArray()

    fun encode(bytes: ByteArray): String {
        val result = StringBuilder((bytes.size + 2) / 3 * 4)
        var index = 0
        while (index < bytes.size) {
            val b0 = bytes[index].toInt() and 255
            val b1 = if (index + 1 < bytes.size) bytes[index + 1].toInt() and 255 else 0
            val b2 = if (index + 2 < bytes.size) bytes[index + 2].toInt() and 255 else 0
            result.append(alphabet[b0 shr 2].toInt().toChar())
            result.append(alphabet[(b0 and 0x03) shl 4 or (b1 shr 4)].toInt().toChar())
            if (index + 1 < bytes.size) result.append(alphabet[(b1 and 0x0f) shl 2 or (b2 shr 6)].toInt().toChar())
            if (index + 2 < bytes.size) result.append(alphabet[b2 and 0x3f].toInt().toChar())
            index += 3
        }
        return result.toString()
    }

    fun decode(text: String): ByteArray? {
        val table = ByteArray(128) { -1 }
        for (value in alphabet.indices) table[alphabet[value].toInt()] = value.toByte()
        val scalars = text.encodeToByteArray()
        if (scalars.isEmpty()) return null
        val bytes = ByteArray(scalars.size * 3 / 4)
        var written = 0
        var index = 0
        while (index < scalars.size) {
            val remaining = scalars.size - index
            if (remaining < 2) return null
            val digits = ByteArray(4)
            val count = minOf(4, remaining)
            for (offset in 0 until count) {
                val byte = scalars[index + offset]
                if (byte < 0 || table[byte.toInt()].toInt() == -1) return null
                digits[offset] = table[byte.toInt()]
            }
            // A partial final group must not carry nonzero tail bits.
            if (count == 2 && digits[1].toInt() and 0x0f != 0) return null
            if (count == 3 && digits[2].toInt() and 0x03 != 0) return null
            bytes[written++] = (digits[0].toInt() shl 2 or (digits[1].toInt() shr 4)).toByte()
            if (count >= 3) bytes[written++] = (digits[1].toInt() shl 4 or (digits[2].toInt() shr 2)).toByte()
            if (count == 4) bytes[written++] = (digits[2].toInt() shl 6 or digits[3].toInt()).toByte()
            index += 4
        }
        return bytes.copyOf(written)
    }
}

/** `document` is unpadded base64url of `0x01 ‖ IV(12) ‖ ciphertext ‖ tag(16)`
 * sealed with AES-256-GCM; AAD binds the ciphertext to the sync account. */
internal object ProviderSyncCipher {
    private const val aadPrefix = "monkeyspaw/provider-settings/v1:"

    private fun aad(userID: ULID) = (aadPrefix + userID.rawValue).encodeToByteArray()

    fun seal(key: ByteArray, userID: ULID, plaintext: ByteArray, nonce: () -> ByteArray): String {
        if (key.size != Limits.providerSyncKeyBytes) throw ProviderSyncError.InvalidKey
        if (plaintext.size > Limits.providerSyncPayloadMaxBytes) throw ProviderSyncError.Oversized
        val iv = nonce()
        if (iv.size != Limits.providerSyncNonceBytes) throw ProviderSyncError.InvalidKey
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"),
            GCMParameterSpec(Limits.providerSyncTagBytes * 8, iv))
        cipher.updateAAD(aad(userID))
        val sealed = try { cipher.doFinal(plaintext) }
        catch (_: Exception) { throw ProviderSyncError.Authentication }
        return Base64URL.encode(byteArrayOf(0x01) + iv + sealed)
    }

    fun open(document: String, key: ByteArray, userID: ULID): ByteArray {
        if (key.size != Limits.providerSyncKeyBytes) throw ProviderSyncError.InvalidKey
        val bytes = Base64URL.decode(document)
        if (bytes == null || bytes.size <= 1 + Limits.providerSyncNonceBytes + Limits.providerSyncTagBytes ||
            bytes[0] != 0x01.toByte()) throw ProviderSyncError.InvalidDocument
        val nonce = bytes.copyOfRange(1, 1 + Limits.providerSyncNonceBytes)
        val sealed = bytes.copyOfRange(1 + Limits.providerSyncNonceBytes, bytes.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"),
            GCMParameterSpec(Limits.providerSyncTagBytes * 8, nonce))
        cipher.updateAAD(aad(userID))
        val plaintext = try { cipher.doFinal(sealed) }
        catch (_: Exception) { throw ProviderSyncError.Authentication }
        if (plaintext.size > Limits.providerSyncPayloadMaxBytes) throw ProviderSyncError.Oversized
        return plaintext
    }
}

/** §26 S4: `{"version":1,"settings":<stored object verbatim>,"secrets":{account:envelope}}`.
 * The whole stored settings object survives, including unknown fields. */
internal class ProviderSyncPayload(val settings: JsonObject, val secrets: Map<String, String>) {
    fun encode(): ByteArray {
        val bytes = ProviderSettingsJson.encode(JsonObject(linkedMapOf(
            "version" to JsonPrimitive(version),
            "settings" to settings,
            "secrets" to JsonObject(secrets.mapValues { JsonPrimitive(it.value) }),
        )))
        if (bytes.size > Limits.providerSyncPayloadMaxBytes) throw ProviderSyncError.Oversized
        return bytes
    }

    companion object {
        const val version = 1L

        fun parse(plaintext: ByteArray): ProviderSyncPayload {
            val root = try { ProviderSettingsJson.read(plaintext) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { throw ProviderSyncError.InvalidDocument }
            if (plaintext.size > Limits.providerSyncPayloadMaxBytes || root.keys != setOf("secrets", "settings", "version")) {
                throw ProviderSyncError.InvalidDocument
            }
            val version = (root["version"] as? JsonPrimitive)?.takeUnless { it.isString }
                ?.let { runCatching { it.content.toBigDecimal().longValueExact() }.getOrNull() }
            if (version != ProviderSyncPayload.version) throw ProviderSyncError.InvalidDocument
            val settings = root["settings"] as? JsonObject ?: throw ProviderSyncError.InvalidDocument
            val rawSecrets = root["secrets"] as? JsonObject ?: throw ProviderSyncError.InvalidDocument
            if (rawSecrets.size > Limits.providerSyncSecretEntries) throw ProviderSyncError.InvalidDocument
            val secrets = rawSecrets.mapValues { (account, value) ->
                val envelope = (value as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: throw ProviderSyncError.InvalidDocument
                if (envelope.encodeToByteArray().size > Limits.providerSyncSecretBytes) {
                    throw ProviderSyncError.InvalidDocument
                }
                try { SecretAccount.parse(account) }
                catch (_: Exception) { throw ProviderSyncError.InvalidDocument }
                envelope
            }
            return ProviderSyncPayload(settings, secrets)
        }
    }
}

/** §26 S8: the per-account baseline `<data>/sync/provider-settings.json`.
 * A server/user mismatch resets rev to 0. */
internal data class ProviderSyncRecord(val serverURL: String, val userID: String, val rev: Long, val payloadHash: String) {
    companion object {
        val codec = SyncDocumentCodec(Limits.providerSyncRecordVersion, { value ->
            val o = WireObject(value)
            SyncIdentifiers.version(o.long("version"), Limits.providerSyncRecordVersion)
            ProviderSyncRecord(o.string("server_url"), o.string("user_id"),
                o.long("rev", minimum = 0), o.string("payload_hash"))
        }, {
            WireValue.ObjectValue(mapOf("version" to wireLong(Limits.providerSyncRecordVersion.toLong()),
                "server_url" to wireString(it.serverURL), "user_id" to wireString(it.userID),
                "rev" to wireLong(it.rev), "payload_hash" to wireString(it.payloadHash)))
        })
    }
}

/** Composition supplies the step's inputs; the step itself stays internal. */
class ProviderSyncInput(val providers: ProviderSettingsService, val keys: ProviderSyncKeyService)

/** The pull-then-push provider-settings step inside one coordinator pass. */
internal class ProviderSyncStep(
    files: StateStore, operations: SyncFileFlushing,
    private val providers: ProviderSettingsService,
    private val keys: ProviderSyncKeyService,
    private val entropy: Entropy,
) {
    private val records = SyncPersistence(files, operations, "sync/provider-settings.json", ProviderSyncRecord.codec)

    suspend fun run(client: SyncHTTPClient, identity: SyncAccountIdentity, permit: SyncWorkPermit): ProviderSyncOutcome {
        val remote = client.providerSettings()
        permit.check()
        val key = keys.keyBytes(identity.userID) ?: return ProviderSyncOutcome.KEY_REQUIRED

        var baseline = records.load()
        if (baseline?.serverURL != identity.serverURL || baseline?.userID != identity.userID.rawValue) baseline = null
        var known = baseline ?: ProviderSyncRecord(identity.serverURL, identity.userID.rawValue, 0, "")

        // The pulled document is S6's "last decrypted remote document".
        var remoteSecrets = emptyMap<String, String>()
        remote.document?.let { document ->
            try {
                val plaintext = ProviderSyncCipher.open(document, key, identity.userID)
                val payload = ProviderSyncPayload.parse(plaintext)
                remoteSecrets = payload.secrets
                if (remote.rev > known.rev) {
                    providers.applySynced(payload.settings, payload.secrets)
                    known = ProviderSyncRecord(known.serverURL, known.userID,
                        remote.rev, SyncHash.of(plaintext).rawValue)
                }
            } catch (error: ProviderSyncError) {
                return when (error) {
                    ProviderSyncError.InvalidDocument, ProviderSyncError.Authentication,
                    ProviderSyncError.UnsupportedVersion, ProviderSyncError.InvalidKey ->
                        ProviderSyncOutcome.DECRYPT_FAILED
                    else -> ProviderSyncOutcome.APPLY_FAILED
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { return ProviderSyncOutcome.APPLY_FAILED }
        }

        val plaintext = try { providers.exportSyncPayload(remoteSecrets).encode() }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { return ProviderSyncOutcome.APPLY_FAILED }
        val hash = SyncHash.of(plaintext).rawValue

        if (remote.rev == known.rev && hash == known.payloadHash) {
            if (baseline != known) records.update { known }
            return ProviderSyncOutcome.UNCHANGED
        }
        val document = ProviderSyncCipher.seal(key, identity.userID, plaintext) {
            entropy.bytes(Limits.providerSyncNonceBytes)
        }
        val response = client.putProviderSettings(PutProviderSettingsRequest(document))
        records.update { ProviderSyncRecord(known.serverURL, known.userID, response.rev, hash) }
        return ProviderSyncOutcome.SYNCED
    }
}
