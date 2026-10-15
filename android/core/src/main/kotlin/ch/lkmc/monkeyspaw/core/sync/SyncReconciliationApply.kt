package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.*

/** Deferred adoption, relocation, visibility and folder lifecycle cannot acknowledge this pull. */
internal fun SyncReconciler.application(plan: SyncReconciliationPlan, mutations: SyncLibraryMutations,
                                      copies: Map<String, SyncReconciliationCopy> = emptyMap()): SyncApplyPlan {
    val preservations = mutableListOf<SyncReconciliationPreservation>()
    val installations = mutableListOf<SyncReconciliationInstall>()
    val removals = mutableMapOf<String, SyncLibraryFile>()
    for (operation in plan.operations) {
        when (operation) {
            is SyncReconciliationOperation.Install -> installations.add(operation.installation)
            is SyncReconciliationOperation.Remove -> removals[operation.file.path] = operation.file
            is SyncReconciliationOperation.Preserve -> {
                val preservation = operation.preservation
                preservations.add(preservation)
                if (preservation.installation != null) installations.add(preservation.installation)
                else removals[preservation.local.path] = preservation.local
            }
            is SyncReconciliationOperation.RestoreUpdate -> continue
            is SyncReconciliationOperation.Adoption, is SyncReconciliationOperation.PathClash,
            is SyncReconciliationOperation.LocalVisibility, is SyncReconciliationOperation.RemovedScope -> throw SyncReconciliationError.RequiresPolicy
        }
    }
    if (copies.keys != preservations.map { it.local.path }.toSet()) throw SyncReconciliationError.RequiresPolicy
    val prompts = plan.nextState.prompts.toMutableMap()
    val edits = mutableListOf<SyncLibraryEdit>()
    val destinations = plan.occupiedPaths.map(::folded).toMutableSet()
    val serverPaths = installations.map { folded(it.remote.libraryPath) }.toSet()
    if (serverPaths.size != installations.size) throw SyncReconciliationError.RequiresPolicy
    destinations.addAll(serverPaths)
    val identities = (plan.localIdentities + prompts.keys).toMutableSet()
    val reused = mutableSetOf<String>()
    for (preservation in preservations) {
        val source = preservation.local.path
        val copy = copies[source] ?: throw SyncReconciliationError.RequiresPolicy
        val edit = copy.edit
        edit.validate()
        val previousOrigin = runCatching { SyncMutationOrigin.origin(PromptCodec.parseFile(preservation.local.bytes,
            LibraryPath.filename(source))) }.getOrNull()
        val expectedOrigin = if (preservation.reason == SyncReconciliationPreservation.Reason.RESTORE_MISSING) SyncPromptOrigin.Rescued
            else previousOrigin ?: SyncPromptOrigin.ConflictOf(preservation.id)
        if (copy.origin != expectedOrigin) throw SyncReconciliationError.RequiresPolicy
        val bytes = edit.bytes ?: throw SyncReconciliationError.RequiresPolicy
        if (edit.heldIssue == null && SyncMutationOrigin.origin(PromptCodec.parseFile(bytes, LibraryPath.filename(edit.path))) != copy.origin) {
            throw SyncReconciliationError.RequiresPolicy
        }
        if (edit.kind == SyncLibraryEdit.Kind.RESCUE) {
            if (edit.retainedBytes?.contentEquals(preservation.local.bytes) != true || edit.retainedSourcePath != source ||
                !destinations.add(folded(edit.path))) throw SyncReconciliationError.RequiresPolicy
            if (edit.heldIssue == null) {
                val id = edit.copyID?.let { runCatching { SyncIdentifiers.ulid(it) }.getOrNull() } ?: throw SyncReconciliationError.RequiresPolicy
                if (!identities.add(PromptIdentity.Assigned(id))) throw SyncReconciliationError.RequiresPolicy
                prompts[PromptIdentity.Assigned(id)] = SyncPromptState(SyncScopeKey.User(plan.nextState.binding.account.userID),
                    edit.path, 0, origin = copy.origin)
            }
        } else if (edit.kind == SyncLibraryEdit.Kind.APPLY && edit.expected?.identity is PromptIdentity.Assigned) {
            val existing = edit.expected
            val identity = existing.identity
            val path = edit.path
            if (copy.origin !is SyncPromptOrigin.ConflictOf || path == source || path !in plan.occupiedPaths ||
                identity !in plan.localIdentities || folded(path) in serverPaths || !reused.add(folded(path)) ||
                !bytes.contentEquals(existing.bytes)) throw SyncReconciliationError.RequiresPolicy
            val expectedBytes = try {
                val document = PromptCodec.parseFile(preservation.local.bytes, LibraryPath.filename(source))
                SyncMutationOrigin.origin(document) // Invalid source markers require a held rescue.
                SyncMutationOrigin.copyBytes(document, (identity as PromptIdentity.Assigned).id,
                    copy.origin, LibraryPath.filename(path))
            } catch (_: Exception) { throw SyncReconciliationError.RequiresPolicy }
            if (!expectedBytes.contentEquals(existing.bytes)) throw SyncReconciliationError.RequiresPolicy
            val old = prompts[identity]
            val privateScope = SyncScopeKey.User(plan.nextState.binding.account.userID)
            if (old != null && old.scope != privateScope) throw SyncReconciliationError.RequiresPolicy
            // Preserve its acknowledged baseline: a renamed/edited copy still needs its private push.
            prompts[identity] = SyncPromptState(privateScope, old?.path ?: path, old?.rev ?: 0, old?.canonicalHash,
                copy.origin, old?.lastError)
        } else {
            throw SyncReconciliationError.RequiresPolicy
        }
        edits.add(edit) // Copies become durable before any source can retire.
    }
    for (installation in installations) {
        val remote = installation.remote
        val target = installation.target
        if (target != null && target.identity != PromptIdentity.Assigned(remote.id)) throw SyncReconciliationError.RequiresPolicy
        edits.add(mutations.publication(remote.bytes, remote.libraryPath, target,
            SyncIdentityTransition(target?.identity, PromptIdentity.Assigned(remote.id)), remote.mode,
            markerIssue = ingest(remote.bytes, LibraryPath.filename(remote.path), remote.scope).issue))
        val source = installation.source
        if (source != null && source.path != remote.libraryPath) removals[source.path] = source
    }
    val publications = edits.map { it.path }.toSet()
    for (path in removals.keys.sortedWith { left, right -> Utf8Order.compare(left.encodeToByteArray(), right.encodeToByteArray()) }) {
        if (path in publications) throw SyncReconciliationError.RequiresPolicy
        edits.add(mutations.trash(removals.getValue(path)))
    }
    if (edits.map { it.path }.toSet().size != edits.size) throw SyncReconciliationError.RequiresPolicy
    return SyncApplyPlan(plan.expectedState, plan.nextState.copy(prompts = prompts), edits)
}

internal fun SyncReconciler.apply(plan: SyncReconciliationPlan, mutations: SyncLibraryMutations, journal: SyncApplyJournal,
                                copies: Map<String, SyncReconciliationCopy> = emptyMap(), permit: SyncWorkPermit? = null): SyncApplyOutcome =
    journal.apply(application(plan, mutations, copies), permit)
