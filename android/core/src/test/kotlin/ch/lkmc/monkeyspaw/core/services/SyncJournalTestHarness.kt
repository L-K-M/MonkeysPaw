package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*

internal class SyncJournalHarness(
    val local: ServiceHarness = ServiceHarness(),
    val libraryOperations: SyncMutationFiles = SyncMutationFiles(local.prompts),
    val dataOperations: SyncMutationFiles = SyncMutationFiles(local.state),
    seed: Boolean = true,
) {
    val binding = SyncTestValues.binding()
    val mutations = SyncLibraryMutations(local.library, libraryOperations)
    val states = SyncStateStore(local.state, dataOperations)
    val accounts = SyncAccountStore(local.state, dataOperations)
    val expected = SyncState(binding, SyncTestValues.uuid, mapOf(SyncTestValues.userScope to "before"))
    var journal: SyncApplyJournal

    init {
        if (seed && states.snapshot.value == null) states.update(binding) { expected }
        journal = replacementJournal()
        clearCalls()
    }

    fun replacementJournal() = SyncApplyJournal(local.state, dataOperations, mutations, states, accounts)
    fun restart(): SyncJournalHarness = SyncJournalHarness(ServiceHarness(prompts = local.prompts, state = local.state),
        libraryOperations, dataOperations, seed = false)

    fun plan(edits: List<SyncLibraryEdit> = emptyList(), directories: List<SyncDirectoryEdit> = emptyList(),
             change: SyncBindingChange? = null, expectedState: SyncState? = expected,
             next: SyncState = expected.copy(cursors = mapOf(SyncTestValues.userScope to "after"))) =
        SyncApplyPlan(expectedState, next, edits, directories, change)

    fun put(body: String = "losing", path: String = "a.md", assigned: Boolean = true): SyncLibraryFile {
        local.prompts.put(if (assigned) source(body) else body, path)
        return mutations.read(path)!!
    }

    fun replacement(file: SyncLibraryFile = put(), body: String = "server", mode: SyncFileMode = SyncFileMode.NORMAL) =
        mutations.publication(source(body).encodeToByteArray(), file.path, file,
            SyncIdentityTransition(file.identity, SyncTestValues.personalID), mode)

    fun preparedCopy(): SyncApplyPlan {
        val file = put()
        val copy = mutations.rescue(file, "Conflicts/Copy.md", SyncTestValues.groupPrompt,
            SyncPromptOrigin.ConflictOf(SyncTestValues.personal))
        val edit = replacement(file)
        return plan(listOf(copy, edit), next = expected.copy(cursors = mapOf(SyncTestValues.userScope to "after"),
            prompts = mapOf(SyncTestValues.personalID to SyncPromptState(SyncTestValues.userScope, file.path, 2, edit.hash),
                SyncTestValues.groupID to SyncPromptState(SyncTestValues.userScope, copy.path, 0, null, copy.copyOrigin))))
    }

    fun preparedAdoption(): SyncApplyPlan {
        val file = put(assigned = false)
        local.history.snapshot("first".encodeToByteArray(), file.identity, local.clock.date)
        local.history.snapshot("second".encodeToByteArray(), file.identity, local.clock.date.plusSeconds(1))
        local.state.put("unknown", "history/${file.identityKey}/nested/opaque.bin")
        local.values.record(file.identity, mapOf("field" to "remembered"))
        local.usage.recordUse(file.identity)
        val edit = mutations.publication(source("losing").encodeToByteArray(), file.path, file,
            SyncIdentityTransition(file.identity, SyncTestValues.personalID), kind = SyncLibraryEdit.Kind.ADOPT)
        clearCalls()
        return plan(listOf(edit))
    }

    fun clearCalls() {
        libraryOperations.calls.clear()
        dataOperations.calls.clear()
        local.prompts.writes.clear()
        local.state.writes.clear()
    }

    companion object {
        fun source(body: String = "body", id: String = SyncTestValues.personal.rawValue) = "---\nid: '$id'\n---\n$body"
    }
}
