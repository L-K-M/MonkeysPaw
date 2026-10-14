package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ProviderSettingsStoreTest {
    @Test fun absentRecordStartsEmptyWithoutChangingGeneralSettingsOrWriting() = runTest {
        val h = ProviderSettingsHarness()
        val general = "{\"version\":1,\"seedProgress\":\"COMPLETE\"}"
        h.files.memory.put(general, "settings.json")
        assertEquals(ProviderSettings(), h.service.snapshot.settings)
        assertFalse(h.service.snapshot.isReadOnly)
        assertNull(h.files.stamp("provider-settings.json"))
        assertTrue(h.files.attemptedWrites.isEmpty())
        val draft = ProviderDraft()
        h.service.save(draft)
        assertEquals(h.service.snapshot, h.reopen().service.snapshot)
        assertEquals(general, h.files.memory.text("settings.json"))
        assertEquals(draft.id, h.service.snapshot.settings.selectedProfileID)
    }

    @Test fun roundTripPreservesNormalizedEndpointsReferencesOrderAndSelection() = runTest {
        val h = ProviderSettingsHarness()
        val first = ProviderDraft(baseURL = "https://api.anthropic.com/v1/messages/", key = ProviderKeyEdit.typed("fixture-first"))
        val second = ProviderDraft(kind = ProviderKind.OPENAI_COMPATIBLE, displayName = "Local",
            baseURL = "http://localhost:11434/v1/chat/completions", modelID = "manual-model")
        h.service.save(first)
        h.service.save(second)
        h.service.selectProfile(second.id)
        val writes = h.files.attemptedWrites.size
        val reopened = h.reopen()
        assertEquals(h.service.snapshot, reopened.service.snapshot)
        assertEquals(writes, h.files.attemptedWrites.size)
        val profiles = reopened.service.snapshot.settings.profiles
        assertEquals(listOf(first.id, second.id), profiles.map { it.id })
        assertEquals("https://api.anthropic.com", profiles[0].baseURL)
        assertEquals(SecretAccount.provider(first.id), profiles[0].secretReference)
        assertNull(profiles[1].secretReference)
        assertEquals("manual-model", profiles[1].modelID)
        assertEquals(SecretTier.KEYSTORE, reopened.service.secretTier(first.id))
        h.service.selectProfile(null)
        assertNull(h.reopen().service.snapshot.settings.selectedProfileID)
    }

    @Test fun unknownRootAndNestedProfileKeysFollowCanonicalIDsThroughReorderEditAndDeletion() = runTest {
        val h = ProviderSettingsHarness()
        val first = ProviderDraft(displayName = "One")
        val second = ProviderDraft(displayName = "Two")
        h.service.save(first)
        h.service.save(second)
        val unknown = Json.parseToJsonElement("{\"nested\":{\"items\":[1,null,\"kept/雪\"]}}")
        val one = Json.parseToJsonElement("{\"array\":[false,\"one\"]}")
        val two = Json.parseToJsonElement("{\"array\":[true,\"two\"]}")
        h.editProfile(first.id) { it["id"] = JsonPrimitive(first.id.rawValue.uppercase()); it["futureProfile"] = one }
        h.editProfile(second.id) { it["futureProfile"] = two }
        val root = h.json().toMutableMap()
        root["future"] = unknown
        root["profiles"] = JsonArray((root["profiles"] as JsonArray).reversed())
        h.put(JsonObject(root))
        h.service.save(second.copy(displayName = "Two edited"))
        h.service.selectProfile(first.id)
        assertEquals(unknown, h.json()["future"])
        val profiles = (h.json()["profiles"] as JsonArray).associate { value ->
            val profile = value as JsonObject
            (profile["id"] as JsonPrimitive).content to profile["futureProfile"]
        }
        assertEquals(one, profiles[first.id.rawValue])
        assertEquals(two, profiles[second.id.rawValue])
        h.service.deleteProfile(first.id)
        assertEquals(two, ((h.json()["profiles"] as JsonArray).single() as JsonObject)["futureProfile"])
        assertEquals(unknown, h.json()["future"])
    }

    @Test fun corruptFutureUnsupportedAndCrossProfileRecordsArePermanentlyReadOnly() = runTest {
        val id = ProviderProfileID()
        val other = ProviderProfileID()
        val badProfile = "{\"id\":\"${id.rawValue}\",\"displayName\":\"Name\",\"kind\":\"anthropic\",\"baseURL\":\"https://api.anthropic.com\",\"modelID\":\"manual\",\"secretReference\":\"provider:${other.rawValue}\"}"
        val cases = listOf(
            "{\"version\":2,\"profiles\":\"future shape\"}" to ProviderSettingsError.FutureVersion(2),
            "{\"version\":2147483648}" to ProviderSettingsError.FutureVersion(2147483648),
            "{\"version\":0}" to ProviderSettingsError.UnsupportedVersion(0),
            "{\"version\":-1}" to ProviderSettingsError.UnsupportedVersion(-1),
        ) + listOf("{\"version\":true,\"profiles\":[]}", "{\"version\":\"1\",\"profiles\":[]}",
            "{\"version\":1}", "{\"version\":1,\"profiles\":null}", "{",
            "{\"version\":1,\"profiles\":[],\"selectedProfileID\":\"invalid\"}",
            "{\"version\":1,\"profiles\":[$badProfile]}").map { it to ProviderSettingsError.CorruptFile }
        for ((original, expected) in cases) {
            val files = ProviderRecordingState()
            files.memory.put(original, "provider-settings.json")
            val h = ProviderSettingsHarness(files)
            assertEquals(expected, h.service.snapshot.readOnlyError)
            assertEquals(ProviderSettings(), h.service.snapshot.settings)
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.save(ProviderDraft()) })
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.resolveForTesting(ProviderDraft()) })
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.selectProfile(null) })
            assertEquals(original, files.memory.text("provider-settings.json"))
            assertTrue(files.attemptedWrites.isEmpty())
            assertTrue(h.secrets.reads.isEmpty())
        }
    }

    @Test fun invalidUTF8TokensUnicodeAndExcessiveNestingFailClosed() = runTest {
        val corrupt = listOf(byteArrayOf(-1), "{\"version\":1,\"profiles\":[],\"future\":NaN}".encodeToByteArray(),
            "{\"version\":1,\"profiles\":[],\"future\":01}".encodeToByteArray(),
            "{\"version\":1,\"profiles\":[],\"future\":1e999}".encodeToByteArray(),
            "{\"version\":1,\"profiles\":[],\"future\":\"\\ud800\"}".encodeToByteArray(),
            "{\"version\":1,\"profiles\":[],\"future\":\"raw\nnewline\"}".encodeToByteArray(),
            ("{\"version\":1,\"profiles\":[],\"future\":" + "[".repeat(2000) + "0" + "]".repeat(2000) + "}").encodeToByteArray())
        for (bytes in corrupt) {
            val files = ProviderRecordingState()
            files.memory.put(bytes, "provider-settings.json")
            val h = ProviderSettingsHarness(files)
            assertEquals(ProviderSettingsError.CorruptFile, h.service.snapshot.readOnlyError)
            assertFailsWith<ProviderSettingsError.CorruptFile> { h.service.save(ProviderDraft()) }
            assertContentEquals(bytes, files.memory.read("provider-settings.json"))
            assertTrue(h.secrets.reads.isEmpty())
        }
    }

    @Test fun firstVersionMarkerControlsCompatibilityAndTheRewrittenMarkerMustStillBeCurrent() = runTest {
        val cases = listOf(
            "{\"version\":2,\"version\":1,\"profiles\":[]}" to ProviderSettingsError.FutureVersion(2),
            "{\"version\":0,\"version\":1,\"profiles\":[]}" to ProviderSettingsError.UnsupportedVersion(0),
            "{\"version\":1,\"version\":2,\"profiles\":[]}" to ProviderSettingsError.CorruptFile,
            "{\"version\":1,\"ver\\u0073ion\":2,\"profiles\":[]}" to ProviderSettingsError.CorruptFile,
        )
        for ((text, expected) in cases) {
            val files = ProviderRecordingState()
            files.memory.put(text, "provider-settings.json")
            val h = ProviderSettingsHarness(files)
            assertEquals(expected, h.service.snapshot.readOnlyError)
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.save(ProviderDraft()) })
            assertEquals(text, files.memory.text("provider-settings.json"))
        }
    }

    @Test fun maximumFoundationDepthAndQuotedBracketsRemainValidUnknownMetadata() = runTest {
        val depth = Limits.providerSettingsJSONNestingCap - 1
        val original = "{\"version\":1.0,\"profiles\":[],\"future\":" + "[".repeat(depth) + "0" + "]".repeat(depth) + "}"
        val files = ProviderRecordingState()
        files.memory.put(original, "provider-settings.json")
        val h = ProviderSettingsHarness(files)
        assertFalse(h.service.snapshot.isReadOnly)
        h.service.save(ProviderDraft())
        assertEquals(Json.parseToJsonElement(original).jsonObject["future"], h.json()["future"])
        val brackets = JsonPrimitive("[\\\"".repeat(2000))
        h.put(JsonObject(h.json() + ("quoted" to brackets)))
        h.service.selectProfile(null)
        assertEquals(brackets, h.json()["quoted"])
    }

    @Test fun unreadableStateIsSanitizedAndRequiresRecreationEvenAfterIORecovers() = runTest {
        for (failure in listOf(StoreError.IOFailure, IllegalStateException("fixture-only diagnostic"))) {
            val files = ProviderRecordingState()
            files.readError = failure
            val h = ProviderSettingsHarness(files)
            assertEquals(ProviderSettingsError.ReadFailed, h.service.snapshot.readOnlyError)
            files.readError = null
            assertFailsWith<ProviderSettingsError.ReadFailed> { h.service.save(ProviderDraft()) }
            assertFailsWith<ProviderSettingsError.ReadFailed> { h.service.resolveForTesting(ProviderDraft()) }
            assertTrue(files.attemptedWrites.isEmpty())
            val reopened = h.reopen()
            assertFalse(reopened.service.snapshot.isReadOnly)
            reopened.service.save(ProviderDraft())
        }
    }

    @Test fun externalFutureOrCorruptReplacementBlocksEveryCredentialAndMetadataOperation() = runTest {
        for ((text, expected) in listOf("{\"version\":8}" to ProviderSettingsError.FutureVersion(8), "invalid" to ProviderSettingsError.CorruptFile)) {
            val h = ProviderSettingsHarness()
            val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-stored"))
            h.service.save(draft)
            h.files.memory.put(text, "provider-settings.json")
            val reads = h.secrets.reads.size
            val writes = h.secrets.writes.size
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.connection(draft.id) })
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.resolveForTesting(draft) })
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.save(draft) })
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.secretTier(draft.id) })
            assertEquals(expected, assertFailsWith<ProviderSettingsError> { h.service.deleteProfile(draft.id) })
            assertEquals(reads, h.secrets.reads.size)
            assertEquals(writes, h.secrets.writes.size)
            assertEquals(text, h.files.memory.text("provider-settings.json"))
            assertEquals(ProviderSettings(), h.service.snapshot.settings)
        }
    }

    @Test fun failedMetadataWritesPreserveBytesAndSnapshotAndRemainRetryable() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft()
        h.files.failNextWrite = true
        assertFailsWith<ProviderSettingsError.WriteFailed> { h.service.save(draft) }
        assertNull(h.files.stamp("provider-settings.json"))
        assertTrue(h.service.snapshot.settings.profiles.isEmpty())
        h.service.save(draft)
        val before = h.service.snapshot
        val bytes = h.files.read("provider-settings.json")
        h.files.failNextWrite = true
        val edit = draft.copy(displayName = "Changed")
        assertFailsWith<ProviderSettingsError.WriteFailed> { h.service.save(edit) }
        assertEquals(before, h.service.snapshot)
        assertContentEquals(bytes, h.files.read("provider-settings.json"))
        h.service.save(edit)
        assertEquals("Changed", h.service.snapshot.settings.profiles.single().displayName)
        assertEquals(h.service.snapshot, h.reopen().service.snapshot)
    }

    @Test fun duplicateIDsUnknownKindsInvalidSelectionAndUnsafeURLsNeverReachSecrets() = runTest {
        val h = ProviderSettingsHarness()
        h.service.save(ProviderDraft())
        val valid = h.json()
        val profile = (valid["profiles"] as JsonArray).single() as JsonObject
        val replacements = listOf(
            valid + ("profiles" to JsonArray(listOf(profile, profile))),
            valid + ("selectedProfileID" to JsonPrimitive(ProviderProfileID().rawValue)),
        ) + listOf("kind" to "unknown", "baseURL" to "http://remote.example", "baseURL" to "https://remote.example?key=fixture")
            .map { (name, value) -> valid + ("profiles" to JsonArray(listOf(JsonObject(profile + (name to JsonPrimitive(value)))))) }
        for (root in replacements) {
            h.put(JsonObject(root))
            val reopened = h.reopen()
            assertEquals(ProviderSettingsError.CorruptFile, reopened.service.snapshot.readOnlyError)
            assertFailsWith<ProviderSettingsError.CorruptFile> { reopened.service.resolveForTesting(ProviderDraft()) }
            assertTrue(h.secrets.reads.isEmpty())
        }
    }

    @Test fun versionOneMetadataBytesMatchFoundationSortedKeysSlashesUnicodeAndNulls() = runTest {
        val h = ProviderSettingsHarness()
        val id = ProviderProfileID.parse("00000000-0000-4000-8000-000000000011")
        h.service.save(ProviderDraft(id = id, displayName = "One/雪", modelID = "manual/é😀"))
        val expected = """{"profiles":[{"baseURL":"https:\/\/api.anthropic.com","displayName":"One\/雪","id":"00000000-0000-4000-8000-000000000011","kind":"anthropic","modelID":"manual\/é😀","secretReference":null}],"selectedProfileID":"00000000-0000-4000-8000-000000000011","version":1}"""
        assertContentEquals(expected.encodeToByteArray(), h.files.read("provider-settings.json"))
    }

    @Test fun readRevalidationPublishesExternalMetadataWithoutSpeculativeRewrite() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft()
        h.service.save(draft)
        h.editProfile(draft.id) { it["displayName"] = JsonPrimitive("External") }
        val bytes = h.files.read("provider-settings.json")
        val writes = h.files.attemptedWrites.size
        h.service.connection(draft.id)
        assertEquals("External", h.service.snapshot.settings.profiles.single().displayName)
        h.service.save(ProviderDraft(h.service.snapshot.settings.profiles.single()))
        assertEquals(writes, h.files.attemptedWrites.size)
        assertContentEquals(bytes, h.files.read("provider-settings.json"))
    }

    @Test fun servicesSharingOneStoreSerializeCompoundEditsWithoutLosingProfiles() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val h = ProviderSettingsHarness(io = dispatcher)
        val other = ProviderSettingsService(h.store, h.secrets, dispatcher)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        h.secrets.afterWrite = { entered.complete(Unit); release.await() }
        val first = ProviderDraft(key = ProviderKeyEdit.typed("fixture-one"))
        val second = ProviderDraft()
        val saving = launch { h.service.save(first) }
        entered.await()
        val pending = launch { other.save(second) }
        runCurrent()
        assertFalse(pending.isCompleted)
        assertEquals(ProviderSettings(), other.snapshot.settings)
        release.complete(Unit)
        joinAll(saving, pending)
        assertEquals(listOf(first.id, second.id), h.service.snapshot.settings.profiles.map { it.id })
        assertEquals(h.service.snapshot, h.reopen().service.snapshot)
    }
}
