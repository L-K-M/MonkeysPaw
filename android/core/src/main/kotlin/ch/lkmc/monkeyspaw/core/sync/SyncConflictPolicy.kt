package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssueCode
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.SyncBytes
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.Prompt
import ch.lkmc.monkeyspaw.core.syncapi.PromptScope
import ch.lkmc.monkeyspaw.core.syncapi.Severity
import java.time.Instant

internal sealed class SyncConflictPolicyError private constructor() : Exception("Sync conflict policy failed.", null, false, true) {
    data object InvalidIntent : SyncConflictPolicyError()
    data object InvalidHead : SyncConflictPolicyError()
    data object InvalidResponse : SyncConflictPolicyError()
    final override fun toString(): String = "<sync conflict policy error>"
}

/** Persist these exact sent facts before HTTP; a later disk read cannot replace them. */
internal class SyncConflictIntent(
    val id: ULID,
    val operation: SyncOperation,
    val baseRev: Long,
    val scope: SyncScopeKey,
    val path: String,
    sentBytes: ByteArray?,
    inputBytes: ByteArray,
    accessGeneration: Long,
) {
    private val saved = sentBytes?.let(::SyncBytes)
    val sentBytes: ByteArray? get() = saved?.copyBytes()
    val sentHash: SyncHash? = saved?.copyBytes()?.let(SyncHash::of)
    val fingerprint: SyncInputFingerprint

    init {
        val wire = runCatching { SyncPathValidator.validate(path, scope.pathScope) }.getOrNull()
        if (baseRev < 0 || operation != SyncOperation.PUT && baseRev == 0L ||
            operation == SyncOperation.PUT && saved == null || operation == SyncOperation.DELETE && saved != null ||
            wire?.path != path) throw SyncConflictPolicyError.InvalidIntent
        val bytes = this.sentBytes
        if (bytes != null) {
            val filename = LibraryPath.filename(path)
            val form = canonical(bytes, filename, scope)
            if (!form.bytes.contentEquals(bytes) || PromptCodec.parseFile(bytes, filename).frontMatter.id != id) {
                throw SyncConflictPolicyError.InvalidIntent
            }
            SyncConflictMetadata.origin(bytes, filename, scope.pathScope)
        }
        fingerprint = SyncInputFingerprint(inputBytes, path, scope, accessGeneration, operation)
    }

    // MOVE carries the destination-canonicalized server baseline, never an accompanying edit.
    override fun toString(): String = "<sync conflict intent>"
}

internal class SyncConflictHead(prompt: Prompt, userID: ULID) {
    val id: ULID
    val rev: Long
    val scope: SyncScopeKey
    val path: String
    private val saved: SyncBytes
    val bytes: ByteArray get() = saved.copyBytes()
    val hash: SyncHash
    val origin: SyncPromptOrigin?

    init {
        try {
            id = SyncIdentifiers.ulid(prompt.id)
            scope = when (val wire = prompt.scope) {
                PromptScope.User -> SyncScopeKey.User(userID)
                is PromptScope.Group -> SyncScopeKey.Group(SyncIdentifiers.ulid(wire.groupID))
            }
            val wire = SyncPathValidator.validate(prompt.path, scope.pathScope)
            if (wire.path != prompt.path || prompt.rev <= 0) throw SyncConflictPolicyError.InvalidHead
            path = prompt.path
            val bytes = prompt.content.encodeToByteArray(throwOnInvalidSequence = true)
            val filename = LibraryPath.filename(path)
            if (!canonical(bytes, filename, scope).bytes.contentEquals(bytes) ||
                PromptCodec.parseFile(bytes, filename).frontMatter.id != id) throw SyncConflictPolicyError.InvalidHead
            saved = SyncBytes(bytes)
            rev = prompt.rev
            hash = SyncHash.of(bytes)
            origin = SyncConflictMetadata.origin(bytes, filename, scope.pathScope)
        } catch (_: Exception) { throw SyncConflictPolicyError.InvalidHead }
    }

    override fun toString(): String = "<sync conflict head>"
}

internal sealed class SyncConflictOutcome {
    /** Adopt only the sent baseline; newer local bytes remain dirty without a copy. */
    class Acknowledged(val head: SyncConflictHead) : SyncConflictOutcome()
    class ServerWins(val head: SyncConflictHead, val local: SyncLibraryFile?) : SyncConflictOutcome()
    class RemoteDeleted(val local: SyncLibraryFile?) : SyncConflictOutcome()
    data object DeleteSucceeded : SyncConflictOutcome()
    class ClashRename(val path: String) : SyncConflictOutcome()
    class AdoptExisting(val head: SyncConflictHead) : SyncConflictOutcome()
    /** Refresh memberships; denial does not identify a viewer role. */
    class Denied(val restore: SyncConflictHead?, val local: SyncLibraryFile?, val error: SyncPromptError) : SyncConflictOutcome()
    class FileError(val error: SyncPromptError) : SyncConflictOutcome()
    final override fun toString(): String = "<sync conflict outcome>"
}

internal class SyncConflictCopyCandidate(val scope: SyncScopeKey, val file: SyncLibraryFile) {
    override fun toString(): String = "<sync conflict copy candidate>"
}

internal object SyncConflictPolicy {
    fun shouldAttempt(fingerprint: SyncInputFingerprint, lastError: SyncPromptError?): Boolean = lastError?.fingerprint != fingerprint

    /** Pure decisions. Transport/auth/protocol errors remain owned by the pass engine. */
    fun resolve(error: SyncHTTPClientError, intent: SyncConflictIntent, userID: ULID, local: SyncLibraryFile? = null,
                recorded: SyncPromptState? = null, accessibleHead: Prompt? = null,
                occupiedPaths: Collection<String> = emptyList()): SyncConflictOutcome? {
        if (intent.scope is SyncScopeKey.User && intent.scope.id != userID) throw SyncConflictPolicyError.InvalidIntent
        local?.validate()
        if (local != null && local.identity != PromptIdentity.Assigned(intent.id)) throw SyncConflictPolicyError.InvalidIntent
        return when (error) {
            is SyncHTTPClientError.Conflict -> {
                val envelope = error.head
                val head = SyncConflictHead(Prompt(intent.id.rawValue, envelope.rev, envelope.scope, envelope.path, envelope.content), userID)
                val sent = intent.sentBytes
                if (intent.operation != SyncOperation.DELETE && head.rev > intent.baseRev && head.scope == intent.scope &&
                    head.path == intent.path && head.hash == intent.sentHash && sent != null && head.bytes.contentEquals(sent)) {
                    SyncConflictOutcome.Acknowledged(head)
                } else SyncConflictOutcome.ServerWins(head, local)
            }
            is SyncHTTPClientError.PathTaken -> {
                if (intent.operation == SyncOperation.DELETE) throw SyncConflictPolicyError.InvalidResponse
                val sent = intent.sentBytes
                if (intent.operation == SyncOperation.PUT && intent.baseRev == 0L && sent != null) {
                    val existing = error.existing
                    val head = SyncConflictHead(Prompt(existing.id, existing.rev, wireScope(intent.scope), intent.path, existing.content), userID)
                    val scope = if (intent.scope is SyncScopeKey.User) CanonicalForm.Scope.USER else CanonicalForm.Scope.GROUP
                    if (CanonicalForm.equivalentForAdoption(sent, head.bytes, scope, LibraryPath.filename(intent.path))) {
                        return SyncConflictOutcome.AdoptExisting(head)
                    }
                }
                try { SyncConflictOutcome.ClashRename(SyncNaming.clash(intent.path, intent.scope.pathScope, occupiedPaths)) }
                catch (_: SyncNamingError.Exhausted) {
                    SyncConflictOutcome.FileError(SyncPromptError(SyncIssueCode.PathClash, intent.fingerprint))
                }
            }
            SyncHTTPClientError.Deleted -> if (intent.operation == SyncOperation.DELETE) SyncConflictOutcome.DeleteSucceeded
                else SyncConflictOutcome.RemoteDeleted(local)
            SyncHTTPClientError.NotFound -> if (intent.operation == SyncOperation.DELETE) SyncConflictOutcome.DeleteSucceeded
                else SyncConflictOutcome.FileError(SyncPromptError(SyncIssueCode.NotFound, intent.fingerprint))
            SyncHTTPClientError.Forbidden -> {
                var restore: SyncConflictHead? = null
                if (intent.baseRev > 0 && recorded != null && recorded.rev > 0 && accessibleHead != null) {
                    val head = runCatching { SyncConflictHead(accessibleHead, userID) }.getOrNull()
                    if (head?.id == intent.id && head.scope == recorded.scope && head.path == recorded.path) restore = head
                }
                SyncConflictOutcome.Denied(restore, local, SyncPromptError(SyncIssueCode.Forbidden, intent.fingerprint))
            }
            is SyncHTTPClientError.Validation -> {
                val issue = error.issues.firstOrNull() ?: throw SyncConflictPolicyError.InvalidResponse
                val code = issueCode(issue.code)
                if (issue.severity != Severity.ERROR || code == null) throw SyncConflictPolicyError.InvalidResponse
                SyncConflictOutcome.FileError(SyncPromptError(code, intent.fingerprint))
            }
            else -> null
        }
    }

    /** Choose a destination and ID once; replays consume the checked journal edit. */
    fun copy(file: SyncLibraryFile, origin: SyncPromptOrigin, userID: ULID, groupFolder: String? = null,
             device: String, at: Instant, freshID: ULID, occupiedPaths: Collection<String>,
             existingCopies: List<SyncConflictCopyCandidate> = emptyList(), excludingPaths: Set<String> = emptySet(),
             mutations: SyncLibraryMutations): SyncReconciliationCopy {
        file.validate()
        val document = PromptCodec.parseFile(file.bytes, LibraryPath.filename(file.path))
        val previous = runCatching { SyncConflictMetadata.origin(document) }.getOrNull()
        val chosenOrigin = if (origin == SyncPromptOrigin.Rescued) origin else previous ?: origin
        for (candidate in existingCopies.sortedWith { a, b -> pathOrder(a.file.path, b.file.path) }) {
            val current = candidate.file
            val identity = runCatching { current.identity }.getOrNull()
            if (chosenOrigin !is SyncPromptOrigin.ConflictOf || candidate.scope != SyncScopeKey.User(userID) ||
                current.path == file.path || current.path in excludingPaths || identity !is PromptIdentity.Assigned ||
                identity.id == document.frontMatter.id ||
                runCatching { SyncConflictMetadata.origin(current.bytes, LibraryPath.filename(current.path)) }.getOrNull() != chosenOrigin) continue
            val expected = runCatching { SyncConflictMetadata.copyBytes(file, identity.id, chosenOrigin, LibraryPath.filename(current.path)) }.getOrNull()
            if (expected?.contentEquals(current.bytes) != true) continue
            current.validate()
            return SyncReconciliationCopy(mutations.publication(current.bytes, current.path, current,
                SyncIdentityTransition(identity, identity)), chosenOrigin)
        }
        val destination = when (origin) {
            SyncPromptOrigin.Rescued -> SyncNaming.rescue(file.path, at, occupiedPaths)
            is SyncPromptOrigin.ConflictOf -> SyncNaming.conflict(file.path, groupFolder, device, at, occupiedPaths)
        }
        return SyncReconciliationCopy(mutations.rescue(file, destination, freshID, chosenOrigin), chosenOrigin)
    }

    /** Reserve incoming paths and previous allocations; exclude every copy this plan retires. */
    fun copies(plan: SyncReconciliationPlan, device: String, at: Instant, freshID: () -> ULID,
               existingCopies: List<SyncConflictCopyCandidate> = emptyList(), mutations: SyncLibraryMutations): Map<String, SyncReconciliationCopy> {
        val occupied = plan.occupiedPaths.toMutableSet()
        val excluded = mutableSetOf<String>()
        val losses = mutableListOf<SyncReconciliationPreservation>()
        fun exclude(installation: SyncReconciliationInstall) {
            occupied.add(installation.remote.libraryPath)
            excluded.add(installation.remote.libraryPath)
            installation.source?.let { excluded.add(it.path) }
        }
        for (operation in plan.operations) {
            when (operation) {
                is SyncReconciliationOperation.Preserve -> {
                    losses.add(operation.preservation)
                    excluded.add(operation.preservation.local.path)
                    operation.preservation.installation?.let(::exclude)
                }
                is SyncReconciliationOperation.Install -> exclude(operation.installation)
                is SyncReconciliationOperation.Remove -> excluded.add(operation.file.path)
                is SyncReconciliationOperation.RestoreUpdate -> Unit
                else -> throw SyncReconciliationError.RequiresPolicy
            }
        }
        val result = linkedMapOf<String, SyncReconciliationCopy>()
        for (loss in losses.sortedWith { a, b -> pathOrder(a.local.path, b.local.path) }) {
            val scope = plan.expectedState?.prompts?.get(PromptIdentity.Assigned(loss.id))?.scope
            val folder = if (scope is SyncScopeKey.Group) plan.expectedState.groups[scope.id]?.folder else null
            val origin = if (loss.reason == SyncReconciliationPreservation.Reason.RESTORE_MISSING) SyncPromptOrigin.Rescued
                else SyncPromptOrigin.ConflictOf(loss.id)
            val copy = copy(loss.local, origin, plan.nextState.binding.account.userID, folder, device, at, freshID(),
                occupied, existingCopies, excluded, mutations)
            result[loss.local.path] = copy
            occupied.add(copy.edit.path)
            excluded.add(copy.edit.path)
        }
        return result.syncMapCopy()
    }

    private fun wireScope(scope: SyncScopeKey): PromptScope = when (scope) {
        is SyncScopeKey.User -> PromptScope.User
        is SyncScopeKey.Group -> PromptScope.Group(scope.id.rawValue)
    }

    private fun issueCode(raw: String): SyncIssueCode? = PromptIssueCode.entries.firstOrNull { it.rawValue == raw }?.let(SyncIssueCode::Content)
        ?: SyncPathIssueCode.entries.firstOrNull { it.wireCode == raw }?.let(SyncIssueCode::Path)
        ?: if (raw == SyncIssueCode.IDMismatch.rawValue) SyncIssueCode.IDMismatch else null
}

private fun canonical(bytes: ByteArray, filename: String, scope: SyncScopeKey): CanonicalForm =
    if (scope is SyncScopeKey.User) CanonicalForm.user(bytes, filename) else CanonicalForm.group(bytes, filename)

private fun pathOrder(left: String, right: String): Int = Utf8Order.compare(left.encodeToByteArray(), right.encodeToByteArray())
