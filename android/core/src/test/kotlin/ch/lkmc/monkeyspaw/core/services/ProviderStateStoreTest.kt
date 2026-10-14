package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.test.*

/** Behavioral cases ported from Swift ProviderStateStoreTests; no Android driver is involved. */
class ProviderStateStoreTest {
    @Test fun formatsHaveTheSharedWireNamesAndOnlyTwoDowngrades() {
        assertEquals(listOf("json_schema", "json_object", "none"), OpenAIResponseFormat.entries.map { it.rawValue })
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, OpenAIResponseFormat.JSON_SCHEMA.lower)
        assertEquals(OpenAIResponseFormat.NONE, OpenAIResponseFormat.JSON_OBJECT.lower)
        assertNull(OpenAIResponseFormat.NONE.lower)
    }

    @Test fun absentStateStartsAtSchemaWithoutWritingOrTouchingProviderSettings() {
        val files = CapabilityFiles()
        val settings = """{"version":1,"profiles":[],"future":"keep"}"""
        files.memory.put(settings, "provider-settings.json")
        val store = ProviderStateStore(files)
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection()))
        assertNull(files.memory.stamp(path))
        assertEquals(listOf(path), files.memory.reads)
        assertEquals(settings, files.memory.text("provider-settings.json"))
        assertTrue(files.attemptedWrites.isEmpty())
    }

    @Test fun unobservedConnectionsAndSchemaSuccessDoNotLearn() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val connection = connection()
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        store.format(connection)
        store.recordSuccess(OpenAIResponseFormat.JSON_SCHEMA, connection)
        assertTrue(files.attemptedWrites.isEmpty())
        assertNull(files.memory.stamp(path))
    }

    @Test fun validatedLowerFormatsRoundTripWithProfileIsolationAndNoSecrets() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val sentinel = "credential-only-sentinel"
        val first = connection(key = sentinel)
        val second = connection(key = sentinel)
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(first))
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, first)
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(second))
        store.recordSuccess(OpenAIResponseFormat.NONE, second)
        val reopened = ProviderStateStore(files)
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, reopened.format(first))
        assertEquals(OpenAIResponseFormat.NONE, reopened.format(second))
        val objectValue = json(files)
        assertEquals(JsonPrimitive(1), objectValue["version"])
        assertEquals(setOf("version", "profiles"), objectValue.keys)
        val profiles = profiles(objectValue)
        assertEquals(2, profiles.size)
        profiles.forEach { assertEquals(setOf("id", "kind", "baseURL", "modelID", "format"), it.keys) }
        files.attemptedWrites.forEach { assertFalse(it.decodeToString().contains(sentinel)) }
        assertEquals("<provider capability state>", store.toString())
    }

    @Test fun storedBytesMatchTheSwiftCompactEscapingProfile() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val connection = connection(id = ProviderProfileID.parse("12345678-1234-1234-1234-123456789abc"),
            model = "模型/\"\\😀")
        store.format(connection)
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, connection)
        // Generated independently with Swift JSONSerialization(.sortedKeys), not the Kotlin writer.
        val expected = """{"profiles":[{"baseURL":"https:\/\/api.openai.com\/v1","format":"json_object","id":"12345678-1234-1234-1234-123456789abc","kind":"openaiCompatible","modelID":"模型\/\"\\😀"}],"version":1}"""
        assertContentEquals(expected.encodeToByteArray(), files.memory.read(path))
        assertFalse(files.memory.text(path).endsWith('\n'))
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, ProviderStateStore(files).format(connection))
    }

    @Test fun unknownRootAndProfileKeysSurviveNormalizedIDRewritesAndInvalidation() {
        val files = CapabilityFiles()
        val connection = connection()
        val other = connection()
        val future = Json.parseToJsonElement("""{"items":[1,null,"/\u0000\b\f\n\r\té😀"]}""")
        val firstEntry = JsonObject(entry(connection, OpenAIResponseFormat.JSON_OBJECT) + mapOf(
            "id" to JsonPrimitive(connection.profileID.rawValue.uppercase()),
            "baseURL" to JsonPrimitive("HTTPS://API.OPENAI.COM.:443/v1/chat/completions/"), "futureProfile" to future))
        val otherEntry = JsonObject(entry(other, OpenAIResponseFormat.NONE) + ("otherFuture" to JsonPrimitive(true)))
        files.memory.put(payload(listOf(firstEntry, otherEntry), mapOf("futureRoot" to future)), path)
        val store = ProviderStateStore(files)
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, store.format(connection))
        assertTrue(files.attemptedWrites.isEmpty())
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        val changed = connection(id = connection.profileID, model = "other-model")
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(changed))
        val rewritten = json(files)
        assertEquals(future, rewritten["futureRoot"])
        val retained = profiles(rewritten).first()
        assertEquals(future, retained["futureProfile"])
        assertEquals(JsonPrimitive(connection.profileID.rawValue), retained["id"])
        assertEquals(JsonPrimitive(connection.baseURL), retained["baseURL"])
        assertEquals(JsonPrimitive("other-model"), retained["modelID"])
        assertEquals(JsonPrimitive("json_schema"), retained["format"])
        assertEquals(otherEntry, profiles(rewritten)[1])
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection))
        assertEquals(OpenAIResponseFormat.NONE, store.format(other))
    }

    @Test fun kindOriginPathAndModelChangesResetEvenAfterReturningToOldIdentity() {
        val id = ProviderProfileID()
        val original = connection(id = id)
        val changes = listOf(connection(id = id, model = "different-model"),
            connection(id = id, base = "https://other.example/v1"),
            connection(id = id, base = "https://api.openai.com:444/v1"),
            connection(id = id, base = "https://api.openai.com/custom/v1"),
            connection(id = id, base = "https://localhost/v1"),
            connection(id = id, base = "http://localhost/v1"),
            connection(id = id, kind = ProviderKind.ANTHROPIC))
        for (changed in changes) {
            val files = CapabilityFiles()
            val store = ProviderStateStore(files)
            store.format(original)
            store.recordSuccess(OpenAIResponseFormat.NONE, original)
            assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(changed))
            assertEquals(OpenAIResponseFormat.JSON_SCHEMA, ProviderStateStore(files).format(changed))
            assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(original))
            assertEquals(OpenAIResponseFormat.JSON_SCHEMA, ProviderStateStore(files).format(original))
        }
    }

    @Test fun equivalentNormalizedBaseAndKeyRotationRetainCapability() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val first = connection()
        store.format(first)
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, first)
        val equivalent = connection(id = first.profileID, base = "HTTPS://API.OPENAI.COM.:443/v1/models/", key = "new-key")
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, store.format(equivalent))
        assertEquals(1, files.attemptedWrites.size)
    }

    @Test fun olderSuccessCannotOverwriteANewlyObservedModel() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val old = connection()
        val new = connection(id = old.profileID, model = "new-model")
        store.format(old)
        store.format(new)
        store.recordSuccess(OpenAIResponseFormat.NONE, old)
        assertTrue(files.attemptedWrites.isEmpty())
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, new)
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, store.format(new))
    }

    @Test fun olderSuccessCannotOverwriteAnExternallyChangedIdentity() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val old = connection()
        store.format(old)
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, old)
        val new = connection(id = old.profileID, model = "externally-changed-model")
        val replacement = payload(listOf(entry(new, OpenAIResponseFormat.NONE)))
        files.memory.put(replacement, path)
        val writes = files.attemptedWrites.size
        store.recordSuccess(OpenAIResponseFormat.NONE, old)
        assertEquals(replacement, files.memory.text(path))
        assertEquals(writes, files.attemptedWrites.size)
    }

    @Test fun outOfOrderSuccessCannotForgetAnAlreadyRejectedLowerFormat() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val connection = connection()
        store.format(connection)
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, connection)
        store.recordSuccess(OpenAIResponseFormat.JSON_SCHEMA, connection)
        assertEquals(OpenAIResponseFormat.NONE, store.format(connection))
        assertEquals(1, files.attemptedWrites.size)
    }

    @Test fun readOutageAndFailedResetCannotLetStaleSuccessUpgradeCurrentCapability() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val original = connection()
        val changed = connection(id = original.profileID, model = "new-model")
        store.format(original)
        store.recordSuccess(OpenAIResponseFormat.NONE, original)
        val before = files.memory.read(path)
        files.readFailure = StoreError.IOFailure
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(changed))
        files.readFailure = null
        files.nextWriteFailure = StoreError.IOFailure
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(original))
        val writes = files.attemptedWrites.size
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, original)
        assertEquals(writes, files.attemptedWrites.size)
        assertContentEquals(before, files.memory.read(path))
        assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(original))
    }

    @Test fun readableCorruptionFutureVersionsAndInvalidEntriesHealOnlyAfterValidatedLearning() {
        val connection = connection()
        val valid = entry(connection, OpenAIResponseFormat.JSON_OBJECT)
        val badFields = listOf("id" to JsonPrimitive("invalid"), "id" to JsonPrimitive(7),
            "kind" to JsonPrimitive("unknown"), "baseURL" to JsonPrimitive("http://remote.example"),
            "baseURL" to JsonPrimitive("https://remote.example?key=value"), "modelID" to JsonPrimitive(""),
            "modelID" to JsonPrimitive("model\n"), "modelID" to JsonPrimitive("model\u200b"),
            "format" to JsonPrimitive("future-format"), "format" to JsonPrimitive(true), "format" to JsonNull)
        val cases = mutableListOf("""{"version":2,"profiles":"new shape"}""", """{"version":0}""",
            """{"version":-1}""", """{"version":true,"profiles":[]}""", """{"version":"1","profiles":[]}""",
            """{"version":1.5,"profiles":[]}""", """{"version":1}""", """{"version":1,"profiles":null}""", "{", "[]")
        badFields.forEach { cases.add(payload(listOf(JsonObject(valid + it)))) }
        cases.add(payload(listOf(valid, valid)))
        cases.add(payload(listOf(valid, JsonObject(valid + ("id" to JsonPrimitive(connection.profileID.rawValue.uppercase()))))))
        cases.add(payload(listOf(JsonObject(valid - "modelID"))))
        cases.add("""{"version":1,"profiles":[true]}""")
        cases.add(payload(listOf(valid)).dropLast(1) + ",\"unknown\":NaN}")
        cases.add(payload(listOf(valid)).dropLast(1) + ",\"unknown\":01}")
        cases.add(payload(listOf(valid)).replace("\"profiles\":", "profiles:"))
        cases.add(payload(listOf(valid)).dropLast(1) + ",\"unknown\":\"\\ud800\"}")
        val bytesCases = cases.map { it.encodeToByteArray() } + listOf(byteArrayOf(-1))
        for (bytes in bytesCases) {
            val files = CapabilityFiles()
            files.memory.put(bytes, path)
            val store = ProviderStateStore(files)
            assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection), bytes.decodeToString())
            assertContentEquals(bytes, files.memory.read(path))
            assertTrue(files.attemptedWrites.isEmpty())
            store.recordSuccess(OpenAIResponseFormat.NONE, connection)
            assertEquals(JsonPrimitive(1), json(files)["version"])
            assertEquals(1, profiles(json(files)).size)
            assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(connection))
        }
    }

    @Test fun parsedCorruptionPreservesUnknownMetadataForTheFirstMatchingProfileDuringRepair() {
        val files = CapabilityFiles()
        val connection = connection()
        val future = Json.parseToJsonElement("""{"keep":[1,2,null]}""")
        val profile = JsonObject(entry(connection, OpenAIResponseFormat.NONE) + mapOf(
            "id" to JsonPrimitive(connection.profileID.rawValue.uppercase()), "futureProfile" to future))
        val other = entry(connection(), OpenAIResponseFormat.NONE)
        files.memory.put(payload(listOf(profile, other, profile), mapOf("futureRoot" to future), version = 9), path)
        val store = ProviderStateStore(files)
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection))
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, connection)
        val healed = json(files)
        assertEquals(future, healed["futureRoot"])
        assertEquals(1, profiles(healed).size)
        assertEquals(future, profiles(healed).single()["futureProfile"])
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, ProviderStateStore(files).format(connection))
    }

    @Test fun deeplyNestedCorruptStateFallsBackWithoutLosingTheActionAndCanBeRepaired() {
        val connection = connection()
        for (arrays in listOf(10_000, 512)) {
            val files = CapabilityFiles()
            val original = payload(listOf(entry(connection, OpenAIResponseFormat.JSON_OBJECT))).dropLast(1) +
                ",\"deep\":" + "[".repeat(arrays) + "0" + "]".repeat(arrays) + "}"
            files.memory.put(original, path)
            val store = ProviderStateStore(files)
            assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection))
            assertEquals(original, files.memory.text(path))
            assertTrue(files.attemptedWrites.isEmpty())
            val response = AssistantResponse(AssistantOutput.Review(LlmReview("checked", emptyList())))
            val result = run { store.recordSuccess(OpenAIResponseFormat.NONE, connection); response }
            assertSame(response, result)
            assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(connection))
            assertEquals(setOf("version", "profiles"), json(files).keys)
        }
    }

    @Test fun swiftDepthBoundaryAndQuotedContainersRetainValidUnknownMetadata() {
        val connection = connection()
        val files = CapabilityFiles()
        // Root + 511 arrays = Foundation's maximum 512 open containers.
        files.memory.put(payload(listOf(entry(connection, OpenAIResponseFormat.JSON_OBJECT))).dropLast(1) +
            ",\"deep\":" + "[".repeat(511) + "0" + "]".repeat(511) + "}", path)
        val store = ProviderStateStore(files)
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, store.format(connection))
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(connection))
        assertTrue(json(files).containsKey("deep"))

        val quoted = "\\\"[{{".repeat(10_000) + "\\]}}\""
        files.memory.put(payload(listOf(entry(connection, OpenAIResponseFormat.JSON_OBJECT)),
            mapOf("quoted" to JsonPrimitive(quoted))), path)
        val reopened = ProviderStateStore(files)
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, reopened.format(connection))
        reopened.recordSuccess(OpenAIResponseFormat.NONE, connection)
        assertEquals(JsonPrimitive(quoted), json(files)["quoted"])
    }

    @Test fun readFailuresRetainStateNeverWriteAndRetryOnLaterActionsWithStaticWarnings() {
        val files = CapabilityFiles()
        val connection = connection()
        val original = payload(listOf(entry(connection, OpenAIResponseFormat.JSON_OBJECT)))
        files.memory.put(original, path)
        val store = ProviderStateStore(files)
        val sentinel = "sensitive-driver-diagnostic"
        val warnings = captureWarnings {
            for (failure in listOf(Exception(sentinel), StoreError.IOFailure)) {
                files.readFailure = failure
                assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection))
                store.recordSuccess(OpenAIResponseFormat.NONE, connection)
                assertTrue(files.attemptedWrites.isEmpty())
                files.readFailure = null
                assertEquals(original, files.memory.text(path))
                assertEquals(OpenAIResponseFormat.JSON_OBJECT, store.format(connection))
            }
        }
        assertEquals(List(2) { listOf("Provider capability cache read failed.", "Provider capability cache update failed.") }.flatten(), warnings.lines().filter { it.isNotEmpty() })
        assertFalse(warnings.contains(sentinel))
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        assertEquals(OpenAIResponseFormat.NONE, store.format(connection))
        assertEquals(1, files.attemptedWrites.size)
    }

    @Test fun externalCorruptReplacementIsRereadAndRepairedOnValidatedLearning() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val connection = connection()
        store.format(connection)
        files.memory.put("""{"version":9,"futureRoot":"keep"}""", path)
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        assertEquals(JsonPrimitive("keep"), json(files)["futureRoot"])
        assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(connection))
    }

    @Test fun failedIdentityResetKeepsSchemaUntilResetCanPublishIncludingAwayAndBack() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val original = connection()
        val changed = connection(id = original.profileID, model = "new-model")
        store.format(original)
        store.recordSuccess(OpenAIResponseFormat.NONE, original)
        val before = files.memory.read(path)
        files.writeFailure = StoreError.IOFailure
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(changed))
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, original)
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(changed))
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(original))
        assertContentEquals(before, files.memory.read(path))
        files.writeFailure = null
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(original))
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, ProviderStateStore(files).format(original))
    }

    @Test fun validatedSuccessCanPublishANewIdentityAfterFailedReset() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val original = connection()
        val changed = connection(id = original.profileID, model = "new-model")
        store.format(original)
        store.recordSuccess(OpenAIResponseFormat.NONE, original)
        files.nextWriteFailure = StoreError.IOFailure
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(changed))
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, changed)
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, ProviderStateStore(files).format(changed))
    }

    @Test fun failedAtomicLearningWritesPreserveCapabilityAndCanBeRetried() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val connection = connection()
        store.format(connection)
        files.nextWriteFailure = StoreError.IOFailure
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, connection)
        assertNull(files.memory.stamp(path))
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection))
        store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, connection)
        val before = files.memory.read(path)
        val stamp = files.memory.stamp(path)
        files.nextWriteFailure = StoreError.IOFailure
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        assertContentEquals(before, files.memory.read(path))
        assertEquals(stamp, files.memory.stamp(path))
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, store.format(connection))
        store.recordSuccess(OpenAIResponseFormat.NONE, connection)
        assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(connection))
    }

    @Test fun cacheWriteFailureDoesNotChangeAValidatedActionsResultAndFailedActionsNeverLearn() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val connection = connection()
        val response = AssistantResponse(AssistantOutput.Review(LlmReview("checked", emptyList())), AssistantTokenUsage(10, 20))
        // The protocol client owns stop/recovery/validation; this is its post-validation handoff.
        fun complete(result: Result<AssistantResponse>): AssistantResponse {
            store.format(connection)
            val validated = result.getOrThrow()
            store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, connection)
            return validated
        }
        for (failure in listOf(AssistantError.Truncated, AssistantError.Declined, AssistantError.InvalidOutput,
            AssistantError.Authentication, AssistantError.ProviderFailure(400))) {
            assertSame(failure, assertFailsWith<AssistantError> { complete(Result.failure(failure)) })
        }
        assertTrue(files.attemptedWrites.isEmpty())
        files.writeFailure = Exception("raw-write-diagnostic")
        val warnings = captureWarnings { assertSame(response, complete(Result.success(response))) }
        assertEquals("Provider capability cache update failed.\n", warnings)
        assertNull(files.memory.stamp(path))
        assertEquals(OpenAIResponseFormat.JSON_SCHEMA, store.format(connection))
        files.writeFailure = null
        assertSame(response, complete(Result.success(response)))
        assertEquals(OpenAIResponseFormat.JSON_OBJECT, ProviderStateStore(files).format(connection))
    }

    @Test fun oneSharedStoreSerializesReadModifyWriteAcrossConcurrentProfiles() {
        val files = CapabilityFiles()
        val store = ProviderStateStore(files)
        val first = connection()
        val second = connection()
        store.format(first)
        store.format(second)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        files.memory.onWrite = {
            entered.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
        }
        val executor = Executors.newFixedThreadPool(2)
        try {
            val firstResult = executor.submit { store.recordSuccess(OpenAIResponseFormat.JSON_OBJECT, first) }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val secondResult = executor.submit {
                secondStarted.countDown()
                store.recordSuccess(OpenAIResponseFormat.NONE, second)
            }
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
            assertFailsWith<TimeoutException> { secondResult.get(100, TimeUnit.MILLISECONDS) }
            release.countDown()
            firstResult.get(5, TimeUnit.SECONDS)
            secondResult.get(5, TimeUnit.SECONDS)
            assertEquals(OpenAIResponseFormat.JSON_OBJECT, ProviderStateStore(files).format(first))
            assertEquals(OpenAIResponseFormat.NONE, ProviderStateStore(files).format(second))
            assertEquals(2, profiles(json(files)).size)
        } finally {
            release.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    private fun connection(id: ProviderProfileID = ProviderProfileID(), base: String = "https://api.openai.com/v1",
                           kind: ProviderKind = ProviderKind.OPENAI_COMPATIBLE, model: String = "chosen-model",
                           key: String? = null) = ProviderConnection(id, kind, ProviderSettings.normalizeBaseURL(base, kind),
        model, key?.let(::SecretValue))

    private fun entry(connection: ProviderConnection, format: OpenAIResponseFormat) = JsonObject(mapOf(
        "id" to JsonPrimitive(connection.profileID.rawValue), "kind" to JsonPrimitive(connection.kind.rawValue),
        "baseURL" to JsonPrimitive(connection.baseURL), "modelID" to JsonPrimitive(connection.modelID),
        "format" to JsonPrimitive(format.rawValue)))

    private fun payload(profiles: List<JsonObject>, unknown: Map<String, JsonElement> = emptyMap(), version: Int = 1) =
        JsonObject(unknown + mapOf("version" to JsonPrimitive(version), "profiles" to JsonArray(profiles))).toString()

    private fun json(files: CapabilityFiles) = Json.parseToJsonElement(files.memory.text(path)).jsonObject
    private fun profiles(objectValue: JsonObject) = objectValue.getValue("profiles").jsonArray.map { it.jsonObject }

    private fun captureWarnings(work: () -> Unit): String {
        val previous = System.err
        val bytes = ByteArrayOutputStream()
        PrintStream(bytes, true, Charsets.UTF_8).use { captured ->
            try { System.setErr(captured); work() } finally { System.setErr(previous) }
        }
        return bytes.toString(Charsets.UTF_8)
    }

    private class CapabilityFiles(val memory: MemoryStore = MemoryStore()) : StateStore by memory {
        val attemptedWrites = mutableListOf<ByteArray>()
        var readFailure: Exception? = null
        var writeFailure: Exception? = null
        var nextWriteFailure: Exception? = null

        override fun read(path: String): ByteArray {
            readFailure?.let { throw it }
            return memory.read(path)
        }

        override fun write(bytes: ByteArray, path: String) {
            attemptedWrites.add(bytes.copyOf())
            val failure = nextWriteFailure ?: writeFailure
            nextWriteFailure = null
            failure?.let { throw it }
            memory.write(bytes, path)
        }
    }

    private val path = "provider-state.json"
}
