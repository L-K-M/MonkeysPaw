package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ProviderKeyRulesTest {
    @Test fun blankKeepsStoredValueAndExplicitClearDeletesItAcrossRestart() = runTest {
        val h = ProviderSettingsHarness()
        val original = ProviderDraft(key = ProviderKeyEdit.typed("fixture-stored"))
        h.service.save(original)
        val edit = ProviderDraft(h.service.snapshot.settings.profiles.single()).copy(
            key = ProviderKeyEdit.typed(" \t\n"), displayName = "Renamed")
        h.service.save(edit)
        assertEquals(1, h.secrets.writes.size)
        assertEquals(SecretValue("fixture-stored"), h.service.connection(edit.id).key)
        assertEquals(original.id, h.service.snapshot.settings.profiles.single().id)
        h.service.save(edit.copy(key = ProviderKeyEdit.Clear))
        assertNull(h.secrets.persisted[SecretAccount.provider(edit.id)])
        assertNull(h.service.snapshot.settings.profiles.single().secretReference)
        assertNull(h.service.connection(edit.id).key)
        assertEquals(listOf(SecretAccount.provider(edit.id)), h.secrets.deletions)
        assertNull(h.reopen().service.connection(edit.id).key)
        h.service.save(edit.copy(key = ProviderKeyEdit.Keep))
        assertNull(h.service.connection(edit.id).key)
    }

    @Test fun changedKindHostSchemeOrPortCannotReuseKeyForSaveOrTest() = runTest {
        val modifications: List<(ProviderDraft) -> ProviderDraft> = listOf(
            { it.copy(kind = ProviderKind.OPENAI_COMPATIBLE) }, { it.copy(baseURL = "https://other.example") },
            { it.copy(baseURL = "http://localhost") }, { it.copy(baseURL = "https://api.anthropic.com:8443") },
        )
        for (modify in modifications) {
            val h = ProviderSettingsHarness()
            h.service.save(ProviderDraft(key = ProviderKeyEdit.typed("fixture-stored")))
            val before = h.service.snapshot
            val edit = modify(ProviderDraft(before.settings.profiles.single()))
            val reads = h.secrets.reads.size
            assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { h.service.resolveForTesting(edit) }
            assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { h.service.save(edit) }
            assertEquals(reads, h.secrets.reads.size)
            assertEquals(before, h.service.snapshot)
            val replacement = edit.copy(key = ProviderKeyEdit.typed("fixture-reentered"))
            assertEquals(SecretValue("fixture-reentered"), h.service.resolveForTesting(replacement).key)
            h.service.save(replacement)
            assertEquals(SecretValue("fixture-reentered"), h.service.connection(edit.id).key)
            assertEquals(edit.id, h.service.snapshot.settings.profiles.single().id)
        }
    }

    @Test fun keylessClearAndDeleteNeverCallNativeDeleteOrRequireCompensation() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.Clear)
        h.secrets.deleteError = SecretStoreError.DeleteFailed
        h.service.save(draft)
        h.service.save(draft)
        val before = h.service.snapshot
        h.files.failNextWrite = true
        assertFailsWith<ProviderSettingsError.WriteFailed> { h.service.save(draft.copy(displayName = "Changed")) }
        assertEquals(before, h.service.snapshot)
        assertNull(h.reopen().service.connection(draft.id).key)
        h.service.deleteProfile(draft.id)
        assertTrue(h.secrets.deletions.isEmpty())
        assertTrue(h.secrets.writes.isEmpty())
    }

    @Test fun changedDestinationCanBeClearedForKeylessLocalUse() = runTest {
        val h = ProviderSettingsHarness()
        h.service.save(ProviderDraft(key = ProviderKeyEdit.typed("fixture-stored")))
        val edit = ProviderDraft(h.service.snapshot.settings.profiles.single()).copy(kind = ProviderKind.OPENAI_COMPATIBLE,
            baseURL = "http://localhost:11434", modelID = "local-model", key = ProviderKeyEdit.Clear)
        assertNull(h.service.resolveForTesting(edit).key)
        assertNotNull(h.secrets.persisted[SecretAccount.provider(edit.id)])
        h.service.save(edit)
        assertNull(h.service.connection(edit.id).key)
        assertNull(h.secrets.persisted[SecretAccount.provider(edit.id)])
    }

    @Test fun equivalentOriginsAndChangedPathOrModelRetainKeyAndSeparateCapabilityIdentity() = runTest {
        val h = ProviderSettingsHarness()
        h.service.save(ProviderDraft(key = ProviderKeyEdit.typed("fixture-stored")))
        val profile = h.service.snapshot.settings.profiles.single()
        val equivalent = ProviderDraft(profile).copy(baseURL = "HTTPS://API.ANTHROPIC.COM:443/v1/messages/")
        h.service.save(equivalent)
        assertEquals(profile.cacheKey, h.service.snapshot.settings.profiles.single().cacheKey)
        val changed = equivalent.copy(baseURL = "https://api.anthropic.com/proxy", modelID = "other-model")
        h.service.save(changed)
        assertEquals(SecretValue("fixture-stored"), h.service.connection(changed.id).key)
        assertNotEquals(profile.cacheKey, h.service.snapshot.settings.profiles.single().cacheKey)
        assertEquals(1, h.secrets.writes.size)
    }

    @Test fun testResolvesOnlyItsDraftAccountAndNeverMutatesMetadataSecretsOrSelection() = runTest {
        val h = ProviderSettingsHarness()
        val first = ProviderDraft(displayName = "One", key = ProviderKeyEdit.typed("fixture-one"))
        val second = ProviderDraft(displayName = "Two", key = ProviderKeyEdit.typed("fixture-two"))
        h.service.save(first)
        h.service.save(second)
        h.service.selectProfile(first.id)
        val before = h.service.snapshot
        val writes = h.files.attemptedWrites.size
        val secretWrites = h.secrets.writes.size
        val deletions = h.secrets.deletions.size
        val bytes = h.files.read("provider-settings.json")
        val draft = ProviderDraft(before.settings.profiles[1])
        assertEquals(SecretValue("fixture-two"), h.service.resolveForTesting(draft).key)
        val typed = draft.copy(key = ProviderKeyEdit.typed("fixture-draft-only"), baseURL = "https://draft.example", modelID = "typed-model")
        val connection = h.service.resolveForTesting(typed)
        assertEquals(SecretValue("fixture-draft-only"), connection.key)
        assertEquals("typed-model", connection.modelID)
        assertEquals("https://draft.example", connection.baseURL)
        assertNull(h.service.resolveForTesting(typed.copy(key = ProviderKeyEdit.Clear)).key)
        val new = ProviderDraft(kind = ProviderKind.OPENAI_COMPATIBLE, displayName = "", baseURL = "http://localhost:8080")
        assertEquals("", h.service.resolveForTesting(new).modelID)
        assertNull(h.service.resolveForTesting(new).key)
        assertEquals(before, h.service.snapshot)
        assertEquals(writes, h.files.attemptedWrites.size)
        assertEquals(secretWrites, h.secrets.writes.size)
        assertEquals(deletions, h.secrets.deletions.size)
        assertContentEquals(bytes, h.files.read("provider-settings.json"))
        assertEquals(SecretValue("fixture-one"), h.service.connection(first.id).key)
        assertEquals(SecretValue("fixture-two"), h.service.connection(second.id).key)
    }

    @Test fun deletionOnlyTouchesItsAccountAndRetainsOtherSelection() = runTest {
        val h = ProviderSettingsHarness()
        val first = ProviderDraft(displayName = "One", key = ProviderKeyEdit.typed("fixture-one"))
        val second = ProviderDraft(displayName = "Two", key = ProviderKeyEdit.typed("fixture-two"))
        h.service.save(first)
        h.service.save(second)
        h.service.selectProfile(second.id)
        h.service.deleteProfile(first.id)
        assertEquals(listOf(SecretAccount.provider(first.id)), h.secrets.deletions)
        assertEquals(listOf(second.id), h.service.snapshot.settings.profiles.map { it.id })
        assertEquals(second.id, h.service.snapshot.settings.selectedProfileID)
        assertEquals(SecretValue("fixture-two"), h.service.connection(second.id).key)
        h.service.deleteProfile(second.id)
        assertNull(h.service.snapshot.settings.selectedProfileID)
        assertFailsWith<ProviderSettingsError.ProfileNotFound> { h.service.deleteProfile(second.id) }
        assertFailsWith<ProviderSettingsError.ProfileNotFound> { h.service.connection(second.id) }
        assertFailsWith<ProviderSettingsError.ProfileNotFound> { h.service.secretTier(second.id) }
        assertFailsWith<ProviderSettingsError.ProfileNotFound> { h.service.selectProfile(second.id) }
    }

    @Test fun newAndPreviouslyKeylessProfilesNeverAdoptOrphanedSecrets() = runTest {
        for (savedFirst in listOf(false, true)) {
            val h = ProviderSettingsHarness()
            val draft = ProviderDraft()
            if (savedFirst) h.service.save(draft)
            val account = SecretAccount.provider(draft.id)
            val orphan = StoredSecret(SecretValue("fixture-orphan"), SecretTier.KEYSTORE)
            h.secrets.persisted[account] = orphan
            val reads = h.secrets.reads.size
            assertNull(h.service.resolveForTesting(draft).key)
            h.service.save(draft)
            assertNull(h.service.connection(draft.id).key)
            assertNull(h.service.snapshot.settings.profiles.single().secretReference)
            assertEquals(reads, h.secrets.reads.size)
            assertEquals(orphan, h.secrets.persisted[account])
        }
    }

    @Test fun typedAndUnknownSecretFailuresPreserveMetadataAndSanitizeErrors() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-old"))
        h.service.save(draft)
        val previous = h.secrets.persisted.toMap()
        val before = h.service.snapshot
        val bytes = h.files.read("provider-settings.json")
        val edit = draft.copy(key = ProviderKeyEdit.typed("fixture-new"))
        h.secrets.readError = SecretStoreError.Locked
        assertEquals(ProviderSettingsError.Secret(SecretStoreError.Locked), assertFailsWith<ProviderSettingsError> { h.service.save(edit) })
        h.secrets.readError = null
        h.secrets.writeError = IllegalStateException("fixture-only untrusted body")
        val error = assertFailsWith<ProviderSettingsError.Secret> { h.service.save(edit) }
        assertEquals(SecretStoreError.WriteFailed, error.error)
        assertNull(error.cause)
        h.secrets.writeError = null
        h.secrets.deleteError = SecretStoreError.DeleteFailed
        assertEquals(ProviderSettingsError.Secret(SecretStoreError.DeleteFailed), assertFailsWith<ProviderSettingsError> {
            h.service.save(edit.copy(key = ProviderKeyEdit.Clear))
        })
        assertEquals(before, h.service.snapshot)
        assertContentEquals(bytes, h.files.read("provider-settings.json"))
        assertEquals(previous, h.secrets.persisted)
    }

    @Test fun metadataFailureRestoresOpaquePreviousPayloadVerbatimForReplaceClearAndDelete() = runTest {
        for (operation in listOf("replace", "clear", "delete")) {
            val h = ProviderSettingsHarness()
            val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-old"))
            h.service.save(draft)
            val account = SecretAccount.provider(draft.id)
            val bound = h.secrets.persisted.getValue(account).value.withValue { Json.parseToJsonElement(it).jsonObject }
            val opaque = SecretValue(" \n" + JsonObject(bound + ("unknown" to JsonArray(listOf(JsonPrimitive("future/雪"), JsonNull)))).toString() + "\n ")
            h.secrets.persisted[account] = StoredSecret(opaque, SecretTier.KEYSTORE)
            val before = h.service.snapshot
            val bytes = h.files.read("provider-settings.json")
            h.files.failNextWrite = true
            assertFailsWith<ProviderSettingsError.WriteFailed> {
                when (operation) {
                    "replace" -> h.service.save(draft.copy(displayName = "Changed", key = ProviderKeyEdit.typed("fixture-new")))
                    "clear" -> h.service.save(draft.copy(key = ProviderKeyEdit.Clear))
                    else -> h.service.deleteProfile(draft.id)
                }
            }
            assertEquals(before, h.service.snapshot)
            assertContentEquals(bytes, h.files.read("provider-settings.json"))
            assertEquals(opaque, h.secrets.persisted[account]?.value)
            assertTrue(h.secrets.reads.contains(account to SecretReadSource.PERSISTED))
            assertEquals(SecretValue("fixture-old"), h.reopen().service.connection(draft.id).key)
        }
    }

    @Test fun failedInitialMetadataCommitRemovesNewSecretAndAllowsRetry() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-new"))
        h.files.failNextWrite = true
        assertFailsWith<ProviderSettingsError.WriteFailed> { h.service.save(draft) }
        assertNull(h.secrets.persisted[SecretAccount.provider(draft.id)])
        assertNull(h.files.stamp("provider-settings.json"))
        h.service.save(draft)
        assertEquals(SecretValue("fixture-new"), h.service.connection(draft.id).key)
    }

    @Test fun failedRestorationMakesInstanceReadOnlyAndDisablesCredentialResolution() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-old"))
        h.service.save(draft)
        val before = h.service.snapshot
        h.secrets.failWriteNumber = h.secrets.writes.size + 2
        h.files.failNextWrite = true
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> {
            h.service.save(draft.copy(displayName = "Changed", key = ProviderKeyEdit.typed("fixture-new")))
        }
        assertEquals(before.settings, h.service.snapshot.settings)
        assertEquals(ProviderSettingsError.SecretRollbackFailed, h.service.snapshot.readOnlyError)
        val reads = h.secrets.reads.size
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> { h.service.connection(draft.id) }
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> { h.service.resolveForTesting(draft) }
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> { h.service.secretTier(draft.id) }
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> { h.service.save(draft) }
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> { h.service.selectProfile(null) }
        assertEquals(reads, h.secrets.reads.size)
    }

    @Test fun failedInitialCompensatingDeleteAlsoBlocksTheInstance() = runTest {
        val h = ProviderSettingsHarness()
        h.files.failNextWrite = true
        h.secrets.deleteError = SecretStoreError.DeleteFailed
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> { h.service.save(ProviderDraft(key = ProviderKeyEdit.typed("fixture-new"))) }
        assertTrue(h.service.snapshot.isReadOnly)
        assertTrue(h.service.snapshot.settings.profiles.isEmpty())
        assertNull(h.files.stamp("provider-settings.json"))
    }

    @Test fun restartCannotSendChangedDestinationCredentialAfterFailedCommitAndRestoration() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-old"))
        h.service.save(draft)
        val bytes = h.files.read("provider-settings.json")
        h.secrets.failWriteNumber = h.secrets.writes.size + 2
        h.files.failNextWrite = true
        assertFailsWith<ProviderSettingsError.SecretRollbackFailed> {
            h.service.save(draft.copy(baseURL = "https://other.example", key = ProviderKeyEdit.typed("fixture-new")))
        }
        assertContentEquals(bytes, h.files.read("provider-settings.json"))
        val reopened = h.reopen()
        assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { reopened.service.connection(draft.id) }
        assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { reopened.service.resolveForTesting(draft.copy(key = ProviderKeyEdit.Keep)) }
    }

    @Test fun externalDestinationEditsCannotRebindCredentialAndExplicitReentryRepairsIt() = runTest {
        for ((name, value) in listOf("kind" to "openaiCompatible", "baseURL" to "https://other.example",
            "baseURL" to "http://localhost", "baseURL" to "https://localhost:8443")) {
            val h = ProviderSettingsHarness()
            val draft = ProviderDraft(baseURL = "https://localhost", key = ProviderKeyEdit.typed("fixture-old"))
            h.service.save(draft)
            h.editProfile(draft.id) { it[name] = JsonPrimitive(value) }
            for (current in listOf(h, h.reopen())) {
                assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { current.service.connection(draft.id) }
                val saved = ProviderDraft(current.service.snapshot.settings.profiles.single())
                assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { current.service.resolveForTesting(saved) }
            }
            assertEquals(1, h.secrets.writes.size)
            val reopened = h.reopen()
            reopened.service.save(ProviderDraft(reopened.service.snapshot.settings.profiles.single()).copy(key = ProviderKeyEdit.typed("fixture-reentered")))
            assertEquals(SecretValue("fixture-reentered"), reopened.service.connection(draft.id).key)
        }
    }

    @Test fun unboundMalformedUnsupportedAndMismatchedPayloadsRequireReentry() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-key"))
        h.service.save(draft)
        val account = SecretAccount.provider(draft.id)
        val persisted = h.secrets.persisted.getValue(account)
        val root = persisted.value.withValue { Json.parseToJsonElement(it).jsonObject }
        val bad = listOf("fixture-unbound", "{", "{\"version\":1}") +
            listOf("version" to JsonPrimitive(2), "version" to JsonPrimitive(true), "kind" to JsonPrimitive("unknown"),
                "origin" to JsonPrimitive("https://other.example:443"), "key" to JsonNull)
                .map { (name, value) -> JsonObject(root + (name to value)).toString() }
        for (value in bad) {
            h.secrets.persisted[account] = StoredSecret(SecretValue(value), SecretTier.KEYSTORE)
            assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { h.service.connection(draft.id) }
            assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { h.service.resolveForTesting(draft.copy(key = ProviderKeyEdit.Keep)) }
        }
        h.secrets.persisted[account] = persisted
        assertEquals(SecretValue("fixture-key"), h.service.connection(draft.id).key)
        for (key in listOf("", "   ", "fixture\nkey", "fixture\u200bkey")) {
            h.secrets.persisted[account] = StoredSecret(SecretValue(JsonObject(root + ("key" to JsonPrimitive(key))).toString()), SecretTier.KEYSTORE)
            assertFailsWith<ProviderSettingsError.InvalidKey> { h.service.connection(draft.id) }
        }
    }

    @Test fun credentialPayloadHasExactlyTheSwiftVersionOneFieldsAndNormalizedOrigin() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(baseURL = "HTTPS://LOCALHOST:443/proxy/v1/messages", key = ProviderKeyEdit.typed(" fixture/雪 "))
        h.service.save(draft)
        val payload = h.secrets.persisted.getValue(SecretAccount.provider(draft.id)).value.withValue { Json.parseToJsonElement(it).jsonObject }
        assertEquals(setOf("version", "kind", "origin", "key"), payload.keys)
        assertEquals(JsonPrimitive(1), payload["version"])
        assertEquals(JsonPrimitive("anthropic"), payload["kind"])
        assertEquals(JsonPrimitive("https://localhost:443"), payload["origin"])
        assertEquals(SecretValue("fixture/雪"), h.service.connection(draft.id).key)
    }

    @Test fun duplicateCredentialMembersUseFirstValuesLikeSwiftJSONDecoder() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-first"))
        h.service.save(draft)
        val account = SecretAccount.provider(draft.id)
        val good = "\"version\":1,\"kind\":\"anthropic\",\"origin\":\"https://api.anthropic.com:443\",\"key\":\"fixture-first\""
        h.secrets.persisted[account] = StoredSecret(SecretValue("{$good,\"key\":\"fixture-second\"}"), SecretTier.KEYSTORE)
        assertEquals(SecretValue("fixture-first"), h.service.connection(draft.id).key)
        for (bad in listOf("\"version\":2", "\"kind\":\"openaiCompatible\"", "\"origin\":\"https://other.example:443\"")) {
            h.secrets.persisted[account] = StoredSecret(SecretValue("{$bad,$good}"), SecretTier.KEYSTORE)
            assertFailsWith<ProviderSettingsError.KeyRequiredForChangedDestination> { h.service.connection(draft.id) }
        }
    }

    @Test fun clearAndDeleteFailClosedWhenTheOpaquePayloadCannotBeReadForCompensation() = runTest {
        val h = ProviderSettingsHarness()
        val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-key"))
        h.service.save(draft)
        val before = h.service.snapshot
        val bytes = h.files.read("provider-settings.json")
        h.secrets.readError = SecretStoreError.Unavailable
        assertEquals(ProviderSettingsError.Secret(SecretStoreError.Unavailable), assertFailsWith<ProviderSettingsError> {
            h.service.save(draft.copy(key = ProviderKeyEdit.Clear))
        })
        assertEquals(ProviderSettingsError.Secret(SecretStoreError.Unavailable), assertFailsWith<ProviderSettingsError> {
            h.service.deleteProfile(draft.id)
        })
        assertEquals(before, h.service.snapshot)
        assertContentEquals(bytes, h.files.read("provider-settings.json"))
        assertTrue(h.secrets.deletions.isEmpty())
    }

    @Test fun invalidDraftsNeverTouchMetadataOrSecrets() = runTest {
        val h = ProviderSettingsHarness()
        val invalid = listOf(
            ProviderDraft(displayName = "", key = ProviderKeyEdit.typed("fixture-key")) to ProviderSettingsError.InvalidProfile,
            ProviderDraft(baseURL = "https://user:password@example.com", key = ProviderKeyEdit.typed("fixture-key")) to ProviderSettingsError.CredentialsInURL,
            ProviderDraft(baseURL = "https://example.com?key=fixture", key = ProviderKeyEdit.typed("fixture-key")) to ProviderSettingsError.QueryOrFragmentInURL,
            ProviderDraft(modelID = "", key = ProviderKeyEdit.typed("fixture-key")) to ProviderSettingsError.InvalidProfile,
        ) + listOf("\nfixture-key", "   ", "fixture\u0000key", "fixture\u200dkey").map {
            ProviderDraft(key = ProviderKeyEdit.Replace(SecretValue(it))) to ProviderSettingsError.InvalidKey
        }
        for ((draft, error) in invalid) assertEquals(error, assertFailsWith<ProviderSettingsError> { h.service.save(draft) })
        assertTrue(h.secrets.reads.isEmpty())
        assertTrue(h.secrets.writes.isEmpty())
        assertTrue(h.files.attemptedWrites.isEmpty())
        assertTrue(h.service.snapshot.settings.profiles.isEmpty())
    }

    @Test fun sentinelsNeverEnterMetadataDescriptionsOrCapturedDiagnostics() = runTest {
        val output = ByteArrayOutputStream()
        val originalErr = System.err
        System.setErr(PrintStream(output, true, Charsets.UTF_8))
        try {
            val h = ProviderSettingsHarness()
            val sentinel = UUID.randomUUID().toString()
            val draft = ProviderDraft(key = ProviderKeyEdit.typed(sentinel))
            h.service.save(draft)
            val edit = ProviderDraft(h.service.snapshot.settings.profiles.single()).copy(displayName = "Edited")
            val connection = h.service.resolveForTesting(edit)
            assertTrue(connection.key?.withValue { it == sentinel } == true)
            h.files.failNextWrite = true
            assertFailsWith<ProviderSettingsError.WriteFailed> { h.service.save(edit) }
            h.secrets.writeError = IllegalStateException(sentinel)
            val error = assertFailsWith<ProviderSettingsError.Secret> { h.service.save(edit.copy(key = ProviderKeyEdit.typed(sentinel))) }
            h.secrets.writeError = null
            h.secrets.readError = IllegalStateException(sentinel)
            val connectionError = assertFailsWith<ProviderSettingsError.Secret> { h.service.connection(draft.id) }
            h.secrets.readError = null
            h.service.save(edit.copy(key = ProviderKeyEdit.Clear))
            val variants = listOf(sentinel, java.util.Base64.getEncoder().encodeToString(sentinel.encodeToByteArray()),
                sentinel.encodeToByteArray().joinToString("") { "%%%02X".format(it) })
            for (bytes in h.files.attemptedWrites + h.files.memory.bytesSnapshot().values.map { it.toByteArray() }) {
                assertTrue(variants.none { bytes.decodeToString().contains(it) }, "Secret reached metadata")
            }
            assertTrue(variants.none { output.toString(Charsets.UTF_8).contains(it) }, "Secret reached diagnostics")
            for (value in listOf(draft, connection, connection.key, h.service.snapshot, h.store, h.service, error,
                error.message, connectionError, connectionError.message)) {
                assertFalse(value.toString().contains(sentinel), "Secret reached a description")
            }
            assertNull(error.cause)
            assertNull(connectionError.cause)
            assertTrue(output.size() > 0)
        } finally { System.setErr(originalErr) }
    }

    @Test fun injectedIOExecutorOwnsMetadataAndSecretWorkAndSnapshotsNeverWaitOnSecrets() = runTest {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { io ->
            val h = ProviderSettingsHarness(io = io)
            val thread = withContext(io) { Thread.currentThread() }
            h.files.onAccess = { assertSame(thread, Thread.currentThread()) }
            h.secrets.onAccess = { assertSame(thread, Thread.currentThread()) }
            val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-key"))
            h.service.save(draft)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            h.secrets.beforeRead = { entered.complete(Unit); release.await() }
            val resolution = launch { h.service.connection(draft.id) }
            entered.await()
            assertEquals(draft.id, h.service.snapshot.settings.selectedProfileID)
            assertFalse(resolution.isCompleted)
            release.complete(Unit)
            resolution.join()
        }
    }

    @Test fun cancellationAfterSecretCommitCannotStrandTheCompoundEditOrSkipCompensation() = runTest {
        for (failMetadata in listOf(false, true)) {
            val h = ProviderSettingsHarness(io = StandardTestDispatcher(testScheduler))
            val draft = ProviderDraft(key = ProviderKeyEdit.typed("fixture-new"))
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            h.secrets.afterWrite = { entered.complete(Unit); release.await() }
            h.files.failNextWrite = failMetadata
            val job = launch {
                try { h.service.save(draft) } catch (_: ProviderSettingsError.WriteFailed) { }
            }
            entered.await()
            job.cancel()
            runCurrent()
            assertFalse(job.isCompleted)
            release.complete(Unit)
            job.join()
            val account = SecretAccount.provider(draft.id)
            if (failMetadata) {
                assertNull(h.secrets.persisted[account])
                assertNull(h.files.stamp("provider-settings.json"))
                assertTrue(h.service.snapshot.settings.profiles.isEmpty())
            } else {
                assertNotNull(h.secrets.persisted[account])
                assertEquals(draft.id, h.service.snapshot.settings.selectedProfileID)
                assertEquals(h.service.snapshot, h.reopen().service.snapshot)
            }
        }
    }

    @Test fun aQueuedCancelledEditPerformsNoSecretOrMetadataMutation() = runTest {
        val h = ProviderSettingsHarness(io = StandardTestDispatcher(testScheduler))
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        h.secrets.afterWrite = { entered.complete(Unit); release.await() }
        val first = ProviderDraft(key = ProviderKeyEdit.typed("fixture-first"))
        val second = ProviderDraft(key = ProviderKeyEdit.typed("fixture-second"))
        val active = launch { h.service.save(first) }
        entered.await()
        val queued = launch { h.service.save(second) }
        runCurrent()
        queued.cancelAndJoin()
        release.complete(Unit)
        active.join()
        assertEquals(listOf(first.id), h.service.snapshot.settings.profiles.map { it.id })
        assertNull(h.secrets.persisted[SecretAccount.provider(second.id)])
        assertEquals(1, h.files.attemptedWrites.size)
    }
}
