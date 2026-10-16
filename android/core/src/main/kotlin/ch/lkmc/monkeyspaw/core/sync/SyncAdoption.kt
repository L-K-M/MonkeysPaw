package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.SyncFileMode
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.ExistingPrompt
import ch.lkmc.monkeyspaw.core.syncapi.Role
import java.nio.charset.CharacterCodingException
import java.time.Instant

internal sealed class SyncAdoptionDecision {
    class Adopt(val remote: SyncReconciliationRemote, val local: SyncLibraryFile) : SyncAdoptionDecision()
    class Conflict(val remote: SyncReconciliationRemote, val local: SyncLibraryFile) : SyncAdoptionDecision()
    class Clash(val remote: SyncReconciliationRemote, val occupant: SyncLibraryFile) : SyncAdoptionDecision()
    class Held(val path: String) : SyncAdoptionDecision()
    class LocalVisibility(val remote: SyncReconciliationRemote) : SyncAdoptionDecision()
    data object Unmatched : SyncAdoptionDecision()
    /** The attempted incarnation disappeared, moved or changed identity during HTTP. */
    data object Replan : SyncAdoptionDecision()
    final override fun toString(): String = "<sync adoption decision>"
}

internal object SyncAdoption {
    /** ID first across accessible scopes; alternative IDs require same scope/path key and B5 equality. */
    fun match(remote: SyncReconciliationRemote, local: SyncReconciliationSnapshot,
              groups: Map<ULID, SyncGroupState>): SyncAdoptionDecision {
        validate(remote, local.binding, groups)
        if (local.availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        if (!LibraryPath.isPrompt(remote.libraryPath)) return SyncAdoptionDecision.LocalVisibility(remote)
        if (local.files.any { SyncLocalScanner.location(it.path, local.binding, groups) == null }) {
            throw SyncReconciliationError.RequiresPolicy
        }
        local.files.forEach { it.validate() }
        val targets = local.files.filter { SyncNaming.pathKey(it.path) == SyncNaming.pathKey(remote.libraryPath) }
            .sortedWith { a, b -> Utf8Order.compare(a.path.encodeToByteArray(), b.path.encodeToByteArray()) }
        targets.firstOrNull { isHeld(it, local) }?.let { return SyncAdoptionDecision.Held(it.path) }
        if (targets.size > 1) return SyncAdoptionDecision.Clash(remote, targets[0])
        val owners = local.files.filter { it.identityKey == remote.id.rawValue && !isHeld(it, local) }
        if (owners.size > 1) throw SyncReconciliationError.InvalidLocalSnapshot
        owners.firstOrNull()?.let { owner ->
            targets.firstOrNull()?.let { if (it.path != owner.path) return SyncAdoptionDecision.Clash(remote, it) }
            return if (equivalent(owner.bytes, remote)) SyncAdoptionDecision.Adopt(remote, owner)
                else SyncAdoptionDecision.Conflict(remote, owner)
        }
        val target = targets.firstOrNull() ?: return SyncAdoptionDecision.Unmatched
        val location = SyncLocalScanner.location(target.path, local.binding, groups) ?: return SyncAdoptionDecision.Unmatched
        if (location.scope != remote.scope || SyncNaming.pathKey(location.path) != SyncNaming.pathKey(remote.path)) {
            return SyncAdoptionDecision.Unmatched
        }
        return if (equivalent(target.bytes, remote)) SyncAdoptionDecision.Adopt(remote, target)
            else SyncAdoptionDecision.Clash(remote, target)
    }

    /** Compare both the exact sent create and fresh incarnation, preserving edits made during HTTP. */
    fun pathTaken(existing: ExistingPrompt, intent: SyncConflictIntent, local: SyncReconciliationSnapshot,
                  groups: Map<ULID, SyncGroupState>): SyncAdoptionDecision {
        val sent = intent.sentBytes
        if (intent.operation != SyncOperation.PUT || intent.baseRev != 0L || sent == null) throw SyncConflictPolicyError.InvalidIntent
        val bytes = try { existing.content.encodeToByteArray(throwOnInvalidSequence = true) }
        catch (_: CharacterCodingException) { throw SyncReconciliationError.InvalidPull }
        val remote = SyncReconciliationRemote(SyncIdentifiers.ulid(existing.id), intent.scope, intent.path,
            SyncLocalScanner.rooted(intent.path, intent.scope, groups), existing.rev, bytes, SyncHash.of(bytes), mode(intent.scope, groups))
        validate(remote, local.binding, groups)
        if (local.availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        val candidates = local.files.filter { it.identityKey == intent.id.rawValue }
        val owners = candidates.filterNot { isHeld(it, local) }
        if (owners.size > 1) throw SyncReconciliationError.InvalidLocalSnapshot
        val file = owners.firstOrNull() ?: candidates.firstOrNull() ?: return SyncAdoptionDecision.Replan
        if (isHeld(file, local)) return SyncAdoptionDecision.Held(file.path)
        val location = SyncLocalScanner.location(file.path, local.binding, groups)
        if (location == null || location.scope != intent.scope || SyncNaming.pathKey(location.path) != SyncNaming.pathKey(intent.path)) {
            return SyncAdoptionDecision.Replan
        }
        if (!equivalent(sent, remote) || !equivalent(file.bytes, remote)) return SyncAdoptionDecision.Clash(remote, file)
        return match(remote, local, groups)
    }

    /** A preparatory journal retains old database/cursors; reconcile the complete pull again after commit. */
    fun application(decision: SyncAdoptionDecision, state: SyncState?, local: SyncReconciliationSnapshot,
                    groups: Map<ULID, SyncGroupState>, device: String, at: Instant, freshID: () -> ULID,
                    mutations: SyncLibraryMutations): SyncApplyPlan {
        if (state != null && state.binding != local.binding) throw SyncError.BindingMismatch
        var next = (state ?: SyncState(local.binding, groups = groups)).copy(groups = groups)
        val remote: SyncReconciliationRemote
        val source: SyncLibraryFile
        val losing: Boolean
        when (decision) {
            is SyncAdoptionDecision.Adopt -> { remote = decision.remote; source = decision.local; losing = false }
            is SyncAdoptionDecision.Conflict -> { remote = decision.remote; source = decision.local; losing = true }
            else -> throw SyncReconciliationError.RequiresPolicy
        }
        // Re-evaluate caller-supplied decisions so holds or a stale alternative ID cannot authorize overwrite.
        val checked = match(remote, local, groups)
        if (!(checked is SyncAdoptionDecision.Adopt && !losing && same(checked.local, source) ||
                checked is SyncAdoptionDecision.Conflict && losing && same(checked.local, source))) {
            throw SyncReconciliationError.RequiresPolicy
        }
        val identity = source.identity
        val destination = PromptIdentity.Assigned(remote.id)
        if (identity != destination && (next.prompts[identity]?.rev ?: 0) > 0) throw SyncReconciliationError.RequiresPolicy
        val edits = mutableListOf<SyncLibraryEdit>()
        if (losing) {
            val occupied = local.files.map { it.path }.toMutableSet().also { it.add(remote.libraryPath) }
            val candidates = local.files.mapNotNull { file ->
                val location = SyncLocalScanner.location(file.path, local.binding, groups)
                if (isHeld(file, local) || location == null) null else SyncConflictCopyCandidate(location.scope, file)
            }
            val id = freshID()
            if (local.files.any { it.identityKey == id.rawValue } || PromptIdentity.Assigned(id) in next.prompts) throw SyncError.InvalidState
            val scope = SyncLocalScanner.location(source.path, local.binding, groups)?.scope
            val folder = if (scope is SyncScopeKey.Group) groups[scope.id]?.folder else null
            val copy = SyncConflictPolicy.copy(source, SyncPromptOrigin.ConflictOf(remote.id), local.binding.account.userID,
                folder, device, at, id, occupied, candidates, setOf(source.path, remote.libraryPath), mutations)
            val bytes = copy.edit.bytes
            val copyID = bytes?.let { PromptCodec.parseFile(it, LibraryPath.filename(copy.edit.path)).frontMatter.id }
            if (copy.edit.heldIssue != null || copyID == null) throw SyncReconciliationError.RequiresPolicy
            val key = PromptIdentity.Assigned(copyID)
            val remembered = next.prompts[key]
            next = next.copy(prompts = next.prompts + (key to SyncPromptState(SyncScopeKey.User(local.binding.account.userID),
                remembered?.path ?: copy.edit.path, remembered?.rev ?: 0, remembered?.canonicalHash, copy.origin, remembered?.lastError)))
            edits.add(copy.edit)
        }
        val form = SyncLocalScanner.canonical(source.bytes, remote.path, remote.scope)
        next = SyncLocalScanner.migrating(next, identity, destination)
        val markers = SyncConflictMetadata.ingest(remote.bytes, LibraryPath.filename(remote.path), remote.scope.pathScope)
        val error = markers.issue?.let { SyncPromptError(it, SyncInputFingerprint(remote.bytes, remote.path, remote.scope, 0, SyncOperation.PUT)) }
        // Drop a group favourite before moving its baseline to private scope, keeping the immutable state valid.
        next = next.copy(prompts = next.prompts + (destination to SyncPromptState(remote.scope, remote.path, remote.rev,
            remote.hash, markers.origin, error)), favorites = if (remote.scope is SyncScopeKey.User) next.favorites - destination else next.favorites)
        if (remote.scope is SyncScopeKey.Group) next = next.applyGroupFavorite(form.favorite, destination)

        if (source.path == remote.libraryPath) {
            edits.add(mutations.publication(remote.bytes, remote.libraryPath, source, SyncIdentityTransition(identity, destination),
                remote.mode, SyncLibraryEdit.Kind.ADOPT, markers.issue))
        } else {
            val alias = mutations.read(remote.libraryPath)
            if (alias != null && (alias.stamp != source.stamp || !alias.bytes.contentEquals(source.bytes))) {
                throw SyncReconciliationError.RequiresPolicy
            }
            // One incarnation at both spellings is one file: publish exact case and never trash its live alias.
            val sameIDAtNewPath = identity == destination && alias == null
            edits.add(mutations.publication(remote.bytes, remote.libraryPath, alias,
                SyncIdentityTransition(if (sameIDAtNewPath) null else identity, destination), remote.mode,
                SyncLibraryEdit.Kind.ADOPT, markers.issue, if (sameIDAtNewPath) null else source))
            if (alias == null) edits.add(mutations.trash(source))
        }
        return SyncApplyPlan(state, next, edits)
    }

    /** Record excluded remote paths without claiming their bytes/revision/cursor were applied. */
    fun localVisibility(remote: SyncReconciliationRemote, state: SyncState?, binding: SyncLibraryIdentity,
                        groups: Map<ULID, SyncGroupState>, accessGeneration: Long = 0): SyncApplyPlan {
        if (state != null && state.binding != binding) throw SyncError.BindingMismatch
        validate(remote, binding, groups)
        if (LibraryPath.isPrompt(remote.libraryPath)) throw SyncError.InvalidState
        var next = (state ?: SyncState(binding, groups = groups)).copy(groups = groups)
        val identity = PromptIdentity.Assigned(remote.id)
        val previous = next.prompts[identity]
        val error = SyncPromptError(SyncIssueCode.LocalVisibility,
            SyncInputFingerprint(remote.bytes, remote.path, remote.scope, accessGeneration, SyncOperation.PUT))
        next = next.copy(prompts = next.prompts + (identity to SyncPromptState(previous?.scope ?: remote.scope,
            previous?.path ?: remote.path, previous?.rev ?: 0, previous?.canonicalHash, previous?.origin, error)))
        return SyncApplyPlan(state, next, emptyList())
    }

    private fun equivalent(bytes: ByteArray, remote: SyncReconciliationRemote): Boolean =
        CanonicalForm.equivalentForAdoption(bytes, remote.bytes,
            if (remote.scope is SyncScopeKey.User) CanonicalForm.Scope.USER else CanonicalForm.Scope.GROUP, LibraryPath.filename(remote.path))

    private fun isHeld(file: SyncLibraryFile, snapshot: SyncReconciliationSnapshot): Boolean =
        file.path in snapshot.heldPaths || !LibraryPath.isPrompt(file.path) || SyncLocalScanner.contentIssue(file) != null

    private fun same(lhs: SyncLibraryFile, rhs: SyncLibraryFile): Boolean = lhs.path == rhs.path && lhs.stamp == rhs.stamp &&
        lhs.identityKey == rhs.identityKey && lhs.hash == rhs.hash && lhs.bytes.contentEquals(rhs.bytes)

    private fun mode(scope: SyncScopeKey, groups: Map<ULID, SyncGroupState>): SyncFileMode =
        if (scope is SyncScopeKey.Group && groups[scope.id]?.role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL

    private fun validate(remote: SyncReconciliationRemote, binding: SyncLibraryIdentity, groups: Map<ULID, SyncGroupState>) {
        if (remote.scope is SyncScopeKey.User && remote.scope.id != binding.account.userID) throw SyncError.BindingMismatch
        val wire = SyncPathValidator.validate(remote.path, remote.scope.pathScope)
        val path = SyncLocalScanner.rooted(remote.path, remote.scope, groups)
        val form = SyncLocalScanner.canonical(remote.bytes, remote.path, remote.scope)
        val document = PromptCodec.parseFile(remote.bytes, LibraryPath.filename(remote.path))
        if (wire.path != remote.path || path != remote.libraryPath || !form.bytes.contentEquals(remote.bytes) ||
            remote.hash != SyncHash.of(remote.bytes) || document.frontMatter.id != remote.id || remote.rev <= 0 || remote.mode != mode(remote.scope, groups)) {
            throw SyncReconciliationError.InvalidPull
        }
    }
}
