package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.SyncFileMode
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.time.Instant
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal enum class SyncPushResult { ACKNOWLEDGED, UNCHANGED, REPLAN, HELD, SKIPPED, REFRESH_MEMBERSHIPS }

internal sealed class SyncPushError private constructor() : Exception("Sync push failed.", null, false, true) {
    data object Busy : SyncPushError()
    data object PendingOperation : SyncPushError()
    class ApplyRequired(val outcome: SyncApplyOutcome) : SyncPushError()
    final override fun toString(): String = "<sync push error>"
}

/** One disk candidate, including move-then-edit. The coordinator owns pass ordering and scheduling. */
internal class SyncPushEngine(
    private val binding: SyncLibraryIdentity,
    private val client: SyncHTTPClient,
    private val states: SyncStateStore,
    private val pending: SyncPendingOperationStore,
    private val mutations: SyncLibraryMutations,
    private val journal: SyncApplyJournal,
    private val ownership: () -> SyncLibraryBinding?,
    private val device: String,
    private val freshID: () -> ULID,
    private val now: () -> Instant = Instant::now,
    private val permit: SyncWorkPermit? = null,
    private val committed: () -> Unit = {},
) {
    private val lock = ReentrantLock()
    private var running = false
    /** Validated head requiring folder/occupant preparation; the exact request stays durable. */
    var policyHead: SyncConflictHead? = null
        private set

    init {
        if (client.server.baseURL != binding.account.serverURL) throw SyncError.BindingMismatch
    }

    suspend fun push(change: SyncLocalChange, availability: SyncReconciliationSnapshot.Availability,
                     accessGeneration: Long = 0, baseBytes: ByteArray? = null): SyncPushResult {
        begin(availability)
        try {
            journal.pending?.let { throw SyncPushError.ApplyRequired(SyncApplyOutcome.RecoveryRequired(it.id)) }
            if (pending.load(binding) != null) throw SyncPushError.PendingOperation
            val local = when (change) {
                is SyncLocalChange.Create -> change.prompt
                is SyncLocalChange.Update -> change.prompt
                is SyncLocalChange.Rename -> change.prompt
                is SyncLocalChange.Move -> change.prompt
                is SyncLocalChange.Delete -> {
                    val id = (change.identity as? PromptIdentity.Assigned)?.id ?: return SyncPushResult.REPLAN
                    val state = currentState()
                    val record = state.prompts[change.identity]?.takeIf { it.rev > 0 } ?: return SyncPushResult.UNCHANGED
                    if (!writable(record.scope, state)) return SyncPushResult.REPLAN
                    val path = SyncLocalScanner.rooted(record.path, record.scope, state.groups)
                    val snapshot = snapshot(state)
                    if (snapshot.files.any { it.identityKey == id.rawValue || it.path == path } || mutations.read(path) != null) {
                        return SyncPushResult.REPLAN
                    }
                    if (isHeld(change.identity, path, record.canonicalHash!!)) return SyncPushResult.HELD
                    val intent = SyncConflictIntent(id, SyncOperation.DELETE, record.rev, record.scope, record.path,
                        null, byteArrayOf(), accessGeneration)
                    return send(SyncPendingOperation(binding, intent, path, null, record))
                }
            }
            val id = (local.identity as? PromptIdentity.Assigned)?.id ?: return SyncPushResult.REPLAN
            return pushFile(id, local.file.path, accessGeneration, baseBytes)
        } finally { end() }
    }

    /** Run before another pull: GET distinguishes a lost acknowledgement from unsent work. */
    suspend fun resume(availability: SyncReconciliationSnapshot.Availability, accessGeneration: Long = 0): SyncPushResult {
        begin(availability)
        try {
            if (journal.pending != null) requireCommit(journal.replay(permit))
            val request = pending.load(binding) ?: return SyncPushResult.UNCHANGED
            val state = currentState()
            val local = live(request.intent.id, snapshot(state))
            if (held(request, local)) { retireHeld(request); return SyncPushResult.HELD }
            val result = try {
                val head = SyncConflictHead(client.prompt(request.intent.id), binding.account.userID)
                if (head.id != request.intent.id) throw SyncConflictPolicyError.InvalidHead
                if (unchangedHead(head, request)) { clearPending(); return SyncPushResult.REPLAN }
                dispatch(SyncHTTPClientError.Conflict(ConflictHead(head.rev, wireScope(head.scope), head.path,
                    head.bytes.decodeToString(throwOnInvalidSequence = true))), request)
            } catch (error: SyncHTTPClientError) {
                if (error == SyncHTTPClientError.NotFound && request.intent.baseRev == 0L) {
                    clearPending()
                    return SyncPushResult.REPLAN
                }
                // Invisible GET does not prove that an update or move was deleted.
                dispatch(error, request)
            }
            return finishMove(request, result, accessGeneration)
        } finally { end() }
    }

    private suspend fun pushFile(id: ULID, path: String, accessGeneration: Long, baseBytes: ByteArray?): SyncPushResult {
        val state = currentState()
        val key = PromptIdentity.Assigned(id)
        val file = mutations.read(path) ?: return SyncPushResult.REPLAN
        if (file.identityKey != id.rawValue || !LibraryPath.isPrompt(file.path) || SyncLocalScanner.contentIssue(file) != null) {
            return SyncPushResult.REPLAN
        }
        val location = SyncLocalScanner.location(path, binding, state.groups) ?: return SyncPushResult.REPLAN
        if (isHeld(key, path, file.hash)) return SyncPushResult.HELD
        val destination = SyncPathValidator.validate(location.path, location.scope.pathScope).path
        val form = SyncLocalScanner.canonical(file.bytes, destination, location.scope)
        val recorded = state.prompts[key]
        if (!writable(location.scope, state) || recorded?.let { !writable(it.scope, state) } == true) return SyncPushResult.REPLAN
        val operation = if (recorded != null && recorded.rev > 0 && recorded.scope != location.scope) SyncOperation.MOVE else SyncOperation.PUT
        if (recorded?.scope == location.scope && recorded.path == destination && recorded.canonicalHash == SyncHash.of(form.bytes)) {
            return SyncPushResult.UNCHANGED
        }
        val fingerprint = SyncInputFingerprint(file.bytes, destination, location.scope, accessGeneration, operation)
        if (!SyncConflictPolicy.shouldAttempt(fingerprint, recorded?.lastError)) return SyncPushResult.SKIPPED
        var sent = form.bytes
        if (operation == SyncOperation.MOVE && recorded != null) {
            val baseline = if (baseBytes != null && matchesBase(baseBytes, id, recorded)) {
                SyncLocalScanner.canonical(baseBytes, recorded.path, recorded.scope).bytes
            } else if (matchesBase(file.bytes, id, recorded)) {
                SyncLocalScanner.canonical(file.bytes, recorded.path, recorded.scope).bytes
            } else {
                val head = SyncConflictHead(client.prompt(id), binding.account.userID)
                if (head.id != id) throw SyncConflictPolicyError.InvalidHead
                if (head.rev != recorded.rev || head.scope != recorded.scope || head.path != recorded.path || head.hash != recorded.canonicalHash) {
                    // No write was sent; a changed server head still owns its location.
                    return install(head, null)
                }
                head.bytes
            }
            sent = SyncLocalScanner.canonical(baseline, destination, location.scope).bytes
        }
        val intent = SyncConflictIntent(id, operation, recorded?.rev ?: 0, location.scope, destination, sent, file.bytes, accessGeneration)
        val request = SyncPendingOperation(binding, intent, path, file, recorded)
        return finishMove(request, send(request), accessGeneration)
    }

    private suspend fun send(request: SyncPendingOperation): SyncPushResult {
        if (!SyncConflictPolicy.shouldAttempt(request.intent.fingerprint, request.recorded?.lastError)) return SyncPushResult.SKIPPED
        savePending(request)
        // Journal IO or the baseline GET can race a save. Send only the captured incarnation.
        val state = currentState()
        val local = live(request.intent.id, snapshot(state))
        if (held(request, local)) { retireHeld(request); return SyncPushResult.HELD }
        val current = mutations.read(request.libraryPath)
        val location = current?.let { SyncLocalScanner.location(it.path, binding, state.groups) }
        val canWrite = writable(request.intent.scope, state) && request.recorded?.let { writable(it.scope, state) } != false
        val sameLocation = current == null || location?.scope == request.intent.scope &&
            SyncPathValidator.validate(location.path, location.scope.pathScope).path == request.intent.path
        if (state.prompts[PromptIdentity.Assigned(request.intent.id)] != request.recorded || !same(current, request.file) ||
            request.intent.operation == SyncOperation.DELETE && local != null || !canWrite || !sameLocation) {
            clearPending()
            return SyncPushResult.REPLAN
        }
        try {
            val intent = request.intent
            val response = when (intent.operation) {
                SyncOperation.PUT -> client.putPrompt(intent.id, PutPromptRequest(intent.baseRev, wireScope(intent.scope), intent.path,
                    intent.sentBytes!!.decodeToString(throwOnInvalidSequence = true)))
                SyncOperation.DELETE -> client.deletePrompt(intent.id, intent.baseRev)
                SyncOperation.MOVE -> client.movePrompt(intent.id, MovePromptRequest(intent.baseRev, wireScope(intent.scope), intent.path))
            }
            if (response.rev <= intent.baseRev) throw SyncHTTPClientError.MalformedResponse
            if (intent.operation == SyncOperation.DELETE) return deleted(request)
            val head = SyncConflictHead(Prompt(intent.id.rawValue, response.rev, wireScope(intent.scope), intent.path,
                intent.sentBytes!!.decodeToString(throwOnInvalidSequence = true)), binding.account.userID)
            return acknowledge(head, request)
        } catch (error: SyncHTTPClientError) { return dispatch(error, request) }
    }

    private suspend fun dispatch(error: SyncHTTPClientError, request: SyncPendingOperation): SyncPushResult {
        val accessible = if (error == SyncHTTPClientError.Forbidden && request.intent.baseRev > 0) {
            try { client.prompt(request.intent.id) }
            catch (failure: SyncHTTPClientError) {
                if (failure == SyncHTTPClientError.Unauthorized ||
                    failure is SyncHTTPClientError.Transport && failure.error == HttpTransportError.Cancelled) throw failure
                null
            }
        } else null
        val state = currentState()
        val snapshot = snapshot(state)
        val local = live(request.intent.id, snapshot)
        if (held(request, local)) { retireHeld(request); return SyncPushResult.HELD }
        val occupied = snapshot.files.mapNotNull { file ->
            SyncLocalScanner.location(file.path, binding, state.groups)?.takeIf { it.scope == request.intent.scope }?.path
        }
        return when (val outcome = SyncConflictPolicy.resolve(error, request.intent, binding.account.userID, local,
            request.recorded, accessible, occupied) ?: throw error) {
            is SyncConflictOutcome.Acknowledged -> acknowledge(outcome.head, request)
            SyncConflictOutcome.DeleteSucceeded -> deleted(request)
            is SyncConflictOutcome.FileError -> fileError(outcome.error, request, state)
            is SyncConflictOutcome.ServerWins -> install(outcome.head, null).also { clearPending() }
            is SyncConflictOutcome.RemoteDeleted -> {
                rescueAndRemove(request.intent.id, state, snapshot, local)
                clearPending()
                SyncPushResult.REPLAN
            }
            is SyncConflictOutcome.Denied -> {
                if (outcome.restore != null) install(outcome.restore, outcome.error)
                else rescueAndRemove(request.intent.id, state, snapshot, local)
                clearPending()
                SyncPushResult.REFRESH_MEMBERSHIPS
            }
            is SyncConflictOutcome.ClashRename -> rename(outcome.path, request, state, local)
            is SyncConflictOutcome.AdoptExisting -> {
                val existing = (error as? SyncHTTPClientError.PathTaken)?.existing ?: throw SyncConflictPolicyError.InvalidResponse
                val decision = SyncAdoption.pathTaken(existing, request.intent, snapshot, state.groups)
                if (decision is SyncAdoptionDecision.Adopt) {
                    requireCommit(journal.apply(SyncAdoption.application(decision, state, snapshot, state.groups,
                        device, now(), freshID, mutations), permit))
                    clearPending()
                    SyncPushResult.ACKNOWLEDGED
                } else {
                    try { rename(SyncNaming.clash(request.intent.path, request.intent.scope.pathScope, occupied), request, state, local) }
                    catch (_: SyncNamingError.Exhausted) {
                        fileError(SyncPromptError(SyncIssueCode.PathClash, request.intent.fingerprint), request, state)
                    }
                }
            }
        }
    }

    private fun fileError(issue: SyncPromptError, request: SyncPendingOperation, state: SyncState): SyncPushResult {
        val key = PromptIdentity.Assigned(request.intent.id)
        val record = state.prompts[key] ?: request.recorded
        val next = state.copy(prompts = state.prompts + (key to SyncPromptState(record?.scope ?: request.intent.scope,
            record?.path ?: request.intent.path, record?.rev ?: 0, record?.canonicalHash, record?.origin, issue)))
        commit(state, next)
        clearPending()
        return SyncPushResult.SKIPPED
    }

    private fun acknowledge(head: SyncConflictHead, request: SyncPendingOperation): SyncPushResult {
        val state = currentState()
        val key = PromptIdentity.Assigned(head.id)
        val previous = state.prompts[key]
        val adopted = SyncPromptState(head.scope, head.path, head.rev, head.hash, head.origin)
        if (previous != request.recorded && previous != adopted) { clearPending(); return SyncPushResult.REPLAN }
        var next = setting(adopted, key, state)
        val edits = mutableListOf<SyncLibraryEdit>()
        val current = if (head.scope is SyncScopeKey.Group) mutations.read(request.libraryPath) else null
        if (current != null && same(current, request.file)) {
            val form = SyncLocalScanner.canonical(current.bytes, head.path, head.scope)
            next = next.applyGroupFavorite(form.favorite, key)
            if (!form.bytes.contentEquals(current.bytes)) edits.add(mutations.publication(form.bytes, request.libraryPath, current,
                SyncIdentityTransition(key, key), mode(head.scope, state)))
        }
        commit(state, next, edits)
        clearPending()
        return SyncPushResult.ACKNOWLEDGED
    }

    private suspend fun finishMove(request: SyncPendingOperation, result: SyncPushResult, accessGeneration: Long): SyncPushResult {
        if (request.intent.operation != SyncOperation.MOVE || result != SyncPushResult.ACKNOWLEDGED) return result
        val followup = pushFile(request.intent.id, request.libraryPath, accessGeneration, null)
        return if (followup == SyncPushResult.UNCHANGED) SyncPushResult.ACKNOWLEDGED else followup
    }

    private fun deleted(request: SyncPendingOperation): SyncPushResult {
        val state = currentState()
        val key = PromptIdentity.Assigned(request.intent.id)
        if (state.prompts[key] != request.recorded && state.prompts[key] != null) { clearPending(); return SyncPushResult.REPLAN }
        // Recreated bytes survive the acknowledgement and get the 410 policy on their next push.
        commit(state, setting(null, key, state))
        clearPending()
        return SyncPushResult.ACKNOWLEDGED
    }

    private fun install(head: SyncConflictHead, error: SyncPromptError?): SyncPushResult {
        val expected = states.load(binding)
        val state = expected ?: SyncState(binding)
        val snapshot = snapshot(state)
        val path = try { SyncLocalScanner.rooted(head.path, head.scope, state.groups) }
        catch (_: SyncError.InvalidScope) { policyHead = head; throw SyncReconciliationError.RequiresPolicy }
        val remote = SyncReconciliationRemote(head.id, head.scope, head.path, path, head.rev, head.bytes, head.hash, mode(head.scope, state))
        val local = live(head.id, snapshot)
        val pathKey = SyncNaming.pathKey(path)
        val targets = snapshot.files.filter { SyncNaming.pathKey(it.path) == pathKey }
        if (targets.size > 1 || targets.any { it.path != path || it.identityKey != head.id.rawValue || path in snapshot.heldPaths } ||
            targets.isEmpty() && mutations.read(path) != null) {
            policyHead = head
            throw SyncReconciliationError.RequiresPolicy
        }
        val installation = SyncReconciliationInstall(remote, local, targets.firstOrNull())
        val record = SyncPromptState(head.scope, head.path, head.rev, head.hash, head.origin, error)
        var next = setting(record, PromptIdentity.Assigned(head.id), state)
        val form = local?.let { runCatching { SyncLocalScanner.canonical(it.bytes, head.path, head.scope) }.getOrNull() }
        if (head.scope is SyncScopeKey.Group && form != null) next = next.applyGroupFavorite(form.favorite, PromptIdentity.Assigned(head.id))
        // Identity-neutral adoption equality cannot discard private comments/formatting on a conflict.
        val operation = if (local != null && form?.bytes?.contentEquals(head.bytes) != true) {
            SyncReconciliationOperation.Preserve(SyncReconciliationPreservation(head.id,
                SyncReconciliationPreservation.Reason.DIRTY_UPSERT, local, installation))
        } else SyncReconciliationOperation.Install(installation)
        val plan = SyncReconciliationPlan(SyncReconciliationPlan.Mode.NORMAL, expected, next, listOf(operation),
            snapshot.files.map { it.path }.toSet(), snapshot.files.map { it.identity }.toSet())
        val candidates = snapshot.files.mapNotNull { file ->
            if (file.path in snapshot.heldPaths) null
            else SyncLocalScanner.location(file.path, binding, state.groups)?.let { SyncConflictCopyCandidate(it.scope, file) }
        }
        val copies = SyncConflictPolicy.copies(plan, device, now(), freshID, candidates, mutations)
        requireCommit(journal.apply(SyncReconciler.application(plan, mutations, copies), permit))
        return SyncPushResult.REPLAN
    }

    private fun rescueAndRemove(id: ULID, state: SyncState, snapshot: SyncReconciliationSnapshot, local: SyncLibraryFile?) {
        var next = setting(null, PromptIdentity.Assigned(id), state)
        val edits = mutableListOf<SyncLibraryEdit>()
        if (local != null) {
            val scope = SyncLocalScanner.location(local.path, binding, state.groups)?.scope
            val folder = (scope as? SyncScopeKey.Group)?.let { state.groups[it.id]?.folder }
            val copy = SyncConflictPolicy.copy(local, SyncPromptOrigin.ConflictOf(id), binding.account.userID, folder,
                device, now(), allocate(snapshot, state), snapshot.files.map { it.path }, mutations = mutations)
            val bytes = copy.edit.bytes
            val copyID = bytes?.let { PromptCodec.parseFile(it, LibraryPath.filename(copy.edit.path)).frontMatter.id }
            if (copyID != null && copy.edit.heldIssue == null) next = next.copy(prompts = next.prompts +
                (PromptIdentity.Assigned(copyID) to SyncPromptState(SyncScopeKey.User(binding.account.userID), copy.edit.path, 0, origin = copy.origin)))
            edits.add(copy.edit)
            edits.add(mutations.trash(local))
        }
        commit(state, next, edits)
    }

    private fun rename(path: String, request: SyncPendingOperation, state: SyncState, local: SyncLibraryFile?): SyncPushResult {
        val location = local?.let { SyncLocalScanner.location(it.path, binding, state.groups) }
        if (local == null || location?.scope != request.intent.scope || SyncNaming.pathKey(location.path) != SyncNaming.pathKey(request.intent.path)) {
            clearPending()
            return SyncPushResult.REPLAN
        }
        val destination = SyncLocalScanner.rooted(path, request.intent.scope, state.groups)
        val key = PromptIdentity.Assigned(request.intent.id)
        val record = state.prompts[key]
        // Markers stay in the bytes; only private state projects their origin.
        val next = if (record?.rev == 0L) state.copy(prompts = state.prompts +
            (key to SyncPromptState(request.intent.scope, path, 0,
                origin = if (request.intent.scope is SyncScopeKey.User) record.origin else null))) else state
        val edit = mutations.publication(local.bytes, destination, null, SyncIdentityTransition(null, key))
        commit(state, next, listOf(edit, mutations.trash(local)))
        clearPending()
        return SyncPushResult.REPLAN
    }

    private fun currentState(): SyncState = states.load(binding) ?: SyncState(binding)

    private fun snapshot(state: SyncState): SyncReconciliationSnapshot {
        val files = mutations.listedFiles()
        if (files.isEmpty()) return SyncReconciliationSnapshot(binding, files)
        val owner = currentOwnership()
        val rescues = journal.heldRescues(binding.root)
        val held = files.filter { isHeld(it.identity, it.path, it.hash, state, owner, rescues) }.map { it.path }.toSet()
        return SyncReconciliationSnapshot(binding, files, heldPaths = held)
    }

    private fun currentOwnership(): SyncLibraryBinding? = ownership().also { owner ->
        if (owner != null && (owner.root != binding.root || owner.owner != binding.account)) throw SyncError.BindingMismatch
        owner?.validate()
    }

    private fun isHeld(identity: PromptIdentity, path: String, hash: SyncHash): Boolean {
        val owner = currentOwnership()
        return isHeld(identity, path, hash, currentState(), owner, journal.heldRescues(binding.root))
    }

    private fun isHeld(identity: PromptIdentity, path: String, hash: SyncHash, state: SyncState,
                       owner: SyncLibraryBinding?, rescues: List<SyncRetainedRescue>): Boolean {
        if (owner?.isHeld(identity, path, hash) == true) return true
        val location = SyncLocalScanner.location(path, binding, state.groups)
        if (location?.scope is SyncScopeKey.Group) {
            val folder = owner?.managedFolders?.entries?.firstOrNull { it.value.folder == path.split('/').getOrNull(1) }
            if (folder != null && (folder.key != location.scope.id || folder.value.owner != binding.account)) return true
        }
        return rescues.any { it.path == path || it.hash == hash }
    }

    private fun held(request: SyncPendingOperation, local: SyncLibraryFile?): Boolean = isHeld(PromptIdentity.Assigned(request.intent.id),
        local?.path ?: request.libraryPath, local?.hash ?: request.file?.hash ?: request.recorded?.canonicalHash ?: SyncHash.of(byteArrayOf()))

    private fun live(id: ULID, snapshot: SyncReconciliationSnapshot): SyncLibraryFile? {
        val files = snapshot.files.filter { it.identityKey == id.rawValue }
        if (files.size > 1) throw SyncReconciliationError.InvalidLocalSnapshot
        return files.firstOrNull()
    }

    private fun matchesBase(bytes: ByteArray, id: ULID, recorded: SyncPromptState): Boolean {
        val form = runCatching { SyncLocalScanner.canonical(bytes, recorded.path, recorded.scope) }.getOrNull() ?: return false
        return PromptCodec.parseFile(form.bytes, LibraryPath.filename(recorded.path)).frontMatter.id == id && SyncHash.of(form.bytes) == recorded.canonicalHash
    }

    private fun unchangedHead(head: SyncConflictHead, request: SyncPendingOperation): Boolean = request.recorded?.let {
        head.rev == it.rev && head.scope == it.scope && head.path == it.path && head.hash == it.canonicalHash
    } == true

    private fun setting(record: SyncPromptState?, key: PromptIdentity, state: SyncState): SyncState {
        val prompts = if (record == null) state.prompts - key else state.prompts + (key to record)
        return state.copy(prompts = prompts, favorites = state.favorites.filterKeys { prompts[it]?.scope is SyncScopeKey.Group })
    }

    private fun allocate(snapshot: SyncReconciliationSnapshot, state: SyncState): ULID = freshID().also { id ->
        if (snapshot.files.any { it.identityKey == id.rawValue } || PromptIdentity.Assigned(id) in state.prompts) throw SyncError.InvalidState
    }

    private fun commit(old: SyncState, next: SyncState, edits: List<SyncLibraryEdit> = emptyList()) {
        val expected = states.load(binding)
        if (expected != old && (expected != null || old != SyncState(binding))) {
            throw SyncPushError.ApplyRequired(SyncApplyOutcome.ReplanAsConflict(UUID.randomUUID()))
        }
        requireCommit(journal.apply(SyncApplyPlan(expected, next, edits), permit))
    }

    private fun requireCommit(result: SyncApplyOutcome) {
        if (result != SyncApplyOutcome.Committed) throw SyncPushError.ApplyRequired(result)
        committed()
    }

    private fun wireScope(scope: SyncScopeKey): PromptScope = when (scope) {
        is SyncScopeKey.User -> PromptScope.User
        is SyncScopeKey.Group -> PromptScope.Group(scope.id.rawValue)
    }

    private fun mode(scope: SyncScopeKey, state: SyncState): SyncFileMode =
        if (scope is SyncScopeKey.Group && state.groups[scope.id]?.role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL

    private fun writable(scope: SyncScopeKey, state: SyncState): Boolean = when (scope) {
        is SyncScopeKey.User -> scope.id == binding.account.userID
        is SyncScopeKey.Group -> state.groups[scope.id]?.role.let { it == Role.EDITOR || it == Role.OWNER }
    }

    private fun same(left: SyncLibraryFile?, right: SyncLibraryFile?): Boolean =
        if (left == null || right == null) left == null && right == null else left.path == right.path && left.stamp == right.stamp &&
            left.identityKey == right.identityKey && left.hash == right.hash && left.bytes.contentEquals(right.bytes)

    private fun begin(availability: SyncReconciliationSnapshot.Availability) {
        permit?.check()
        if (availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        lock.withLock {
            if (running) throw SyncPushError.Busy
            running = true
            policyHead = null
        }
    }

    private fun end() = lock.withLock { running = false }
    private fun savePending(request: SyncPendingOperation) = mutate { pending.save(request) }
    private fun clearPending() = mutate { pending.clear() }
    private fun retireHeld(request: SyncPendingOperation) = mutate { pending.retainHeld(request); pending.clear() }
    private fun <T> mutate(work: () -> T): T = if (permit != null) permit.mutate(work) else work()
}
