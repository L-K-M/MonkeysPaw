package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption
import ch.lkmc.monkeyspaw.core.ports.HttpMethod
import ch.lkmc.monkeyspaw.core.ports.HttpRequest
import ch.lkmc.monkeyspaw.core.ports.HttpResponse
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.ports.SecretStore
import java.io.PrintWriter
import java.io.StringWriter
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Portable value cases from Swift ProviderNormalization/AssistantValues/AssistantClientValuesTests. */
class AssistantValuesTest {
    @Test fun stableIdsAndNamespacedAccountsStayIsolated() {
        val id = ProviderProfileID.parse("00112233-4455-6677-8899-AABBCCDDEEFF")
        assertEquals("00112233-4455-6677-8899-aabbccddeeff", id.rawValue)
        assertEquals(id, ProviderProfileID.parse(id.rawValue))
        val account = SecretAccount.provider(id)
        assertEquals("provider:${id.rawValue}", account.rawValue)
        assertEquals(account, SecretAccount.parse(account.rawValue))
        assertNotEquals(account, SecretAccount.provider(ProviderProfileID()))
        assertNotEquals(account, SecretAccount("device-token", id.rawValue))
        for (value in listOf("", "provider", "provider:", "provider:a:b", "provider:a b", ":id", "prøvider:id", "provider:a\n")) {
            assertEquals(SecretStoreError.InvalidAccount, assertFailsWith<SecretStoreError> { SecretAccount.parse(value) })
        }
        for (value in listOf("", "1-1-1-1-1", "00112233445566778899aabbccddeeff", "00112233-4455-6677-8899-aabbccddeefg")) {
            assertEquals(ProviderSettingsError.InvalidProfile, assertFailsWith<ProviderSettingsError> { ProviderProfileID.parse(value) })
        }
    }

    @Test fun profilesRejectInvalidMetadataAndCrossAccountReferences() {
        val id = ProviderProfileID()
        for ((name, model) in listOf("" to "manual", " \n" to "manual", "Name" to "", "Name" to " \t",
            "Na\nme" to "manual", "Name" to "man\u200dual")) {
            assertEquals(ProviderSettingsError.InvalidProfile, assertFailsWith<ProviderSettingsError> {
                ProviderProfile(id, name, ProviderKind.ANTHROPIC, "https://example.com", model)
            })
        }
        assertEquals(ProviderSettingsError.InvalidProfile, assertFailsWith<ProviderSettingsError> {
            ProviderProfile(id, "Name", ProviderKind.ANTHROPIC, "https://example.com", "manual", SecretAccount.provider(ProviderProfileID()))
        })
        assertEquals(ProviderSettingsError.InvalidProfile, assertFailsWith<ProviderSettingsError> {
            ProviderProfile(id, "", ProviderKind.ANTHROPIC, "invalid URL", "manual")
        })
        val profile = profile(id = id)
        assertEquals(ProviderSettingsError.DuplicateProfile, assertFailsWith<ProviderSettingsError> { ProviderSettings(listOf(profile, profile)) })
        assertEquals(ProviderSettingsError.ProfileNotFound, assertFailsWith<ProviderSettingsError> { ProviderSettings(listOf(profile), ProviderProfileID()) })
        assertEquals(1, ProviderSettings().version)
        val valid = ProviderSettings(listOf(profile), id)
        assertEquals(profile, valid.profiles.single())
        assertFalse(ProviderSettingsSnapshot(valid).isReadOnly)
        assertTrue(ProviderSettingsSnapshot(valid, ProviderSettingsError.CorruptFile).isReadOnly)
    }

    @Test fun cacheIdentityIncludesIdKindFullNormalizedPathAndExactModel() {
        val id = ProviderProfileID()
        val original = profile(id).cacheKey
        assertEquals(original, profile(id, base = "HTTPS://EXAMPLE.COM:443/v1/messages").cacheKey)
        for (changed in listOf(profile(), profile(id, kind = ProviderKind.OPENAI_COMPATIBLE),
            profile(id, base = "https://example.com/proxy"), profile(id, model = "other"))) {
            assertNotEquals(original, changed.cacheKey)
        }
        assertNotEquals(profile(id, model = "é").cacheKey, profile(id, model = "e\u0301").cacheKey)
    }

    @Test fun draftsUseKindDefaultsAndBlankTypedKeysMeanKeep() {
        assertEquals("Anthropic", ProviderDraft().displayName)
        assertEquals("claude-opus-5-5", ProviderDraft().modelID)
        assertEquals("OpenAI-compatible", ProviderDraft(kind = ProviderKind.OPENAI_COMPATIBLE).displayName)
        assertEquals("", ProviderDraft(kind = ProviderKind.OPENAI_COMPATIBLE).modelID)
        assertEquals("Local", ProviderDraft(kind = ProviderKind.OPENAI_COMPATIBLE, displayName = "Local").displayName)
        assertEquals(ProviderKeyEdit.Replace(SecretValue("sentinel")), ProviderKeyEdit.typed(" \tsentinel\r\n"))
        assertEquals(ProviderKeyEdit.Keep, ProviderKeyEdit.typed(" \t\n"))
        assertEquals(ProviderKeyEdit.Keep, ProviderKeyEdit.typed("\u0085\u200b"))
        assertEquals(ProviderKeyEdit.Replace(SecretValue("first\nsecond")), ProviderKeyEdit.typed("first\nsecond"))
        val profile = profile()
        val draft = ProviderDraft(profile)
        assertEquals(profile.id, draft.id)
        assertEquals(profile.baseURL, draft.baseURL)
        assertEquals(ProviderKeyEdit.Keep, draft.key)
        assertEquals("Edited", draft.copy(displayName = "Edited").displayName)
    }

    @Test fun diagnosticStringsAndExceptionTracesRedactSecretsAndContent() {
        val sentinel = "runtime-${ProviderProfileID().rawValue}"
        val secret = SecretValue(sentinel)
        val draft = ProviderDraft(displayName = sentinel, baseURL = "https://example.com?key=$sentinel", key = ProviderKeyEdit.Replace(secret))
        val connection = ProviderConnection(draft.id, draft.kind, "https://example.com", sentinel, secret)
        val field = LlmArtifact.Field(sentinel, FieldKind.TEXT, sentinel, sentinel, sentinel, listOf(FieldOption(sentinel, sentinel)), false, true)
        val artifact = LlmArtifact(sentinel, sentinel, listOf(sentinel), listOf(field), sentinel, sentinel)
        val finding = LlmReview.Finding(LlmRubricCriterion.CLARITY, LlmReviewSeverity.HIGH, sentinel, sentinel, sentinel, LlmReview.QuoteMatch.Unmatched)
        val review = LlmReview(sentinel, listOf(finding))
        val actions = listOf(AssistantAction.Write(sentinel), AssistantAction.Review(sentinel), AssistantAction.Improve(sentinel, sentinel, listOf(finding)))
        val message = AssistantMessage(AssistantMessage.Role.USER, sentinel)
        val outputs = listOf(AssistantOutput.Artifact(artifact), AssistantOutput.Review(review))
        val values: List<Any> = listOf(secret, StoredSecret(secret, SecretTier.KEYSTORE), draft, draft.key, connection, field, artifact, finding, review,
            ModelDescriptor(sentinel, sentinel), AssistantModelPage(listOf(ModelDescriptor(sentinel)), true, sentinel, sentinel),
            ConnectionTestResult.Ok(listOf(ModelDescriptor(sentinel))), message,
            HttpRequest("https://example.com?key=$sentinel", HttpMethod.POST, mapOf("Authorization" to sentinel), sentinel.toByteArray(), deadlineNanos = 1L),
            HttpResponse(500, mapOf("error" to sentinel), sentinel.toByteArray())) + actions + outputs +
            actions.map { AssistantRequest(it, transcript = listOf(message), feedback = sentinel) } + outputs.map { AssistantResponse(it) }
        for (value in values) assertFalse(sentinel in value.toString(), value.javaClass.simpleName)

        val errors = listOf(AssistantError.UnexpectedStop(sentinel), AssistantError.Transport(HttpTransportError.NetworkFailure),
            AssistantError.RateLimited(15.0), AssistantError.ProviderFailure(500), ProviderSettingsError.Secret(SecretStoreError.ReadFailed),
            ProviderSettingsError.InvalidBaseURL, ProviderSettingsError.SecretRollbackFailed, HttpTransportError.InvalidRequest, SecretStoreError.WriteFailed)
        for (error in errors) {
            assertFalse(sentinel in error.toString())
            assertFalse(sentinel in error.message.orEmpty())
            assertFalse(sentinel in error.localizedMessage.orEmpty())
            assertNull(error.cause)
            assertFailsWith<IllegalStateException> { error.initCause(Exception(sentinel)) }
            error.addSuppressed(Exception(sentinel))
            assertTrue(error.suppressed.isEmpty())
            val trace = StringWriter()
            error.printStackTrace(PrintWriter(trace))
            assertFalse(sentinel in trace.toString())
        }
        assertEquals("unexpectedStop", AssistantError.UnexpectedStop(sentinel).toString())
        assertEquals(AssistantError.UnexpectedStop(sentinel), AssistantError.UnexpectedStop(sentinel))
        assertEquals(sentinel, secret.withValue { it })
        assertEquals("keystore", SecretTier.KEYSTORE.rawValue)
    }

    @Test fun requestAndModelPagesRetainTypedMetadataWithoutMutableAliases() {
        val models = mutableListOf(ModelDescriptor("model", "Model"))
        val page = AssistantModelPage(models, hasMore = true, firstID = "model", lastID = "model")
        val result = ConnectionTestResult.Ok(models)
        models.clear()
        assertEquals("Model", page.models.single().displayName)
        assertTrue(page.hasMore)
        assertEquals("model", page.firstID)
        assertEquals("model", page.lastID)
        assertEquals(page.models, result.models)
        assertNull(AssistantRequest(AssistantAction.Write("Brief")).effort)
        val messages = mutableListOf(AssistantMessage(AssistantMessage.Role.USER, "message"))
        val request = AssistantRequest(AssistantAction.Review("Source"), effort = AssistantEffort.HIGH, transcript = messages)
        messages.clear()
        assertEquals(AssistantEffort.HIGH, request.effort)
        assertEquals("message", request.transcript.single().content)
        assertFailsWith<UnsupportedOperationException> { (request.transcript as MutableList).clear() }
        val profiles = mutableListOf(profile())
        val settings = ProviderSettings(profiles)
        profiles.clear()
        assertEquals(1, settings.profiles.size)
        assertFailsWith<UnsupportedOperationException> { (settings.profiles as MutableList).clear() }
    }

    @Test fun outputCollectionsRemainImmutableAtEveryOwnedLevel() {
        val options = mutableListOf(FieldOption("label", "value"))
        val field = LlmArtifact.Field("field", FieldKind.CHOICE, "Label", "", "", options, false, true)
        val fields = mutableListOf(field)
        val tags = mutableListOf("tag")
        val artifact = LlmArtifact("Title", "Description", tags, fields, "Body", "Notes")
        val findings = mutableListOf(LlmReview.Finding(LlmRubricCriterion.OUTPUT_FORMAT, LlmReviewSeverity.LOW, "quote", "problem", "suggestion",
            LlmReview.QuoteMatch.Matched(1, 5)))
        val review = LlmReview("Summary", findings)
        val action = AssistantAction.Improve("Source", "Instruction", findings)
        options.clear()
        fields.clear()
        tags.clear()
        findings.clear()
        assertEquals(listOf(FieldOption("label", "value")), artifact.fields.single().options)
        assertEquals(listOf("tag"), artifact.tags)
        assertEquals(review.findings, action.selectedFindings)
        assertEquals(LlmReview.QuoteMatch.Matched(1, 5), review.findings.single().quoteMatch)
        assertFailsWith<UnsupportedOperationException> { (artifact.fields as MutableList).clear() }
        assertFailsWith<UnsupportedOperationException> { (field.options as MutableList).clear() }
        assertEquals("output_format", review.findings.single().criterion.rawValue)
        assertEquals("low", review.findings.single().severity.rawValue)
    }

    @Test fun suspendSecretPortSupportsPersistedRollbackAndIdempotentDelete() = runTest {
        val store = MemorySecretStore()
        val first = SecretAccount.provider(ProviderProfileID())
        val second = SecretAccount("device-token", "account")
        val before = SecretValue("old payload")
        assertNull(store.read(first, SecretReadSource.EFFECTIVE))
        assertEquals(SecretTier.KEYSTORE, store.write(before, first))
        store.write(SecretValue("other account"), second)
        val old = store.read(first, SecretReadSource.PERSISTED)!!
        store.write(SecretValue("new payload"), first)
        store.write(old.value, first)
        assertEquals(before, store.read(first, SecretReadSource.EFFECTIVE)!!.value)
        store.delete(first)
        store.delete(first)
        assertNull(store.read(first, SecretReadSource.PERSISTED))
        assertEquals(SecretValue("other account"), store.read(second, SecretReadSource.PERSISTED)!!.value)
    }

    private fun profile(id: ProviderProfileID = ProviderProfileID(), kind: ProviderKind = ProviderKind.ANTHROPIC,
                        base: String = "https://example.com", model: String = "manual"): ProviderProfile =
        ProviderProfile(id, "Name", kind, base, model, SecretAccount.provider(id))

    private class MemorySecretStore : SecretStore {
        private val values = mutableMapOf<SecretAccount, StoredSecret>()

        override suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret? = values[account]
        override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier {
            values[account] = StoredSecret(value, SecretTier.KEYSTORE)
            return SecretTier.KEYSTORE
        }
        override suspend fun delete(account: SecretAccount) { values.remove(account) }
    }
}
