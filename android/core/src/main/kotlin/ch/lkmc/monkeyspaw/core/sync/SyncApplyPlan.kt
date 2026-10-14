package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.*
import java.util.UUID

/** The planner selects every byte, destination and identity once, before durable preparation. */
internal class SyncApplyPlan(
    val expectedState: SyncState?,
    val nextState: SyncState,
    edits: List<SyncLibraryEdit>,
    directories: List<SyncDirectoryEdit> = emptyList(),
    val bindingChange: SyncBindingChange? = null,
    val id: UUID = UUID.randomUUID(),
) {
    val edits = edits.syncListCopy()
    val directories = directories.syncListCopy()
    override fun toString(): String = "<sync apply plan>"
}

/** Ownership and prior-account holds commit inside the file transaction's recovery gate. */
internal class SyncBindingChange(val expected: SyncLibraryBinding?, val next: SyncLibraryBinding) {
    override fun toString(): String = "<sync binding change>"
}

internal class SyncApplyStep(
    val edit: SyncLibraryEdit,
    migrations: List<SyncKeyedMigration>,
    val started: Boolean = false,
    val completed: Boolean = false,
) {
    val migrations = migrations.syncListCopy()
    fun progress(started: Boolean = this.started, completed: Boolean = this.completed) =
        SyncApplyStep(edit, migrations, started, completed)
    override fun toString(): String = "<sync apply step>"
}

internal class SyncApplyRecord(
    val id: UUID,
    val expectedState: SyncState?,
    val nextState: SyncState,
    steps: List<SyncApplyStep>,
    directorySteps: List<SyncDirectoryStep> = emptyList(),
    val bindingChange: SyncBindingChange? = null,
    val version: Int = Limits.syncApplyJournalVersion,
) {
    val steps = steps.syncListCopy()
    val directorySteps = directorySteps.syncListCopy()

    constructor(plan: SyncApplyPlan, steps: List<SyncApplyStep>, directories: List<SyncDirectoryStep>) :
        this(plan.id, plan.expectedState, plan.nextState, steps, directories, plan.bindingChange)

    fun progress(steps: List<SyncApplyStep> = this.steps, directories: List<SyncDirectoryStep> = directorySteps) =
        SyncApplyRecord(id, expectedState, nextState, steps, directories, bindingChange, version)

    fun validate() {
        SyncIdentifiers.version(version.toLong(), Limits.syncApplyJournalVersion)
        expectedState?.validate()
        nextState.validate()
        if (expectedState != null && expectedState.binding != nextState.binding ||
            steps.map { it.edit.path }.toSet().size != steps.size ||
            directorySteps.map { it.edit.source }.toSet().size != directorySteps.size) throw SyncError.InvalidState
        val ids = steps.map { it.edit.id } + directorySteps.map { it.edit.id }
        if (ids.toSet().size != ids.size) throw SyncError.InvalidState
        bindingChange?.let {
            it.expected?.validate()
            it.next.validate()
            if (it.next.root != nextState.binding.root || it.expected != null &&
                (it.expected.root != nextState.binding.root || it.expected.owner != nextState.binding.account)) {
                throw SyncError.BindingMismatch
            }
        }
        steps.forEach { step ->
            step.edit.validate()
            if (step.completed && !step.started || step.edit.kind == SyncLibraryEdit.Kind.REPAIR_DUPLICATE &&
                step.migrations.isNotEmpty()) throw SyncError.InvalidState
            step.migrations.forEach { migration ->
                migration.validate()
                if (step.edit.transition?.let { matches(migration, it) } != true) throw SyncError.InvalidState
            }
        }
        directorySteps.forEach { step ->
            step.edit.validate()
            if (step.completed && !step.started) throw SyncError.InvalidState
            val transitions = step.edit.identityTransitions()
            step.migrations.forEach { migration ->
                migration.validate()
                if (transitions.none { matches(migration, it) }) throw SyncError.InvalidState
            }
        }
    }

    private fun matches(migration: SyncKeyedMigration, transition: SyncIdentityTransition): Boolean {
        val source = transition.source ?: return false
        if (source == transition.destination) return false
        return when (val change = migration.change) {
            is SyncKeyedMigration.Change.Values -> change.source == source && change.destination == transition.destination
            is SyncKeyedMigration.Change.File -> {
                val move = change.move
                if (migration.store == SyncKeyedStoreKind.USAGE) {
                    move.source == "usage/$source" && move.destination == "usage/${transition.destination}"
                } else {
                    val from = "history/$source/"
                    val to = "history/${transition.destination}/"
                    move.source.startsWith(from) && move.destination.startsWith(to) &&
                        move.source.removePrefix(from) == move.destination.removePrefix(to)
                }
            }
        }
    }

    override fun toString(): String = "<sync apply journal>"
}

internal sealed interface SyncApplyOutcome {
    data object Committed : SyncApplyOutcome
    /** State conflicts identify the plan; file conflicts identify its stable edit. */
    data class ReplanAsConflict(val operationID: UUID) : SyncApplyOutcome
    /** Partly applied or externally changed keyed data must recover before replacing intent. */
    data class RecoveryRequired(val operationID: UUID) : SyncApplyOutcome
}
