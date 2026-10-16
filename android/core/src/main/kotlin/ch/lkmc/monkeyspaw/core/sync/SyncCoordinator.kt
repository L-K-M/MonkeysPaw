package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.time.Instant

internal class SyncPassResult(
    val counts: SyncCounts = SyncCounts(), details: List<SyncFileDetail> = emptyList(), val rerun: Boolean = false,
) {
    val details = details.syncListCopy()
    fun copy(counts: SyncCounts = this.counts, details: List<SyncFileDetail> = this.details, rerun: Boolean = this.rerun) =
        SyncPassResult(counts, details, rerun)
}

internal sealed class SyncCoordinatorError : Exception("Sync coordination failed.", null, false, true) {
    data object RecoveryRequired : SyncCoordinatorError()
    data object NoProgress : SyncCoordinatorError()
    class FileErrors(val details: List<SyncFileDetail>) : SyncCoordinatorError()
    final override fun toString(): String = "<sync coordinator error>"
}

/** One bounded pass. The engine serializes all callers on this graph, including recovery. */
internal class SyncCoordinator(
    val permit: SyncWorkPermit,
    client: SyncHTTPClient,
    files: StateStore,
    private val states: SyncStateStore,
    private val accounts: SyncAccountStore,
    private val mutations: SyncLibraryMutations,
    private val journal: SyncApplyJournal,
    private val pending: SyncPendingOperationStore,
    private val device: String,
    private val freshID: () -> ULID,
    private val date: () -> Instant,
    private val clock: MonotonicClock,
    private val preparationLimit: Int = Limits.syncPreparationLimit,
    private val committed: () -> Unit = {},
) {
    private val client = client.permitting(permit)
    private val collector = SyncPullCollector(this.client, files, permit.binding.account.userID, clock)
    private val push = SyncPushEngine(permit.binding, this.client, states, pending, mutations, journal,
        ::ownership, device, freshID, date, permit)
    private var accessGeneration = 0L
    private val available = SyncReconciliationSnapshot.Availability.AVAILABLE

    suspend fun run(progress: (SyncPassResult) -> Unit = {}, phase: (SyncPhase) -> Unit = {}): SyncPassResult {
        check()
        phase(SyncPhase.RECOVERING)
        recoverApply()
        currentState()
        val resumed = performingPush { push.resume(available, accessGeneration) }
        check()
        if (pending.load(permit.binding) != null) throw SyncCoordinatorError.RecoveryRequired
        var result = SyncPassResult(rerun = resumed == SyncPushResult.REFRESH_MEMBERSHIPS)
        val deadline = clock.nowNanos() + Limits.syncCollectionBudgetNanos
        var recollected = false
        var foldersPrepared = false
        var pull: SyncCollectedPull? = null
        try {
            repeat(preparationLimit) {
                check()
                if (pull == null) {
                    val state = currentState()
                    phase(if (state?.databaseID == null) SyncPhase.RESYNCING else SyncPhase.COLLECTING)
                    pull = collector.collect(PullRequest(state?.databaseID?.toString(),
                        state?.cursors.orEmpty().mapKeys { it.key.rawValue }), deadline)
                    foldersPrepared = false
                    check()
                }
                val collected = pull ?: throw SyncCoordinatorError.NoProgress
                phase(SyncPhase.RECONCILING)
                val old = currentState()
                val local = snapshot()
                val memberships = collected.scopes.values.mapNotNull {
                    val identity = it.identity as? ScopeIdentity.Group ?: return@mapNotNull null
                    GroupMembership(identity.groupID, identity.name, identity.role)
                }
                val inventory = inventory(local)
                if (!foldersPrepared) {
                    val folders = SyncGroupFolders.update(memberships, old, ownership(), inventory, mutations)
                    foldersPrepared = true
                    if (changed(folders)) { commit(folders); return@repeat }
                }
                val stale = SyncGroupFolders.stale(old, ownership(), inventory, date(), freshID, mutations)
                if (changed(stale)) { phase(SyncPhase.GROUP_FOLDERS); commit(stale); return@repeat }
                val plan = try { SyncReconciler.plan(collected, old, local) }
                catch (error: SyncReconciliationError) {
                    when (error) {
                        SyncReconciliationError.InvalidLocalSnapshot -> {
                            phase(SyncPhase.SCANNING)
                            commit(scan(old).preparation ?: throw error)
                            return@repeat
                        }
                        is SyncReconciliationError.SnapshotRequired -> {
                            if (recollected) throw SyncCoordinatorError.NoProgress
                            collected.discard()
                            pull = null
                            recollected = true
                            return@repeat
                        }
                        else -> throw error
                    }
                }
                if (plan.mode == SyncReconciliationPlan.Mode.RESTORE) phase(SyncPhase.RESYNCING)
                if (preparePolicy(plan, local, phase)) return@repeat
                phase(SyncPhase.GROUP_FOLDERS)
                if (collected.removed.isNotEmpty()) {
                    val current = old ?: SyncState(permit.binding)
                    val accessible = application(preparingAccessible(plan, current), local)
                    if (changed(accessible)) { commit(accessible); return@repeat }
                    val removal = SyncGroupFolders.removed(collected.removed, current, ownership(), inventory,
                        plan.nextState.prompts.keys, date(), freshID, mutations)
                    if (changed(removal)) { commit(removal); return@repeat }
                }
                commit(application(plan, local))
                result = result.copy(counts = result.counts.copy(pulled = plan.operations.size))
                progress(result)
                runCatching { collected.discard() }
                pull = null
                phase(SyncPhase.SCANNING)
                // A denied-head collision resets a scope. Never return push candidates until it is recollected.
                val finalScan = preparedScan(phase) ?: return summarize(result.copy(rerun = true))
                phase(SyncPhase.PUSHING)
                for (change in finalScan.changes) {
                    check()
                    val outcome = performingPush { push.push(change, available, accessGeneration) }
                    check()
                    result = result.copy(counts = result.counts.copy(
                        pushed = result.counts.pushed + if (outcome == SyncPushResult.ACKNOWLEDGED) 1 else 0),
                        rerun = result.rerun || outcome == SyncPushResult.REFRESH_MEMBERSHIPS || outcome == SyncPushResult.REPLAN)
                    val committed = currentState()
                    val details = errorDetails(committed)
                    result = result.copy(details = details, counts = result.counts.copy(fileErrors = details.size,
                        conflicts = committed?.prompts?.values?.count { it.origin != null } ?: 0))
                    progress(result)
                    if (outcome == SyncPushResult.REFRESH_MEMBERSHIPS) break
                }
                return summarize(result)
            }
            throw SyncCoordinatorError.NoProgress
        } finally {
            // Cleanup must also run on cancellation/fatal driver errors. Start sweeps any failed deletion next time.
            runCatching { pull?.discard() }
        }
    }

    suspend fun recoverJournal() {
        check()
        recoverApply()
        currentState()
        permit.mutate { pending.recover(permit.binding) }
        performingPush { push.resume(available, accessGeneration) }
        check()
        if (journal.pending != null || pending.load(permit.binding) != null) throw SyncCoordinatorError.RecoveryRequired
    }

    private fun recoverApply() {
        permit.check()
        // Replay also settles an absent journal with a live durability-uncertain permit.
        if (journal.pending != null || mutations.pendingPermit != null || mutations.hasUnreadableJournal) {
            requireCommit(journal.replay(permit))
            committed()
        }
    }

    private suspend fun check() { currentCoroutineContext().ensureActive(); permit.check() }
    private fun currentState(): SyncState? {
        permit.check()
        return states.load(permit.binding).also { accessGeneration = accessGeneration(it?.groups.orEmpty()) }
    }
    private fun ownership() = accounts.binding(permit.binding.root)
    private fun snapshot(): SyncReconciliationSnapshot {
        permit.check()
        val files = mutations.listedFiles()
        val owned = ownership()
        if (owned != null && owned.owner != permit.binding.account) throw SyncError.BindingMismatch
        val rescues = journal.heldRescues(permit.binding.root)
        val held = files.filter { owned?.isHeld(it.identity, it.path, it.hash) == true ||
            rescues.any { rescue -> rescue.path == it.path || rescue.hash == it.hash } }.map { it.path }.toSet()
        return SyncReconciliationSnapshot(permit.binding, files, heldPaths = held)
    }
    private fun inventory(local: SyncReconciliationSnapshot) =
        SyncGroupFolders.inventory(permit.binding, available, local.heldPaths, mutations)
    private fun scan(state: SyncState?): SyncLocalScan {
        permit.check()
        return SyncLocalScanner.scan(permit.binding, state, ownership(), journal.heldRescues(permit.binding.root),
            available, accessGeneration, freshID, mutations)
    }
    private fun summarize(result: SyncPassResult): SyncPassResult {
        val state = currentState()
        val final = scan(state)
        val details = (final.issues.map { SyncFileDetail(it.key, it.value.rawValue) } + errorDetails(state))
            .distinctBy { it.path }.sortedWith { a, b -> comparePaths(a.path, b.path) }
        val pending = final.changes.count { retryable(it, state) } +
            (final.preparation?.edits?.size ?: 0) + final.orphanFiles.size
        return result.copy(details = details, counts = result.counts.copy(fileErrors = details.size,
            held = final.snapshot.heldPaths.size, conflicts = state?.prompts?.values?.count { it.origin != null } ?: 0,
            pending = pending), rerun = result.rerun || final.preparation != null || pending > 0)
    }
    private fun errorDetails(state: SyncState?): List<SyncFileDetail> = state?.prompts?.values.orEmpty().mapNotNull { record ->
        record.lastError?.let { SyncFileDetail(SyncLocalScanner.rooted(record.path, record.scope, state!!.groups), it.code.rawValue) }
    }.sortedWith { a, b -> comparePaths(a.path, b.path) }

    private suspend fun performingPush(operation: suspend () -> SyncPushResult): SyncPushResult {
        try { return operation() }
        catch (_: SyncReconciliationError.RequiresPolicy) {
            repeat(preparationLimit) {
                check()
                val head = push.policyHead ?: throw SyncCoordinatorError.RecoveryRequired
                var state = currentState()
                val scope = head.scope
                if (scope is SyncScopeKey.Group && state?.groups?.containsKey(scope.id) != true) {
                    val me = client.me()
                    check()
                    if (me.user.id != permit.binding.account.userID.rawValue || me.groups.none { it.groupID == scope.id.rawValue }) {
                        throw SyncCoordinatorError.RecoveryRequired
                    }
                    val local = snapshot()
                    commit(SyncGroupFolders.update(me.groups, state, ownership(), inventory(local), mutations))
                    state = currentState()
                }
                state ?: throw SyncCoordinatorError.RecoveryRequired
                val local = snapshot()
                val remote = remote(head, state)
                val target = local.files.firstOrNull { SyncNaming.pathKey(it.path) == SyncNaming.pathKey(remote.libraryPath) &&
                    (it.path != remote.libraryPath || it.identityKey != head.id.rawValue || it.path in local.heldPaths) }
                if (target != null) relocate(target, emptyPlan(state, local), local)
                try { return push.resume(available, accessGeneration) }
                catch (_: SyncReconciliationError.RequiresPolicy) { /* The fresh head can race another local occupant. */ }
            }
            throw SyncCoordinatorError.NoProgress
        }
    }

    private fun retryable(change: SyncLocalChange, state: SyncState?): Boolean {
        val prompt = when (change) {
            is SyncLocalChange.Create -> change.prompt
            is SyncLocalChange.Update -> change.prompt
            is SyncLocalChange.Rename -> change.prompt
            is SyncLocalChange.Move -> change.prompt
            is SyncLocalChange.Delete -> {
                return SyncConflictPolicy.shouldAttempt(SyncInputFingerprint(byteArrayOf(), change.recorded.path,
                    change.recorded.scope, accessGeneration, SyncOperation.DELETE), state?.prompts?.get(change.identity)?.lastError)
            }
        }
        val record = state?.prompts?.get(prompt.identity)
        val operation = if (record != null && record.rev > 0 && record.scope != prompt.scope) SyncOperation.MOVE else SyncOperation.PUT
        return SyncConflictPolicy.shouldAttempt(SyncInputFingerprint(prompt.file.bytes, prompt.path, prompt.scope,
            accessGeneration, operation), record?.lastError)
    }

    private suspend fun preparedScan(phase: (SyncPhase) -> Unit): SyncLocalScan? {
        repeat(preparationLimit) {
            check()
            val state = currentState()
            val local = scan(state)
            if (local.orphanFiles.isNotEmpty()) {
                phase(SyncPhase.GROUP_FOLDERS)
                commit(SyncGroupFolders.stale(state, ownership(), inventory(local.snapshot), date(), freshID, mutations))
            } else if (local.preparation != null) commit(local.preparation)
            else {
                val denied = local.issues.keys.sortedWith(::comparePaths).firstOrNull { local.issues[it] == SyncIssueCode.Forbidden }
                if (denied == null || state == null) return local
                if (restoreDenied(denied, state, local.snapshot)) return null
            }
            phase(SyncPhase.SCANNING)
        }
        throw SyncCoordinatorError.NoProgress
    }

    /** Preserve fresh raw bytes after GET, never dispatch a known viewer write. */
    private suspend fun restoreDenied(path: String, state: SyncState, local: SyncReconciliationSnapshot): Boolean {
        val source = local.files.firstOrNull { it.path == path }
        val identity = source?.identity ?: state.prompts.entries.firstOrNull {
            runCatching { SyncLocalScanner.rooted(it.value.path, it.value.scope, state.groups) }.getOrNull() == path
        }?.key ?: throw SyncCoordinatorError.NoProgress
        val recorded = state.prompts[identity]
        var head: SyncConflictHead? = null
        if (identity is PromptIdentity.Assigned && recorded != null && recorded.rev > 0) {
            try {
                val accessible = SyncConflictHead(client.prompt(identity.id), permit.binding.account.userID)
                if (accessible.id == identity.id && accessible.scope == recorded.scope && accessible.path == recorded.path) head = accessible
            } catch (error: SyncHTTPClientError) {
                if (error != SyncHTTPClientError.NotFound && error != SyncHTTPClientError.Deleted && error != SyncHTTPClientError.Forbidden) throw error
            }
        }
        check()
        val fresh = snapshot()
        val matching = fresh.files.filter { it.identity == identity }
        val sources = matching.filter { it.path !in fresh.heldPaths }
        if (sources.size > 1) throw SyncReconciliationError.InvalidLocalSnapshot
        val file = sources.singleOrNull()
        if (file == null && matching.isNotEmpty()) return false
        val prompts = state.prompts.toMutableMap().also { it.remove(identity) }
        var installation: SyncReconciliationInstall? = null
        if (head != null) {
            val remote = remote(head, state)
            val targets = fresh.files.filter { SyncNaming.pathKey(it.path) == SyncNaming.pathKey(remote.libraryPath) }
            val occupant = targets.firstOrNull { it.path != remote.libraryPath || it.identityKey != head.id.rawValue || it.path in fresh.heldPaths }
            if (occupant != null) { relocate(occupant, emptyPlan(state, fresh), fresh); return true }
            installation = SyncReconciliationInstall(remote, file, targets.firstOrNull())
            prompts[identity] = SyncPromptState(head.scope, head.path, head.rev, head.hash, head.origin)
        }
        var next = state.copy(prompts = prompts, favorites = state.favorites.filterKeys { prompts[it]?.scope is SyncScopeKey.Group })
        if (identity is PromptIdentity.Assigned) {
            val operations = mutableListOf<SyncReconciliationOperation>()
            if (file != null) {
                val unchanged = installation?.let { file.path == it.remote.libraryPath &&
                    runCatching { SyncLocalScanner.canonical(file.bytes, it.remote.path, it.remote.scope).bytes }
                        .getOrNull()?.contentEquals(it.remote.bytes) == true } == true
                operations.add(if (unchanged) SyncReconciliationOperation.Install(installation!!)
                    else SyncReconciliationOperation.Preserve(SyncReconciliationPreservation(identity.id,
                        SyncReconciliationPreservation.Reason.DIRTY_UPSERT, file, installation)))
            } else if (installation != null) operations.add(SyncReconciliationOperation.Install(installation))
            commit(application(SyncReconciliationPlan(SyncReconciliationPlan.Mode.NORMAL, state, next, operations,
                fresh.files.map { it.path }.toSet(), fresh.files.map { it.identity }.toSet()), fresh))
        } else {
            val edits = if (file == null) emptyList() else {
                val copy = SyncConflictPolicy.copy(file, SyncPromptOrigin.Rescued, permit.binding.account.userID,
                    device = device, at = date(), freshID = freshID(), occupiedPaths = fresh.files.map { it.path }, mutations = mutations)
                copy.edit.copyID?.let { raw ->
                    val id = PromptIdentity.Assigned(SyncIdentifiers.ulid(raw))
                    if (id in next.prompts || fresh.files.any { it.identity == id }) throw SyncError.InvalidState
                    next = next.copy(prompts = next.prompts + (id to SyncPromptState(SyncScopeKey.User(permit.binding.account.userID),
                        copy.edit.path, 0, origin = copy.origin)))
                }
                listOf(copy.edit, mutations.trash(file))
            }
            commit(SyncApplyPlan(state, next, edits))
        }
        return false
    }

    private fun remote(head: SyncConflictHead, state: SyncState) = SyncReconciliationRemote(head.id, head.scope, head.path,
        SyncLocalScanner.rooted(head.path, head.scope, state.groups), head.rev, head.bytes, head.hash, SyncGroupFolders.mode(head.scope, state.groups))
    private fun emptyPlan(state: SyncState, local: SyncReconciliationSnapshot) = SyncReconciliationPlan(
        SyncReconciliationPlan.Mode.NORMAL, state, state, emptyList(), local.files.map { it.path }.toSet(), local.files.map { it.identity }.toSet())
    private fun changed(plan: SyncApplyPlan) = plan.expectedState != plan.nextState || plan.edits.isNotEmpty() ||
        plan.directories.isNotEmpty() || plan.bindingChange != null
    private fun commit(plan: SyncApplyPlan) {
        permit.check()
        requireCommit(journal.apply(plan, permit))
        committed()
        accessGeneration = accessGeneration(plan.nextState.groups)
    }
    private fun requireCommit(outcome: SyncApplyOutcome) {
        if (outcome != SyncApplyOutcome.Committed) throw SyncCoordinatorError.RecoveryRequired
    }
    private fun application(plan: SyncReconciliationPlan, local: SyncReconciliationSnapshot): SyncApplyPlan {
        val candidates = local.files.mapNotNull {
            if (it.path in local.heldPaths) return@mapNotNull null
            val location = SyncLocalScanner.location(it.path, permit.binding, plan.nextState.groups) ?: return@mapNotNull null
            SyncConflictCopyCandidate(location.scope, it)
        }
        return SyncReconciler.application(plan, mutations, SyncConflictPolicy.copies(plan, device, date(), freshID, candidates, mutations))
    }
    private fun preparingAccessible(plan: SyncReconciliationPlan, old: SyncState): SyncReconciliationPlan {
        val removed = plan.operations.filterIsInstance<SyncReconciliationOperation.RemovedScope>().map { it.scope }.toSet()
        val retained = old.prompts.filter { it.value.scope in removed && it.key !in plan.nextState.prompts }
        val next = old.copy(groups = old.groups + plan.nextState.groups, prompts = plan.nextState.prompts + retained,
            favorites = plan.nextState.favorites + old.favorites.filterKeys { it in retained })
        return SyncReconciliationPlan(plan.mode, plan.expectedState, next,
            plan.operations.filter { it !is SyncReconciliationOperation.RemovedScope }, plan.occupiedPaths, plan.localIdentities)
    }
    private fun preparePolicy(plan: SyncReconciliationPlan, local: SyncReconciliationSnapshot, phase: (SyncPhase) -> Unit): Boolean {
        for (operation in plan.operations) {
            when (operation) {
                is SyncReconciliationOperation.Adoption -> {
                    phase(SyncPhase.SCANNING)
                    val decision = SyncAdoption.match(operation.remote, local, plan.nextState.groups)
                    when (decision) {
                        is SyncAdoptionDecision.Adopt, is SyncAdoptionDecision.Conflict -> {
                            val occupant = if (decision is SyncAdoptionDecision.Adopt) decision.local else (decision as SyncAdoptionDecision.Conflict).local
                            val preparation = try { SyncAdoption.application(decision, plan.expectedState, local, plan.nextState.groups,
                                device, date(), freshID, mutations) }
                            catch (_: SyncReconciliationError.RequiresPolicy) { relocate(occupant, plan, local); return true }
                            commit(preparation)
                        }
                        is SyncAdoptionDecision.Clash -> relocate(decision.occupant, plan, local)
                        is SyncAdoptionDecision.Held -> relocate(local.files.firstOrNull { it.path == decision.path }
                            ?: throw SyncCoordinatorError.RecoveryRequired, plan, local)
                        else -> throw SyncReconciliationError.RequiresPolicy
                    }
                    return true
                }
                is SyncReconciliationOperation.PathClash -> { relocate(operation.occupant, plan, local); return true }
                is SyncReconciliationOperation.LocalVisibility -> {
                    val issue = SyncAdoption.localVisibility(operation.remote, plan.expectedState, permit.binding,
                        plan.nextState.groups, accessGeneration)
                    if (changed(issue)) commit(issue)
                    throw SyncCoordinatorError.FileErrors(errorDetails(currentState()))
                }
                else -> Unit
            }
        }
        return false
    }
    private fun relocate(file: SyncLibraryFile, plan: SyncReconciliationPlan, local: SyncReconciliationSnapshot) {
        val location = SyncLocalScanner.location(file.path, permit.binding, plan.nextState.groups)
        var next = plan.expectedState ?: SyncState(permit.binding, groups = plan.nextState.groups)
        if (file.path in local.heldPaths || !LibraryPath.isPrompt(file.path) || SyncLocalScanner.contentIssue(file) != null ||
            location == null || SyncGroupFolders.mode(location.scope, plan.nextState.groups) == SyncFileMode.READ_ONLY) {
            commit(SyncGroupFolders.rescueOccupant(file, plan.expectedState, ownership(), inventory(local), date(), freshID, mutations))
            return
        }
        val occupied = local.files.mapNotNull {
            SyncLocalScanner.location(it.path, permit.binding, plan.nextState.groups)?.takeIf { it.scope == location.scope }?.path
        }
        val destination = try { SyncNaming.clash(location.path, location.scope.pathScope, occupied) }
        catch (_: SyncNamingError.Exhausted) {
            val record = next.prompts[file.identity]
            val issue = SyncPromptError(SyncIssueCode.PathClash, SyncInputFingerprint(file.bytes, location.path,
                location.scope, accessGeneration, SyncOperation.PUT))
            next = next.copy(prompts = next.prompts + (file.identity to SyncPromptState(record?.scope ?: location.scope,
                record?.path ?: location.path, record?.rev ?: 0, record?.canonicalHash, record?.origin, issue)))
            val diagnostics = SyncApplyPlan(plan.expectedState, next, emptyList())
            if (changed(diagnostics)) commit(diagnostics)
            throw SyncCoordinatorError.FileErrors(errorDetails(next))
        }
        val rooted = SyncLocalScanner.rooted(destination, location.scope, plan.nextState.groups)
        val target = PromptIdentity.at(rooted, PromptCodec.parseFile(file.bytes, LibraryPath.filename(file.path)).frontMatter.id)
        next = SyncLocalScanner.migrating(next, file.identity, target)
        val publication = mutations.publication(file.bytes, rooted, null, SyncIdentityTransition(file.identity, target),
            SyncFileMode.NORMAL, SyncLibraryEdit.Kind.RELOCATE, adoptingSource = file)
        commit(SyncApplyPlan(plan.expectedState, next, listOf(publication, mutations.trash(file))))
    }

    companion object {
        /** Stable across restarts/reauthentication. Only authoritative access changes the fingerprint. */
        internal fun accessGeneration(groups: Map<ULID, SyncGroupState>): Long = if (groups.isEmpty()) 0 else
            SyncHash.of(groups.entries.sortedBy { it.key.rawValue }.joinToString("\n") { it.key.rawValue + ":" + it.value.role.wireValue }
                .encodeToByteArray()).rawValue.take(15).toLong(16)
    }
}

internal class SyncPermittedTransport(private val transport: HttpTransport, private val permit: SyncWorkPermit) : HttpTransport {
    override suspend fun send(request: HttpRequest): HttpResponse {
        currentCoroutineContext().ensureActive()
        permit.check()
        try { return transport.send(request).also { currentCoroutineContext().ensureActive(); permit.check() } }
        catch (error: Throwable) { currentCoroutineContext().ensureActive(); permit.check(); throw error }
    }
}
