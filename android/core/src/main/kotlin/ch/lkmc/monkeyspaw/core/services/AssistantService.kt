package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.llm.AssistantModelList
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.coroutines.*

/** Explicit actions and pure candidate preparation. L16 owns checked publication. */
class AssistantService(
    private val providerSettings: ProviderSettingsService,
    private val anthropic: AssistantClient,
    private val openAICompatible: AssistantClient,
    private val io: CoroutineDispatcher,
    private val clock: Clock,
    private val entropy: Entropy,
    private val monotonic: MonotonicClock = MonotonicClock(System::nanoTime),
    private val timer: CoroutineDispatcher = Dispatchers.Default,
) {
    val selectedProfile: ProviderProfile? get() = providerSettings.snapshot.settings.let { settings ->
        settings.profiles.firstOrNull { it.id == settings.selectedProfileID }
    }

    internal fun isCurrent(context: AssistantContext): Boolean = context.profile == selectedProfile

    fun perform(command: AssistantCommand, context: AssistantContext, effort: AssistantEffort? = null,
                transcript: List<AssistantMessage> = emptyList(), feedback: String? = null): AssistantOperation<AssistantActionResult> {
        val deadline = monotonic.nowNanos() + Limits.llmBudgetNanos
        val turns = transcript.immutableCopy()
        return operation(deadline) {
            checkDeadline(deadline)
            val localIssues = validate(context, command)
            val profile = context.profile ?: throw AssistantError.NotConfigured
            val connection = providerSettings.connection(profile.id)
            currentCoroutineContext().ensureActive()
            if (!isCurrent(context) || connection.kind != profile.kind || connection.baseURL != profile.baseURL ||
                connection.modelID != profile.modelID) throw AssistantFailure.StaleContext
            checkDeadline(deadline)
            val response = client(connection).perform(AssistantRequest(command.action(context), effort, turns, feedback), connection, deadline)
            val issues = when (val output = response.output) {
                is AssistantOutput.Artifact -> output.value.issues
                is AssistantOutput.Review -> localIssues
            }
            AssistantActionResult(response, issues)
        }
    }

    /** Identity is finalized before the diff; retained IDs survive explicit feedback and Show diff. */
    fun prepare(artifact: LlmArtifact, command: AssistantCommand, context: AssistantContext,
                retainingID: ULID? = null): AssistantOperation<AssistantCandidate> = operation {
        validate(context, command)
        val original = if (command is AssistantCommand.Write) null else context.editor?.document()
        val merged = when (command) {
            is AssistantCommand.Write -> ArtifactMerge.write(artifact, retainingID ?: freshID())
            is AssistantCommand.Improve -> ArtifactMerge.improve(artifact, original ?: throw AssistantFailure.NoEditor)
            AssistantCommand.Review -> throw AssistantError.InvalidOutput
        }
        var document = when (merged) {
            is ArtifactMergeResult.Ready -> merged.candidate.document
            is ArtifactMergeResult.Invalid -> throw AssistantFailure.Invalid(merged.issues)
            is ArtifactMergeResult.Failed -> throw merged.error
        }
        if (context.access.mutationAccess == AssistantMutationAccess.PRIVATE_COPY && command is AssistantCommand.Improve) {
            document = withoutIdentity(document)
        }
        if (document.frontMatter.id == null) {
            val loaded = if (command is AssistantCommand.Improve &&
                context.access.mutationAccess == AssistantMutationAccess.CURRENT_SCOPE) context.editor?.loadedID else null
            document = PromptMutations.assigningIdentity(loaded ?: retainingID ?: freshID(), document, document.frontMatter.title + ".md")
        }
        val content = ArtifactMergeCandidate(document)
        val diff = ArtifactDiff.compare(original, content)
        currentCoroutineContext().ensureActive()
        if (!isCurrent(context)) throw AssistantFailure.StaleContext
        AssistantCandidate(content, diff, context, context.access.mutationAccess)
    }

    /** One intent budget covers credential resolution and all pages, with no persistence. */
    fun testConnection(draft: ProviderDraft): AssistantConnectionTest {
        val deadline = monotonic.nowNanos() + Limits.modelListTimeoutNanos
        return AssistantConnectionTest(operation(deadline) {
            checkDeadline(deadline)
            val connection = providerSettings.resolveForTesting(draft)
            currentCoroutineContext().ensureActive()
            checkDeadline(deadline)
            models(connection, deadline)
        })
    }

    private fun validate(context: AssistantContext, command: AssistantCommand): List<PromptIssue> {
        var localIssues: List<PromptIssue> = emptyList()
        val editor = context.editor
        if (editor != null) {
            when (editor.availability) {
                AssistantEditorAvailability.AVAILABLE -> Unit
                AssistantEditorAvailability.BUSY -> throw AssistantFailure.EditorBusy
                AssistantEditorAvailability.CONFLICTED -> throw AssistantFailure.EditorConflict
            }
            if (command !is AssistantCommand.Write) {
                editor.readOnlyReason?.let { throw AssistantFailure.ReadOnly(it) }
                if (editor.stamp == null && !editor.isNew) throw AssistantFailure.EditorConflict
                val document = editor.document()
                if (document.isReadOnly) throw AssistantFailure.ReadOnly(SourceReadOnlyReason.FUTURE_FORMAT)
                val issues = document.issues
                localIssues = issues
                if (issues.any { it.severity == PromptIssueSeverity.ERROR }) throw AssistantFailure.Invalid(issues)
                if (document.frontMatter.isPrivate) throw AssistantError.PrivatePrompt
            }
        } else if (command !is AssistantCommand.Write) throw AssistantFailure.NoEditor
        if (context.access == AssistantAccessState.UNAVAILABLE) throw AssistantError.AccessDenied
        if (context.profile == null) throw AssistantError.NotConfigured
        if (!isCurrent(context)) throw AssistantFailure.StaleContext
        return localIssues
    }

    private fun withoutIdentity(document: PromptDocument): PromptDocument {
        val header = document.preservedHeader?.let { original ->
            original.copy(entries = original.entries.filterNot { PortableYaml.string(it.key) == "id" })
        }
        val changed = PromptDocument(document.source, document.body, document.frontMatter.copy(id = null),
            document.template, document.decodingIssues, header, document.declarationLocations)
        return PromptCodec.parse(PromptCodec.write(changed), document.frontMatter.title + ".md")
    }

    private suspend fun models(connection: ProviderConnection, deadline: Long): List<ModelDescriptor> {
        val models = mutableMapOf<String, ModelDescriptor>()
        val cursors = mutableSetOf<String>()
        var afterID: String? = null
        var count = 0
        var bytes = 0
        repeat(Limits.modelListPageCap) {
            currentCoroutineContext().ensureActive()
            checkDeadline(deadline)
            val page = client(connection).listModels(connection, afterID, deadline)
            currentCoroutineContext().ensureActive()
            checkDeadline(deadline)
            if (page.models.size > Limits.modelListEntryCap - count) throw AssistantError.InvalidOutput
            count += page.models.size
            val cursorBytes = listOfNotNull(page.firstID, page.lastID).sumOf { it.toByteArray(Charsets.UTF_8).size.toLong() }
            if (cursorBytes > Limits.modelListByteCap - bytes) throw AssistantError.InvalidOutput
            bytes += cursorBytes.toInt()
            for (model in page.models) {
                if (!AssistantModelList.validID(model.id)) throw AssistantError.InvalidOutput
                val size = model.id.toByteArray(Charsets.UTF_8).size.toLong() +
                    (model.displayName?.toByteArray(Charsets.UTF_8)?.size ?: 0)
                if (size > Limits.modelListByteCap - bytes) throw AssistantError.InvalidOutput
                bytes += size.toInt()
                val name = listOfNotNull(models[model.id]?.displayName, model.displayName).minWithOrNull(::compareUTF8)
                models[model.id] = ModelDescriptor(model.id, name)
            }
            if (!page.hasMore) return models.values.sortedWith { a, b -> compareUTF8(a.id, b.id) }
            val cursor = page.lastID
            if (page.models.isEmpty() || cursor == null || !AssistantModelList.validID(cursor) || !cursors.add(cursor)) {
                throw AssistantError.InvalidOutput
            }
            afterID = cursor
        }
        throw AssistantError.InvalidOutput
    }

    private fun compareUTF8(a: String, b: String): Int {
        val left = a.toByteArray(Charsets.UTF_8)
        val right = b.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(left.size, right.size)) {
            val order = (left[index].toInt() and 255).compareTo(right[index].toInt() and 255)
            if (order != 0) return order
        }
        return left.size.compareTo(right.size)
    }

    private fun client(connection: ProviderConnection): AssistantClient =
        if (connection.kind == ProviderKind.ANTHROPIC) anthropic else openAICompatible

    private fun freshID(): ULID = ULID.generate(clock.now(), entropy.bytes(Limits.ulidEntropyBytes))

    private fun checkDeadline(deadline: Long) {
        if (deadline - monotonic.nowNanos() <= 0) throw AssistantError.Transport(HttpTransportError.DeadlineExceeded)
    }

    private fun <T> operation(deadline: Long? = null, work: suspend () -> T): AssistantOperation<T> =
        AssistantOperation<T>().also { operation ->
            operation.start(io, timer, deadline?.let { { it - monotonic.nowNanos() } }, work)
        }

    override fun toString(): String = "<assistant service>"
}

class AssistantConnectionTest internal constructor(private val operation: AssistantOperation<List<ModelDescriptor>>) {
    fun cancel() = operation.cancel()

    suspend fun await(): ConnectionTestResult = try { ConnectionTestResult.Ok(operation.await()) }
    catch (error: AssistantFailure) {
        when (error) {
            is AssistantFailure.Settings -> ConnectionTestResult.Settings(error.error)
            is AssistantFailure.Assistant -> when (val cause = error.error) {
                AssistantError.Authentication -> ConnectionTestResult.Authentication
                AssistantError.ModelNotFound -> ConnectionTestResult.NotFound
                is AssistantError.RateLimited -> ConnectionTestResult.RateLimited(cause.retryAfterSeconds)
                is AssistantError.ProviderFailure -> if (cause.statusCode in listOf(405, 501)) ConnectionTestResult.UnsupportedListing
                    else ConnectionTestResult.ProviderFailure(cause.statusCode)
                AssistantError.Overloaded -> ConnectionTestResult.ProviderFailure(529)
                is AssistantError.Transport -> when (cause.error) {
                    HttpTransportError.Cancelled -> ConnectionTestResult.Cancelled
                    HttpTransportError.DeadlineExceeded -> ConnectionTestResult.Timeout
                    HttpTransportError.NetworkFailure, HttpTransportError.RedirectRefused -> ConnectionTestResult.Network
                    else -> ConnectionTestResult.InvalidResponse
                }
                else -> ConnectionTestResult.InvalidResponse
            }
            else -> ConnectionTestResult.InvalidResponse
        }
    }

    override fun toString(): String = "<assistant connection test>"
}
