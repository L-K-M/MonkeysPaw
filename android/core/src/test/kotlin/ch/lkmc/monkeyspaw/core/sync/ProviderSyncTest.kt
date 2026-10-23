package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.sync.ProviderSyncOutcome
import ch.lkmc.monkeyspaw.core.ports.HttpMethod
import ch.lkmc.monkeyspaw.core.ports.HttpRequest
import ch.lkmc.monkeyspaw.core.ports.HttpResponse
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.services.MemoryStore
import ch.lkmc.monkeyspaw.core.services.ProviderFakeSecrets
import ch.lkmc.monkeyspaw.core.services.ProviderRecordingState
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsService
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsStore
import ch.lkmc.monkeyspaw.core.services.ProviderSyncKeyError
import ch.lkmc.monkeyspaw.core.services.ProviderSyncKeyService
import ch.lkmc.monkeyspaw.core.services.SyncFlushes
import ch.lkmc.monkeyspaw.core.services.SyncTestValues
import ch.lkmc.monkeyspaw.core.syncapi.ProviderSettingsDocument
import ch.lkmc.monkeyspaw.core.syncapi.ProviderSettingsResponse
import ch.lkmc.monkeyspaw.core.syncapi.PutProviderSettingsRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProviderSyncTest {
    private val user = SyncTestValues.user
    private val keyBytes = ByteArray(32) { it.toByte() }
    private val nonce get() = hex("cafebabefacedbaddecaf888")

    private fun hex(text: String): ByteArray =
        ByteArray(text.length / 2) { text.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    // McGrew–Viega AES-256-GCM test case 13 verbatim: K, IV, P, A, C and T,
    // shared with the Swift tests.
    @Test fun sealMatchesTheSharedVector() {
        val key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
        val plaintext = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.GCMParameterSpec(128, nonce))
        cipher.updateAAD(hex("feedfacedeadbeeffeedfacedeadbeefabaddad2"))
        val sealed = cipher.doFinal(plaintext)
        assertEquals("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa" +
            "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662" + "76fc6ece0f4e1768cddf8853bb2d551b",
            sealed.joinToString("") { "%02x".format(it.toInt() and 255) })
    }

    @Test fun documentRoundTripsWithVersionByteAndNonce() {
        val plaintext = "{\"secrets\":{},\"settings\":{},\"version\":1}".encodeToByteArray()
        val document = ProviderSyncCipher.seal(keyBytes, user, plaintext) { nonce }
        val bytes = Base64URL.decode(document)!!
        assertEquals(0x01.toByte(), bytes[0])
        assertContentEquals(nonce, bytes.copyOfRange(1, 13))
        assertEquals(1 + 12 + plaintext.size + 16, bytes.size)
        assertContentEquals(plaintext, ProviderSyncCipher.open(document, keyBytes, user))
    }

    @Test fun tamperingAndWrongAccountFailAuthentication() {
        val document = ProviderSyncCipher.seal(keyBytes, user, "payload".encodeToByteArray()) { nonce }
        val bytes = Base64URL.decode(document)!!
        for (index in listOf(bytes.size - 1, bytes.size - 17, 14)) {
            val copy = bytes.copyOf().also { it[index] = (it[index].toInt() xor 0x40).toByte() }
            assertFailsWith<ProviderSyncError.Authentication> {
                ProviderSyncCipher.open(Base64URL.encode(copy), keyBytes, user)
            }
        }
        assertFailsWith<ProviderSyncError.Authentication> {
            ProviderSyncCipher.open(document, keyBytes, SyncTestValues.otherUser)
        }
        assertFailsWith<ProviderSyncError.Authentication> {
            ProviderSyncCipher.open(document, keyBytes.copyOf().also { it[0] = (it[0] + 1).toByte() }, user)
        }
    }

    @Test fun malformedDocumentsAndKeysAreTyped() {
        for (document in listOf("", "!!!", "AQAB", Base64URL.encode(byteArrayOf(1, 2)),
            "AA==", "a")) {
            assertFailsWith<ProviderSyncError.InvalidDocument>(document) {
                ProviderSyncCipher.open(document, keyBytes, user)
            }
        }
        // An empty-plaintext envelope is valid wire format; it fails at the tag.
        assertFailsWith<ProviderSyncError.Authentication> {
            ProviderSyncCipher.open(Base64URL.encode(byteArrayOf(1) + ByteArray(12 + 16)), keyBytes, user)
        }
        assertFailsWith<ProviderSyncError.InvalidKey> {
            ProviderSyncCipher.seal(byteArrayOf(1), user, byteArrayOf(120)) { nonce }
        }
        assertFailsWith<ProviderSyncError.InvalidKey> {
            ProviderSyncCipher.seal(keyBytes, user, byteArrayOf(120)) { byteArrayOf(1) }
        }
        assertFailsWith<ProviderSyncError.InvalidKey> { ProviderSyncCipher.open("AA", byteArrayOf(1), user) }
    }

    @Test fun base64URLRejectsPaddingTailBitsAndNonAlphabet() {
        for (text in listOf("", "a", "AA==", "ab", "abd", "A A", "AA=A")) assertNull(Base64URL.decode(text))
        assertContentEquals(byteArrayOf(0x01), Base64URL.decode("AQ"))
        assertContentEquals(byteArrayOf(0x01, 0x00), Base64URL.decode("AQA"))
        assertEquals("AAECAwQ", Base64URL.encode(Base64URL.decode("AAECAwQ")!!))
        for (count in 1..64) {
            val bytes = ByteArray(count) { (it * 37).toByte() }
            assertContentEquals(bytes, Base64URL.decode(Base64URL.encode(bytes)))
        }
    }

    @Test fun payloadRoundTripAndStrictShape() {
        val settings = JsonObject(mapOf("version" to JsonPrimitive(1), "profiles" to kotlinx.serialization.json.JsonArray(emptyList()),
            "selectedProfileID" to kotlinx.serialization.json.JsonNull, "future" to JsonObject(mapOf("nested" to JsonPrimitive(1)))))
        val payload = ProviderSyncPayload(settings, mapOf("provider:550e8400-e29b-41d4-a716-446655440000" to "envelope"))
        val decoded = ProviderSyncPayload.parse(payload.encode())
        assertEquals(payload.settings, decoded.settings)
        assertEquals(payload.secrets, decoded.secrets)

        for (text in listOf("""{"version":1,"settings":{}}""",
            """{"version":1,"settings":{},"secrets":{},"extra":0}""",
            """{"version":2,"settings":{},"secrets":{}}""",
            """{"version":true,"settings":{},"secrets":{}}""",
            """{"version":1.5,"settings":{},"secrets":{}}""",
            """{"version":1,"settings":[],"secrets":{}}""",
            """{"version":1,"settings":{},"secrets":{"provider:x":5}}""",
            """{"version":1,"settings":{},"secrets":{"not-an-account":"e"}}""")) {
            assertFailsWith<ProviderSyncError.InvalidDocument>(text) { ProviderSyncPayload.parse(text.encodeToByteArray()) }
        }
    }

    private inner class Rig {
        val data = MemoryStore()
        val flushes = SyncFlushes()
        val providerFiles = ProviderRecordingState()
        val secrets = ProviderFakeSecrets()
        val entropy = ch.lkmc.monkeyspaw.core.ports.Entropy { count -> ByteArray(count) { i -> i.toByte() } }
        val store = ProviderSettingsStore(providerFiles)
        val service = ProviderSettingsService(store, secrets, Dispatchers.Unconfined)
        val keys = ProviderSyncKeyService(secrets, entropy)
        val step = ProviderSyncStep(data, flushes, service, keys, entropy)
        val requests = mutableListOf<HttpRequest>()
        var remoteRev = 0L
        var remoteDocument: String? = null
        val transport = HttpTransport { request ->
            requests.add(request)
            when (request.method) {
                HttpMethod.GET -> HttpResponse(200, body = ProviderSettingsDocument.codec.encode(
                    ProviderSettingsDocument(remoteRev, remoteDocument, null)))
                else -> HttpResponse(200, body = ProviderSettingsResponse.codec.encode(ProviderSettingsResponse(++remoteRev)))
            }
        }
        val server = SyncServerURL(SyncTestValues.accountIdentity().serverURL)
        val client = SyncHTTPClient(server, transport, SyncCredential(server, SecretValue("A".repeat(43))))
        val identity = SyncTestValues.accountIdentity()
        val permit = SyncWorkPermit(SyncTestValues.binding(account = identity), 0)
        suspend fun provision() = keys.enterKey(user, Base64URL.encode(keyBytes))

        fun remotePayload(settings: JsonObject, secrets: Map<String, String>): String {
            val plaintext = ProviderSyncPayload(settings, secrets).encode()
            return ProviderSyncCipher.seal(keyBytes, user, plaintext) { nonce }
        }
    }

    @Test fun keyServiceGeneratesEntersAndRemoves() = runTest {
        val rig = Rig()
        val generated = rig.keys.generateKey(user)
        assertEquals(43, generated.length)
        assertContentEquals(ByteArray(32) { it.toByte() }, Base64URL.decode(generated))
        assertEquals(SecretAccount.providerSync(user).rawValue, "provider-sync:${user.rawValue}")
        assertNotNull(rig.keys.tier(user))
        assertFailsWith<ProviderSyncKeyError.InvalidKey> { rig.keys.enterKey(user, "AAAA") }
        assertFailsWith<ProviderSyncKeyError.InvalidKey> { rig.keys.enterKey(user, Base64URL.encode(ByteArray(31))) }
        rig.keys.removeKey(user)
        assertNull(rig.keys.tier(user))
    }

    @Test fun keyRequiredWithoutProvisioning() = runTest {
        val rig = Rig()
        assertEquals(ProviderSyncOutcome.KEY_REQUIRED, rig.step.run(rig.client, rig.identity, rig.permit))
        assertTrue(rig.requests.isEmpty())
    }

    @Test fun decryptFailedOnOpaqueRemote() = runTest {
        val rig = Rig()
        rig.provision()
        rig.remoteRev = 3
        rig.remoteDocument = Base64URL.encode(byteArrayOf(1) + ByteArray(12) + byteArrayOf(9, 9) + ByteArray(16))
        // The remote is unreadable but must not stall sync: literal
        // last-writer-wins overwrites it this pass so key rotation self-heals.
        assertEquals(ProviderSyncOutcome.DECRYPT_FAILED, rig.step.run(rig.client, rig.identity, rig.permit))
        assertTrue(rig.providerFiles.memory.listFiles().none { it.relativePath == "provider-settings.json" })
        val put = rig.requests.single { it.method == HttpMethod.PUT }
        val payload = ProviderSyncPayload.parse(ProviderSyncCipher.open(
            PutProviderSettingsRequest.codec.decode(put.body!!).document, keyBytes, user))
        assertEquals(emptyMap(), payload.secrets)
        // The next pass sees our own document and settles unchanged.
        rig.remoteDocument = PutProviderSettingsRequest.codec.decode(put.body!!).document
        rig.remoteRev = 4
        rig.requests.clear()
        assertEquals(ProviderSyncOutcome.UNCHANGED, rig.step.run(rig.client, rig.identity, rig.permit))
        assertTrue(rig.requests.none { it.method == HttpMethod.PUT })
    }

    @Test fun metadataWriteFailureRollsBackSecretMutations() = runTest {
        val rig = Rig()
        rig.provision()
        val profileID = "550e8400-e29b-41d4-a716-446655440000"
        val account = "provider:$profileID"
        val secretAccount = SecretAccount.provider(
            ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID.parse(profileID))
        val local = JsonObject(mapOf(
            "version" to JsonPrimitive(1),
            "selectedProfileID" to JsonPrimitive(profileID),
            "profiles" to kotlinx.serialization.json.JsonArray(listOf(JsonObject(mapOf(
                "id" to JsonPrimitive(profileID), "displayName" to JsonPrimitive("Mine"),
                "kind" to JsonPrimitive("anthropic"), "baseURL" to JsonPrimitive("https://api.anthropic.com"),
                "modelID" to JsonPrimitive("m"), "secretReference" to JsonPrimitive(account)))))))
        rig.providerFiles.memory.put(local.toString(), "provider-settings.json")
        rig.secrets.persisted[secretAccount] = ch.lkmc.monkeyspaw.core.domain.llm.StoredSecret(
            SecretValue("local-envelope"), ch.lkmc.monkeyspaw.core.domain.llm.SecretTier.KEYSTORE)
        // The remote rewrites the secret, then the metadata write fails: the
        // rollback contract must restore the local envelope.
        rig.remoteDocument = rig.remotePayload(local, mapOf(account to "remote-envelope"))
        rig.remoteRev = 2
        rig.providerFiles.failNextWrite = true
        assertEquals(ProviderSyncOutcome.APPLY_FAILED, rig.step.run(rig.client, rig.identity, rig.permit))
        rig.secrets.persisted[secretAccount]!!.value.withValue {
            assertEquals("local-envelope", it)
        }
        assertTrue(rig.requests.none { it.method == HttpMethod.PUT })
    }

    @Test fun firstSyncUploadsEncryptedDocument() = runTest {
        val rig = Rig()
        rig.provision()
        assertEquals(ProviderSyncOutcome.SYNCED, rig.step.run(rig.client, rig.identity, rig.permit))
        val put = rig.requests.single { it.method == HttpMethod.PUT }
        val document = PutProviderSettingsRequest.codec.decode(put.body!!).document
        val payload = ProviderSyncPayload.parse(ProviderSyncCipher.open(document, keyBytes, user))
        assertEquals(emptyMap(), payload.secrets)
        assertEquals(1, payload.settings["version"]?.let { (it as JsonPrimitive).content.toInt() })
        val record = ProviderSyncRecord.codec.decode(
            SyncTestValues.raw(rig.data, "sync/provider-settings.json"))
        assertEquals(1, record.rev)
    }

    @Test fun remoteNewerAppliesAndCarriesSecretForward() = runTest {
        val rig = Rig()
        rig.provision()
        val profileID = "550e8400-e29b-41d4-a716-446655440000"
        val account = "provider:$profileID"
        val remoteSettings = JsonObject(mapOf(
            "version" to JsonPrimitive(1),
            "selectedProfileID" to JsonPrimitive(profileID),
            "profiles" to kotlinx.serialization.json.JsonArray(listOf(JsonObject(mapOf(
                "id" to JsonPrimitive(profileID), "displayName" to JsonPrimitive("Remote"),
                "kind" to JsonPrimitive("anthropic"), "baseURL" to JsonPrimitive("https://api.anthropic.com"),
                "modelID" to JsonPrimitive("claude-opus-4-7"), "secretReference" to JsonPrimitive(account)))))))
        rig.remoteDocument = rig.remotePayload(remoteSettings, mapOf(account to "{\"version\":1,\"kind\":\"anthropic\",\"key\":\"k\",\"origin\":\"x\"}"))
        rig.remoteRev = 5
        // The remote document applies locally; the export is identical, so the pass is unchanged.
        assertEquals(ProviderSyncOutcome.UNCHANGED, rig.step.run(rig.client, rig.identity, rig.permit))
        val stored = rig.secrets.persisted[SecretAccount.provider(ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID.parse(profileID))]
        assertNotNull(stored)
        val written = rig.providerFiles.memory.text("provider-settings.json")
        assertTrue(written.contains(profileID))
        // A second pass stays unchanged without another PUT.
        rig.requests.clear()
        assertEquals(ProviderSyncOutcome.UNCHANGED, rig.step.run(rig.client, rig.identity, rig.permit))
        assertTrue(rig.requests.none { it.method == HttpMethod.PUT })
    }

    @Test fun missingLocalSecretCarriesRemoteEntryIntoUpload() = runTest {
        val rig = Rig()
        rig.provision()
        val profileID = "550e8400-e29b-41d4-a716-446655440001"
        val account = "provider:$profileID"
        // Local metadata references the account but this device never stored the key.
        val local = JsonObject(mapOf(
            "version" to JsonPrimitive(1),
            "selectedProfileID" to kotlinx.serialization.json.JsonNull,
            "profiles" to kotlinx.serialization.json.JsonArray(listOf(JsonObject(mapOf(
                "id" to JsonPrimitive(profileID), "displayName" to JsonPrimitive("Local"),
                "kind" to JsonPrimitive("anthropic"), "baseURL" to JsonPrimitive("https://api.anthropic.com"),
                "modelID" to JsonPrimitive("m"), "secretReference" to JsonPrimitive(account)))))))
        rig.remoteDocument = rig.remotePayload(local, mapOf(account to "remote-envelope"))
        rig.remoteRev = 2
        // Remote rev is newer than baseline 0: metadata applies, then the export
        // carries the remote secret entry back instead of erasing it.
        assertEquals(ProviderSyncOutcome.UNCHANGED, rig.step.run(rig.client, rig.identity, rig.permit))
        // Now edit locally without provisioning the secret; the next pass uploads
        // and still carries the remote envelope forward.
        rig.secrets.persisted.remove(SecretAccount.provider(ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID.parse(profileID)))
        rig.service.selectProfile(ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID.parse(profileID))
        assertEquals(ProviderSyncOutcome.SYNCED, rig.step.run(rig.client, rig.identity, rig.permit))
        val put = rig.requests.last { it.method == HttpMethod.PUT }
        val payload = ProviderSyncPayload.parse(ProviderSyncCipher.open(
            PutProviderSettingsRequest.codec.decode(put.body!!).document, keyBytes, user))
        assertEquals("remote-envelope", payload.secrets[account])
    }
}
