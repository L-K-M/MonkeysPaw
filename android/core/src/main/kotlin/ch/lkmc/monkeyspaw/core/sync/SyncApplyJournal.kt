package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.UUID
import java.util.concurrent.CancellationException
import kotlin.concurrent.withLock

/** One serialized journal per graph, recovered before ordinary library work is enabled. */
internal class SyncApplyJournal(
    private val files: StateStore,
    private val operations: SyncFileOperations,
    private val mutations: SyncLibraryMutations,
    private val states: SyncStateStore,
    private val accounts: SyncAccountStore? = null,
) {
    private class StateChanged : Exception("Sync state changed.", null, false, false)
    private val persistence = SyncPersistence(files, operations, journalPath, SyncApplyJson.codec)
    private val lock = mutations.journalLock

    init {
        lock.withLock {
            try {
                val record = loadRecord()
                if (record != null) mutations.resume(record.id, record.nextState)
                else settleEmptyJournal()
            } catch (error: Exception) {
                mutations.blockForRecovery()
                throw safe(error)
            }
        }
    }

    val pending: SyncApplyRecord? get() = persistence.snapshot.value

    fun apply(plan: SyncApplyPlan, permit: SyncWorkPermit? = null): SyncApplyOutcome {
        if (permit == null) return applyPlan(plan)
        permit.validate(plan.nextState.binding)
        return permit.mutate { applyPlan(plan) }
    }

    private fun applyPlan(plan: SyncApplyPlan): SyncApplyOutcome = lock.withLock {
        if (loadRecord() != null) throw SyncError.InvalidState
        if (!matchesBaseline(plan)) return@withLock SyncApplyOutcome.ReplanAsConflict(plan.id)
        mutations.begin(plan.id, plan.nextState)
        try {
            val record = prepare(plan)
            persistence.update { current ->
                if (current != null) throw SyncError.InvalidState
                record
            }
        } catch (error: Exception) {
            if (persistence.snapshot.error == null && persistence.snapshot.value == null) mutations.finish(plan.id)
            throw safe(error)
        }
        run()
    }

    /** No new names or IDs. Completion flags are hints; actual bytes/modes/durability are rechecked. */
    fun replay(permit: SyncWorkPermit? = null): SyncApplyOutcome =
        if (permit == null) replayPlan(null) else permit.mutate { replayPlan(permit.binding) }

    private fun replayPlan(binding: SyncLibraryIdentity?): SyncApplyOutcome = lock.withLock {
        val record = try {
            persistence.recover { record ->
                if (record != null && binding != null && record.nextState.binding != binding) throw SyncError.BindingMismatch
            }
        } catch (error: Exception) {
            mutations.blockForRecovery()
            throw safe(error)
        }
        if (record == null) {
            if (binding != null && mutations.pendingPermit?.nextState?.binding?.let { it != binding } == true) {
                throw SyncError.BindingMismatch
            }
            try { settleEmptyJournal() }
            catch (error: Exception) {
                mutations.blockForRecovery()
                throw safe(error)
            }
            return@withLock SyncApplyOutcome.Committed
        }
        mutations.resume(record.id, record.nextState)
        record.bindingChange?.let { change ->
            val accounts = accounts ?: throw SyncError.InvalidState
            accounts.recoverBinding(change.next.root) { actual ->
                if (actual != change.expected && actual != change.next) throw LibraryError.RecoveryRequired
            }
        }
        states.recover(record.nextState.binding)
        run()
    }

    /** Archive the old intent before replacement; partially migrated keyed data cannot be discarded. */
    fun replan(plan: SyncApplyPlan): SyncApplyOutcome = lock.withLock {
        val previous = loadRecord() ?: throw SyncError.InvalidState
        if (previous.id == plan.id || previous.nextState.binding != plan.nextState.binding) throw SyncError.InvalidState
        if (previous.steps.any { !mutations.canReplan(it.edit, it.migrations, it.completed) } ||
            previous.directorySteps.any { !mutations.canReplan(it) }) throw LibraryError.RecoveryRequired
        if (!matchesBaseline(plan)) return@withLock SyncApplyOutcome.ReplanAsConflict(plan.id)
        val replacement = prepare(plan)
        try {
            val archive = files.read(journalPath)
            if (archive.size > Limits.syncRecordMaxBytes ||
                SyncApplyJson.codec.decode(WireJson.parse(archive).objectValue()).id != previous.id) throw SyncError.InvalidState
            retain(archive, "sync/retained/${previous.id}-journal.json")
            persistence.update { current ->
                if (current?.id != previous.id) throw SyncError.InvalidState
                replacement
            }
            mutations.replacePermit(previous.id, replacement.id, replacement.nextState)
        } catch (error: Exception) { throw safe(error) }
        run()
    }

    private fun prepare(plan: SyncApplyPlan): SyncApplyRecord = SyncApplyRecord(plan,
        plan.edits.map { SyncApplyStep(it, mutations.prepareMigrations(it)) },
        plan.directories.map { SyncDirectoryStep(it, mutations.prepareMigrations(it)) }).also { it.validate() }

    private fun matchesBaseline(plan: SyncApplyPlan): Boolean {
        if (states.load(plan.nextState.binding) != plan.expectedState) return false
        plan.bindingChange?.let {
            val accounts = accounts ?: throw SyncError.InvalidState
            if (accounts.binding(it.next.root) != it.expected) return false
        }
        return true
    }

    private fun loadRecord(): SyncApplyRecord? = try { persistence.load() }
    catch (error: Exception) { mutations.blockForRecovery(); throw safe(error) }

    private fun run(): SyncApplyOutcome {
        var record = loadRecord() ?: throw LibraryError.RecoveryRequired
        mutations.begin(record.id, record.nextState)
        val binding = record.nextState.binding
        val state = states.load(binding)
        if (state != record.expectedState && state != record.nextState) return SyncApplyOutcome.ReplanAsConflict(record.id)
        var stateCommitted = false
        try {
            record.bindingChange?.let { change ->
                val actual = (accounts ?: throw SyncError.InvalidState).binding(change.next.root)
                if (actual != change.expected && actual != change.next) return SyncApplyOutcome.ReplanAsConflict(record.id)
            }
            if (state != record.nextState) {
                val result = runDirectories(record, SyncDirectoryEdit.Kind.RESERVE)
                record = result.first
                result.second?.let { return it }
            }
            val renamed = runDirectories(record, SyncDirectoryEdit.Kind.RENAME)
            record = renamed.first
            renamed.second?.let { return it }
            for (index in record.steps.indices) {
                val step = record.steps[index]
                retain(step.edit, binding)
                if (!step.started) {
                    record = record.progress(steps = record.steps.toMutableList().also { it[index] = step.progress(started = true) })
                    save(record)
                }
                val result = try {
                    mutations.apply(step.edit, if (step.started) SyncLibraryMutations.Attempt.REPLAY else SyncLibraryMutations.Attempt.FIRST)
                } catch (error: SyncFileOperationError) {
                    retainDisplaced(step.edit, error.displacedBytes, error.effect, error)
                    throw error
                }
                retainDisplaced(step.edit, result.displacedBytes, result.effect)
                if (result.outcome == SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT) {
                    return if (mutations.canReplan(step.edit, step.migrations, step.completed)) SyncApplyOutcome.ReplanAsConflict(step.edit.id)
                    else SyncApplyOutcome.RecoveryRequired(step.edit.id)
                }
                step.migrations.forEach { mutations.migrate(it, operations) }
                record = record.progress(steps = record.steps.toMutableList().also {
                    it[index] = step.progress(started = true, completed = true)
                })
                save(record)
            }
            // A noncooperating edit during another step must not become an acknowledged baseline.
            record.steps.forEach {
                if (mutations.verify(it.edit) == SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT) {
                    return SyncApplyOutcome.ReplanAsConflict(it.edit.id)
                }
            }
            val removed = runDirectories(record, SyncDirectoryEdit.Kind.REMOVE_EMPTY)
            record = removed.first
            removed.second?.let { return it }
            record.directorySteps.forEach {
                // Committed folder ownership remains valid if files arrive during uncertain journal removal.
                if (!(it.edit.kind == SyncDirectoryEdit.Kind.RESERVE && state == record.nextState && it.completed) &&
                    mutations.verify(it.edit) == SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT) {
                    return SyncApplyOutcome.ReplanAsConflict(it.edit.id)
                }
            }
            record.bindingChange?.let { change ->
                (accounts ?: throw SyncError.InvalidState).updateBinding(change.next.root) { actual ->
                    if (actual != change.expected && actual != change.next) throw StateChanged()
                    change.next
                }
            }
            states.update(binding) { actual ->
                if (actual != record.expectedState && actual != record.nextState &&
                    !(record.expectedState == null && actual == SyncState(binding))) throw StateChanged()
                record.nextState
            }
            stateCommitted = true
            mutations.stateCommitted(record.id)
            persistence.reset(null)
            mutations.finish(record.id)
            return SyncApplyOutcome.Committed
        } catch (_: LibraryError.KeyedStateConflict) {
            return SyncApplyOutcome.RecoveryRequired(record.id)
        } catch (_: StateChanged) {
            return SyncApplyOutcome.ReplanAsConflict(record.id)
        } catch (error: Exception) {
            if (stateCommitted) states.blockForRecovery(state)
            throw safe(error)
        }
    }

    private fun runDirectories(initial: SyncApplyRecord, kind: SyncDirectoryEdit.Kind): Pair<SyncApplyRecord, SyncApplyOutcome?> {
        var record = initial
        for (index in record.directorySteps.indices) {
            val step = record.directorySteps[index]
            if (step.edit.kind != kind) continue
            if (!step.started) {
                record = record.progress(directories = record.directorySteps.toMutableList().also { it[index] = step.progress(started = true) })
                save(record)
            }
            if (mutations.apply(step.edit) == SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT) {
                return record to SyncApplyOutcome.ReplanAsConflict(step.edit.id)
            }
            step.migrations.forEach { mutations.migrate(it, operations) }
            record = record.progress(directories = record.directorySteps.toMutableList().also {
                it[index] = step.progress(started = true, completed = true)
            })
            save(record)
        }
        return record to null
    }

    private fun save(record: SyncApplyRecord) = persistence.update { current ->
        if (current?.id != record.id) throw SyncError.InvalidState
        record
    }

    private fun settleEmptyJournal() {
        val permit = mutations.pendingPermit
        if (permit == null) {
            if (mutations.hasUnreadableJournal) {
                SyncDurability.flushParents(journalPath, operations)
                mutations.finishEmptyRecovery()
            }
            return
        }
        // Preparatory plans may leave state identical. Equality alone cannot prove file/ownership commit.
        if (permit.commit != SyncRecoveryGate.CommitEvidence.STATE_DURABLE) throw LibraryError.RecoveryRequired
        val previous = states.snapshot.value
        states.recover(permit.nextState.binding) { if (it != permit.nextState) throw LibraryError.RecoveryRequired }
        try { SyncDurability.flushParents(journalPath, operations) }
        catch (error: Exception) { states.blockForRecovery(previous); throw safe(error) }
        mutations.resume(permit.id, permit.nextState)
        mutations.finish(permit.id)
    }

    private fun retainDisplaced(edit: SyncLibraryEdit, bytes: ByteArray?, effect: SyncFileMutationEffect,
                                original: SyncFileOperationError? = null) {
        if (bytes == null || edit.retainedBytes?.contentEquals(bytes) == true) return
        try { retain(bytes, retentionPrefix(edit) + "-displaced.bin") }
        catch (_: SyncError.InvalidState) { throw SyncFileOperationError(SyncFileFailureCode.INVALID_STATE, effect, bytes) }
        catch (_: Exception) { throw original ?: SyncFileOperationError(SyncFileFailureCode.IO_FAILURE, effect, bytes) }
    }

    private fun retain(edit: SyncLibraryEdit, binding: SyncLibraryIdentity) {
        val bytes = edit.retainedBytes ?: return
        val prefix = retentionPrefix(edit)
        retain(bytes, "$prefix.bin")
        val metadata = SyncRetention(edit.retainedSourcePath, SyncHash.of(bytes), edit.copyID,
            if (edit.kind == SyncLibraryEdit.Kind.RESCUE) edit.heldIssue else null,
            binding.account.serverURL, binding.account.userID.rawValue, binding.root,
            if (edit.kind == SyncLibraryEdit.Kind.RESCUE) edit.path else null, edit.copyOrigin)
        val path = "$prefix.json"
        val encoded = SyncRetention.codec.encode(metadata)
        val current = SyncDurability.readIfPresent(path, files)
        if (current == null) retain(syncDocumentBytes(encoded), path)
        else {
            if (current.size > Limits.syncRecordMaxBytes) throw SyncError.InvalidState
            val old = try { WireJson.parse(current).objectValue() } catch (_: Exception) { throw SyncError.InvalidState }
            val previous = try { SyncRetention.codec.decode(old) } catch (_: Exception) { throw SyncError.InvalidState }
            if (!previous.canUpgradeTo(metadata)) throw SyncError.InvalidState
            val upgraded = syncDocumentBytes(syncMergeDocument(encoded, old))
            if (upgraded.size > Limits.syncRecordMaxBytes) throw SyncError.InvalidState
            if (!current.contentEquals(upgraded)) files.writePrivate(upgraded, path)
            SyncDurability.flushFileAndParents(path, operations)
        }
    }

    fun heldRescues(root: SyncLibraryRoot): List<SyncRetainedRescue> = lock.withLock {
        val result = mutableListOf<SyncRetainedRescue>()
        for (file in operations.listFiles()) {
            val path = file.relativePath
            if (!path.startsWith("sync/retained/") || !path.endsWith(".json")) continue
            val stem = path.removePrefix("sync/retained/").removeSuffix(".json")
            val id = try { SyncIdentifiers.uuid(stem) } catch (_: Exception) { continue }
            val data = files.read(path)
            if (data.size > Limits.syncRecordMaxBytes) throw SyncError.InvalidState
            val metadata = try { SyncRetention.codec.decode(WireJson.parse(data).objectValue()) }
                catch (error: SyncError) { throw error } catch (_: Exception) { throw SyncError.InvalidState }
            val issue = metadata.heldIssue ?: continue
            val libraryRoot = metadata.libraryRoot ?: throw SyncError.InvalidState
            val binding = SyncLibraryIdentity(SyncAccountIdentity(metadata.serverURL ?: throw SyncError.InvalidState,
                SyncIdentifiers.ulid(metadata.userID ?: throw SyncError.InvalidState)), libraryRoot)
            if (binding.root != root) continue
            val destination = metadata.destinationPath ?: throw SyncError.InvalidState
            val source = metadata.sourcePath ?: throw SyncError.InvalidState
            if (syncValidated { SyncPathValidator.validate(destination, SyncPathValidator.Scope.USER).path } != destination) {
                throw SyncError.InvalidState
            }
            StorePath.validate(source)
            if (SyncHash.of(files.read("sync/retained/$stem.bin")) != metadata.hash) throw SyncError.InvalidState
            result.add(SyncRetainedRescue(id, binding, destination, source, metadata.hash, issue,
                metadata.origin ?: SyncPromptOrigin.Rescued))
        }
        result.sortedWith { a, b -> Utf8Order.compare(a.path.encodeToByteArray(), b.path.encodeToByteArray()) }.syncListCopy()
    }

    private fun retain(bytes: ByteArray, path: String) {
        val current = SyncDurability.readIfPresent(path, files)
        if (current != null && !current.contentEquals(bytes)) throw SyncError.InvalidState
        if (current == null) files.writePrivate(bytes, path)
        SyncDurability.flushFileAndParents(path, operations)
    }

    private fun retentionPrefix(edit: SyncLibraryEdit): String = "sync/retained/${edit.id}"

    private companion object {
        const val journalPath = "sync/apply.json"
        fun safe(error: Exception): Exception = when (error) {
            is SyncError, is LibraryError, is SyncFileOperationError, is CancellationException -> error
            is StoreError -> SyncError.WriteFailed(error)
            else -> SyncError.InvalidState
        }
    }
}

private class SyncRetention(
    val sourcePath: String?, val hash: SyncHash, val copyID: String?, val heldIssue: SyncIssueCode?,
    val serverURL: String?, val userID: String?, val libraryRoot: SyncLibraryRoot?,
    val destinationPath: String?, val origin: SyncPromptOrigin?,
    val version: Int = Limits.syncApplyJournalVersion,
) {
    fun canUpgradeTo(next: SyncRetention): Boolean = version == next.version && sourcePath == next.sourcePath &&
        hash == next.hash && copyID == next.copyID && heldIssue == next.heldIssue &&
        (serverURL == null || serverURL == next.serverURL) && (userID == null || userID == next.userID) &&
        (libraryRoot == null || libraryRoot == next.libraryRoot) && (destinationPath == null || destinationPath == next.destinationPath) &&
        (origin == null || origin == next.origin)

    companion object {
        val codec = SyncDocumentCodec(Limits.syncApplyJournalVersion, { value ->
            SyncIdentifiers.version(WireObject(value).long("version"), Limits.syncApplyJournalVersion)
            SyncRetention(value.optional("sourcePath")?.stringValue(), SyncHash(WireObject(value).string("hash")),
                value.optional("copyID")?.stringValue()?.also(SyncIdentifiers::ulid),
                value.optional("heldIssue")?.stringValue()?.let(SyncIssueCode::parse),
                value.optional("serverURL")?.stringValue(), value.optional("userID")?.stringValue(),
                value.optional("libraryRoot")?.stringValue()?.let(::SyncLibraryRoot), value.optional("destinationPath")?.stringValue(),
                value.optional("origin")?.objectValue()?.let(SyncStateJson::origin))
        }, { value: SyncRetention ->
            syncObject("version" to wireLong(value.version.toLong()), "sourcePath" to wireNullable(value.sourcePath),
                "hash" to wireString(value.hash.rawValue), "copyID" to wireNullable(value.copyID),
                "heldIssue" to wireNullable(value.heldIssue?.rawValue), "serverURL" to wireNullable(value.serverURL),
                "userID" to wireNullable(value.userID), "libraryRoot" to wireNullable(value.libraryRoot?.path),
                "destinationPath" to wireNullable(value.destinationPath),
                "origin" to (value.origin?.let(SyncStateJson::origin) ?: WireValue.Null))
        })
    }
}
