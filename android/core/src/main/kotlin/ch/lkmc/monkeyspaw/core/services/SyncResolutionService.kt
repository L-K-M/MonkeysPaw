package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactDiff
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.Base64
import kotlinx.coroutines.CancellationException

internal class SyncResolutionContext(
    val binding: SyncLibraryIdentity, val permit: SyncWorkPermit, val client: SyncHTTPClient,
    val graph: SyncEngineGraph, val clock: Clock,
)

/** Explicit conflict decisions use the engine's existing single writer and durable apply journal. */
class SyncResolutionService(private val sync: SyncEngine) {
    suspend fun preview(copy: PromptIdentity, session: SyncResolutionSession = SyncResolutionSession()): SyncResolutionPreview =
        sync.resolvingConflict { context ->
            session.bind(context.permit)
            try { preview(copy(copy, context), session, context) }
            finally { session.release(context.permit) }
        }

    suspend fun resolve(action: SyncResolutionAction, preview: SyncResolutionPreview): SyncResolutionResult =
        sync.resolvingConflict(preview.epoch) { context ->
            preview.session.bind(context.permit)
            try {
                check(preview, context)
                when (action) {
                    SyncResolutionAction.KEEP_BOTH -> {
                        val bytes = SyncConflictMetadata.settingOrigin(null, preview.baseline.bytes, LibraryPath.filename(preview.copyPath))
                        commit(preview, bytes, null, context)
                    }
                    SyncResolutionAction.KEEP_SERVER -> {
                        if (!preview.canKeepServer) throw SyncResolutionFailure.OriginalUnavailable
                        val current = preview(preview.baseline, preview.session, context)
                        if (!sameHead(preview.head, current.head)) return@resolvingConflict refreshed(preview, current)
                        commit(preview, null, null, context)
                    }
                    SyncResolutionAction.KEEP_MINE -> {
                        val current = preview(preview.baseline, preview.session, context)
                        check(preview, context)
                        if (!sameHead(preview.head, current.head) || !sameBytes(preview.candidateBytes, current.candidateBytes)) {
                            return@resolvingConflict refreshed(preview, current)
                        }
                        if (preview.role != current.role) throw SyncResolutionFailure.StaleAccess
                        current.mineRefusal?.let { throw it }
                        if (!sameFile(preview.original, current.original)) throw SyncResolutionFailure.StaleCopy
                        val head = current.head ?: throw SyncResolutionFailure.InvalidCandidate
                        val bytes = current.candidateBytes ?: throw SyncResolutionFailure.InvalidCandidate
                        checkOriginal(preview, context)
                        var acknowledged = head
                        // An identical head also completes a previous lost reply without another write.
                        if (!head.bytes.contentEquals(bytes)) {
                            context.permit.mutate { context.graph.journal.retainResolution(attempt(preview, context)) }
                            check(preview, context)
                            checkOriginal(preview, context)
                            val response = try {
                                context.client.putPrompt(head.id, PutPromptRequest(head.rev, wireScope(head.scope), head.path,
                                    bytes.decodeToString(throwOnInvalidSequence = true)))
                            } catch (_: SyncHTTPClientError.Conflict) {
                                return@resolvingConflict refreshed(preview, preview(preview.baseline, preview.session, context))
                            }
                            if (response.rev <= head.rev) throw SyncHTTPClientError.MalformedResponse
                            acknowledged = SyncConflictHead(Prompt(head.id.rawValue, response.rev, wireScope(head.scope),
                                head.path, bytes.decodeToString(throwOnInvalidSequence = true)), context.binding.account.userID)
                        }
                        // A late reply cannot discard a changed copy, original, access policy or closed view.
                        check(preview, context)
                        checkOriginal(preview, context)
                        commit(preview, null, acknowledged, context)
                    }
                }
                preview.consume()
                sync.committedMutation(SyncChangeOrigin.USER, preview.epoch)
                SyncResolutionResult.Resolved(action)
            } finally { preview.session.release(context.permit) }
        }

    private fun state(context: SyncResolutionContext): SyncState {
        context.permit.check()
        val graph = context.graph
        val state = graph.states.load(context.binding) ?: throw SyncResolutionFailure.Inactive
        val access = graph.mutations.accessSnapshot
        if (access.isBlocked || access.binding != null && access.binding != context.binding) throw SyncResolutionFailure.StaleAccess
        return state
    }

    private fun copy(identity: PromptIdentity, context: SyncResolutionContext): SyncLibraryFile {
        val state = state(context)
        if (identity !is PromptIdentity.Assigned) throw SyncResolutionFailure.InvalidCopy
        val file = context.graph.mutations.listedFiles().filter { it.identity == identity }.singleOrNull()
            ?: throw SyncResolutionFailure.InvalidCopy
        val location = SyncLocalScanner.location(file.path, context.binding, state.groups)
        if (location?.scope != SyncScopeKey.User(context.binding.account.userID) ||
            state.prompts[identity]?.scope?.let { it != location.scope } == true ||
            SyncConflictMetadata.origin(file.bytes, LibraryPath.filename(file.path)) == null) throw SyncResolutionFailure.InvalidCopy
        val owner = context.graph.accounts.binding(context.binding.root)
        if (owner != null && (owner.owner != context.binding.account || owner.isHeld(identity, file.path, file.hash)) ||
            context.graph.journal.heldRescues(context.binding.root).any { it.path == file.path || it.hash == file.hash }) {
            throw SyncResolutionFailure.AccessDenied
        }
        return file
    }

    private fun versions(context: SyncResolutionContext): List<Long> =
        listOf(context.graph.states.snapshot.accessVersion) + context.graph.accounts.accessVersions

    private fun check(preview: SyncResolutionPreview, context: SyncResolutionContext) {
        preview.check()
        if (preview.binding != context.binding || preview.graph !== context.graph) throw SyncResolutionFailure.StaleSession
        state(context)
        if (context.graph.mutations.accessSnapshot.generation != preview.accessGeneration || versions(context) != preview.accessVersions) {
            throw SyncResolutionFailure.StaleAccess
        }
        if (!sameFile(copy(preview.copyIdentity, context), preview.baseline)) throw SyncResolutionFailure.StaleCopy
    }

    private suspend fun preview(file: SyncLibraryFile, session: SyncResolutionSession,
                                context: SyncResolutionContext): SyncResolutionPreview {
        session.check()
        val state = state(context)
        val access = context.graph.mutations.accessSnapshot
        val versions = versions(context)
        val origin = SyncConflictMetadata.origin(file.bytes, LibraryPath.filename(file.path)) ?: throw SyncResolutionFailure.InvalidCopy
        val originalID = (origin as? SyncPromptOrigin.ConflictOf)?.promptID
        var head: SyncConflictHead? = null
        var role: Role? = null
        var refusal: SyncResolutionFailure? = if (originalID == null) SyncResolutionFailure.OriginalUnavailable else null
        if (originalID != null) {
            try {
                val checked = SyncConflictHead(context.client.prompt(originalID), context.binding.account.userID)
                if (checked.id != originalID) throw SyncHTTPClientError.MalformedResponse
                head = checked
                if (checked.scope is SyncScopeKey.Group) {
                    val me = context.client.me()
                    if (me.user.id != context.binding.account.userID.rawValue) throw SyncHTTPClientError.MalformedResponse
                    role = me.groups.firstOrNull { it.groupID == checked.scope.id.rawValue }?.role
                    if (role == null || role == Role.VIEWER || state.groups[checked.scope.id]?.role.let { it == null || it == Role.VIEWER }) {
                        refusal = SyncResolutionFailure.AccessDenied
                    }
                }
            } catch (error: SyncHTTPClientError) {
                refusal = when (error) {
                    SyncHTTPClientError.NotFound, SyncHTTPClientError.Deleted -> SyncResolutionFailure.OriginalUnavailable
                    SyncHTTPClientError.Forbidden -> SyncResolutionFailure.AccessDenied
                    else -> throw error
                }
            }
        }
        var candidate: ByteArray? = null
        var diff: ArtifactDiff? = null
        var original: SyncLibraryFile? = null
        if (head != null) {
            try {
                val filename = LibraryPath.filename(head.path)
                val unmarked = SyncConflictMetadata.settingOrigin(null, file.bytes, filename)
                val replaced = PromptMutations.replacingIdentity(head.id, PromptCodec.parseFile(unmarked, filename), filename)
                candidate = SyncLocalScanner.canonical(replaced.source.encodeToByteArray(throwOnInvalidSequence = true), head.path, head.scope).bytes
                diff = ArtifactDiff.compare(head.bytes, candidate)
                val path = SyncLocalScanner.rooted(head.path, head.scope, state.groups)
                original = context.graph.mutations.read(path)
                val matches = context.graph.mutations.listedFiles().filter { it.identityKey == head.id.rawValue }
                if (original?.identityKey?.let { it != head.id.rawValue } == true ||
                    matches.size > 1 || matches.singleOrNull()?.path?.let { it != path } == true) {
                    refusal = SyncResolutionFailure.OriginalUnavailable
                } else if (original != null) {
                    val form = SyncLocalScanner.canonical(original.bytes, head.path, head.scope)
                    if (SyncHash.of(form.bytes) != state.prompts[original.identity]?.canonicalHash && !form.bytes.contentEquals(head.bytes)) {
                        refusal = SyncResolutionFailure.StaleCopy
                    }
                    if (access.access(path, original.identity).readOnlyReason != null) refusal = SyncResolutionFailure.AccessDenied
                }
                val owner = context.graph.accounts.binding(context.binding.root)
                if (owner?.isHeld(PromptIdentity.Assigned(head.id), path, original?.hash ?: head.hash) == true) {
                    refusal = SyncResolutionFailure.AccessDenied
                }
            } catch (_: Exception) { refusal = refusal ?: SyncResolutionFailure.InvalidCandidate }
        }
        val result = SyncResolutionPreview(file.identity, file.path, originalID, candidate, diff, refusal, file, original,
            head, context.binding, context.graph, context.permit.epoch, access.generation, versions, role, session)
        check(result, context)
        return result
    }

    private fun checkOriginal(preview: SyncResolutionPreview, context: SyncResolutionContext) {
        val head = preview.head ?: throw SyncResolutionFailure.OriginalUnavailable
        val path = SyncLocalScanner.rooted(head.path, head.scope, state(context).groups)
        if (!sameFile(preview.original, context.graph.mutations.read(path)) ||
            context.graph.mutations.listedFiles().any { it.identityKey == head.id.rawValue && it.path != path }) {
            throw SyncResolutionFailure.StaleCopy
        }
    }

    private fun commit(preview: SyncResolutionPreview, copyBytes: ByteArray?, acknowledged: SyncConflictHead?, context: SyncResolutionContext) {
        check(preview, context)
        val old = state(context)
        var next = old
        val mutations = context.graph.mutations
        val edits = mutableListOf<SyncLibraryEdit>()
        if (acknowledged != null) {
            checkOriginal(preview, context)
            val path = SyncLocalScanner.rooted(acknowledged.path, acknowledged.scope, old.groups)
            val identity = PromptIdentity.Assigned(acknowledged.id)
            preview.original?.let { mutations.preserveHistory(it, context.clock.now()) }
            edits.add(mutations.publication(acknowledged.bytes, path, preview.original,
                SyncIdentityTransition(preview.original?.identity, identity)))
            // Canonical installation consumes any raw group favourite input; the personal choice stays private.
            next = next.copy(prompts = next.prompts + (identity to SyncPromptState(acknowledged.scope, acknowledged.path,
                acknowledged.rev, acknowledged.hash, acknowledged.origin)))
        }
        if (copyBytes != null) {
            mutations.preserveHistory(preview.baseline, context.clock.now())
            edits.add(mutations.publication(copyBytes, preview.copyPath, preview.baseline,
                SyncIdentityTransition(preview.copyIdentity, preview.copyIdentity)))
            next.prompts[preview.copyIdentity]?.let { record ->
                next = next.copy(prompts = next.prompts + (preview.copyIdentity to record.copy(origin = null, lastError = null)))
            }
        } else {
            edits.add(mutations.trash(preview.baseline))
            if (next.prompts[preview.copyIdentity]?.rev == 0L) next = next.copy(prompts = next.prompts - preview.copyIdentity)
        }
        check(preview, context)
        if (context.graph.journal.apply(SyncApplyPlan(old, next, edits), context.permit) != SyncApplyOutcome.Committed) {
            throw SyncResolutionFailure.RecoveryRequired
        }
    }

    private fun attempt(preview: SyncResolutionPreview, context: SyncResolutionContext): ByteArray {
        val head = preview.head ?: throw SyncResolutionFailure.InvalidCandidate
        fun bytes(value: ByteArray) = wireString(Base64.getEncoder().encodeToString(value))
        return syncDocumentBytes(syncObject("version" to wireLong(1), "account" to SyncAccountJson.identity(context.binding.account),
            "root" to wireString(context.binding.root.path), "originalID" to wireString(head.id.rawValue),
            "scope" to wireString(head.scope.rawValue), "path" to wireString(head.path), "baseRev" to wireLong(head.rev),
            "serverBytes" to bytes(head.bytes), "candidateBytes" to bytes(preview.candidateBytes ?: throw SyncResolutionFailure.InvalidCandidate),
            "candidateHash" to wireString(SyncHash.of(preview.candidateBytes ?: throw SyncResolutionFailure.InvalidCandidate).rawValue),
            "copyID" to wireString(preview.copyIdentity.storageKey), "copyPath" to wireString(preview.copyPath),
            "copyStamp" to wireString(preview.baseline.stamp.journalToken()), "copyBytes" to bytes(preview.baseline.bytes)))
    }

    private fun refreshed(old: SyncResolutionPreview, next: SyncResolutionPreview): SyncResolutionResult {
        old.consume()
        return SyncResolutionResult.Refreshed(next)
    }

    private fun sameHead(left: SyncConflictHead?, right: SyncConflictHead?): Boolean =
        if (left == null || right == null) left == null && right == null else left.id == right.id && left.rev == right.rev &&
            left.scope == right.scope && left.path == right.path && left.bytes.contentEquals(right.bytes)

    private fun sameFile(left: SyncLibraryFile?, right: SyncLibraryFile?): Boolean =
        if (left == null || right == null) left == null && right == null else left.path == right.path && left.stamp == right.stamp &&
            left.identity == right.identity && left.bytes.contentEquals(right.bytes)

    private fun sameBytes(left: ByteArray?, right: ByteArray?): Boolean =
        if (left == null || right == null) left == null && right == null else left.contentEquals(right)

    private fun wireScope(scope: SyncScopeKey): PromptScope = when (scope) {
        is SyncScopeKey.User -> PromptScope.User
        is SyncScopeKey.Group -> PromptScope.Group(scope.id.rawValue)
    }

    companion object {
        /** Fixed UI reasons only; never expose HTTP/parser/driver bodies. */
        fun failure(error: Throwable): SyncResolutionFailure = when (error) {
            is SyncResolutionFailure -> error
            SyncHTTPClientError.Unauthorized -> SyncResolutionFailure.NeedsSignIn
            SyncHTTPClientError.Forbidden, LibraryError.AccessDenied -> SyncResolutionFailure.AccessDenied
            SyncHTTPClientError.NotFound, SyncHTTPClientError.Deleted -> SyncResolutionFailure.OriginalUnavailable
            LibraryError.AccessChanged -> SyncResolutionFailure.StaleAccess
            is CancellationException -> SyncResolutionFailure.Inactive
            is SyncHTTPClientError.Transport, is SyncHTTPClientError.ServerFailure, is SyncHTTPClientError.RateLimited -> SyncResolutionFailure.Offline
            is SyncError, is SyncFileOperationError, LibraryError.RecoveryRequired -> SyncResolutionFailure.RecoveryRequired
            else -> SyncResolutionFailure.OperationFailed
        }
    }
}
