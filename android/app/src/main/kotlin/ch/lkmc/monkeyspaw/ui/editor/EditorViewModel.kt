package ch.lkmc.monkeyspaw.ui.editor

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.Clock
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.IoDispatcher
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.ZoneId
import javax.inject.Inject

@HiltViewModel
internal class EditorViewModel @Inject constructor(
    private val repository: LibraryRepository,
    @IoDispatcher private val worker: CoroutineDispatcher,
    private val clock: Clock,
) : ViewModel() {
    private enum class LoadPurpose { REPLACE, RECONCILE, RELOCATED }
    private enum class DraftAcceptance { REPLACE, KEEP_NEWER }
    private data class Baseline(val entry: LibraryEntry, val source: String?,
        val readOnlyReason: SourceReadOnlyReason?, val projection: EditorDocumentState)
    private data class Request(val decision: EditorPendingDecision, val session: Long)
    private data class Observation(val load: PromptLoadResult, val projection: EditorDocumentState?)
    private data class CommandResult(val result: EditResult, val projection: EditorDocumentState?)

    private val mutableState = MutableStateFlow(EditorUiState())
    val state = mutableState.asStateFlow()
    // Set by activity composition, outside the view. All selection changes pass this guard first.
    var onSelectionChanged: ((LibrarySelection?) -> Unit)? = null
    @Volatile private var active = true
    @Volatile private var session = 0L
    private var revision = 0L
    private var nextDecision = 0L
    private var loadGeneration = 0L
    private var historyGeneration = 0L
    private var baseline: Baseline? = null
    private var pending: Request? = null
    private val requests = ArrayDeque<Request>()
    private var savingDecision: Long? = null
    private var runningCommand: EditorAction? = null
    private var validationJob: Job? = null
    private var loadJob: Job? = null
    private var historyRequested = false

    init {
        viewModelScope.launch {
            repository.state.collect { library ->
                if (library.refreshing || library.snapshot.version == 0L || state.value.writing ||
                    state.value.status == EditorStatus.LOADING || state.value.isNew) return@collect
                val path = state.value.relativePath ?: return@collect
                val stamp = baseline?.entry?.stamp ?: return@collect
                val current = library.snapshot.prompts.firstOrNull { it.entry.relativePath == path }?.entry
                if (current?.stamp != stamp) refresh()
            }
        }
    }

    fun snapshot(): EditorSnapshot? {
        val current = state.value
        return EditorSnapshot(session, revision, current.relativePath ?: return null,
            current.source ?: return null, current.stamp, current.selection?.identity, current.isNew)
    }

    fun open(selection: LibrarySelection) = request(EditorAction.Open(selection))
    fun createDraft(path: String = "Untitled.md") = request(EditorAction.New(path))
    fun close() = request(EditorAction.Close)
    fun reload() = request(EditorAction.Reload)
    fun rename(filename: String) = request(EditorAction.Rename(filename))
    fun move(folder: String) = request(EditorAction.Move(folder))
    fun delete() = request(EditorAction.Delete)
    fun restore(revision: HistoryRevision) = request(EditorAction.Restore(revision))

    fun edit(source: String) {
        if (!active || !state.value.canEdit || state.value.source == source) return
        revision++
        mutableState.value = state.value.copy(source = source,
            dirty = state.value.isNew || source != baseline?.source, validating = true,
            failure = null, status = if (state.value.writing) state.value.status else EditorStatus.READY)
        validate()
    }

    fun setNewPath(path: String) {
        if (!active || !state.value.isNew || state.value.writing || state.value.relativePath == path) return
        revision++
        mutableState.value = state.value.copy(relativePath = path, dirty = true, failure = null, validating = true)
        validate()
    }

    fun setTab(tab: EditorTab) {
        if (!active) return
        mutableState.value = state.value.copy(tab = tab)
        if (tab == EditorTab.HISTORY) loadHistory()
    }

    private fun validate() {
        val captured = snapshot() ?: return
        validationJob?.cancel()
        validationJob = viewModelScope.launch {
            val projection = withContext(worker) {
                project(PromptCodec.parse(captured.source, captured.relativePath.substringAfterLast('/')))
            }
            if (!current(captured) || captured.revision != revision) return@launch
            applyProjection(projection)
        }
    }

    fun save() {
        if (state.value.canSave) startSave(state.value.stamp)
    }

    private fun startSave(stamp: FileStamp?) {
        if (!active || !state.value.canEdit || state.value.writing || state.value.status == EditorStatus.LOADING) return
        val captured = snapshot() ?: return
        loadGeneration++
        loadJob?.cancel()
        mutableState.value = state.value.copy(status = EditorStatus.SAVING, failure = null)
        viewModelScope.launch {
            val completed = command(captured) { editing ->
                if (captured.isNew) editing.create(captured.source, captured.relativePath)
                else editing.save(captured.source, captured.relativePath, stamp)
            }
            if (!current(captured)) return@launch
            mutableState.value = state.value.copy(status = EditorStatus.READY)
            if (completed.result is EditResult.Saved) {
                val unchanged = state.value.source == captured.source && state.value.relativePath == captured.relativePath
                acceptCommit(completed, if (unchanged) DraftAcceptance.REPLACE else DraftAcceptance.KEEP_NEWER)
                if (savingDecision == pending?.decision?.id && !state.value.dirty) finishDecision()
            } else applyFailure(completed.result)
            savingDecision = null
            drain()
        }
    }

    fun resolveDecision(id: Long, decision: EditorDecision) {
        if (!active || state.value.writing || pending?.decision?.id != id) return
        when (decision) {
            EditorDecision.SAVE -> {
                if (state.value.conflict != null) return
                savingDecision = id
                save()
            }
            EditorDecision.DISCARD -> {
                baseline?.let { acceptBaseline(it) }
                mutableState.value = state.value.copy(dirty = false, conflict = null, failure = null)
                finishDecision()
            }
            EditorDecision.CANCEL -> {
                pending = null
                savingDecision = null
                mutableState.value = state.value.copy(pendingDecision = null)
                drain()
            }
        }
    }

    fun resolveConflict(choice: EditorConflictChoice) {
        val conflict = state.value.conflict ?: return
        if (!active || state.value.writing) return
        if (choice == EditorConflictChoice.CANCEL) {
            loadGeneration++
            loadJob?.cancel()
            mutableState.value = state.value.copy(conflict = conflict.copy(loading = false,
                presentation = EditorConflictPresentation.BANNER))
            return
        }
        if (conflict.loading) return
        when (choice) {
            EditorConflictChoice.KEEP_MINE -> {
                if (conflict.readOnlyReason != null || conflict.failure != null) return
                savingDecision = pending?.decision?.id
                startSave(conflict.stamp)
            }
            EditorConflictChoice.TAKE_THEIRS -> if (!conflict.deleted) load(LoadPurpose.REPLACE)
            EditorConflictChoice.DISCARD -> if (conflict.deleted) {
                reset()
                finishDecision()
            }
            EditorConflictChoice.REVIEW -> {
                mutableState.value = state.value.copy(conflict = conflict.copy(presentation = EditorConflictPresentation.DIALOG))
                refresh()
            }
            EditorConflictChoice.CANCEL -> Unit
        }
    }

    private fun request(action: EditorAction) {
        if (!active) return
        if (action is EditorAction.Open && action.selection == state.value.selection) return
        if (action == runningCommand) return
        if (pending?.let { it.session == session && it.decision.action == action } == true ||
            requests.any { it.session == session && it.decision.action == action }) return
        requests.addLast(Request(EditorPendingDecision(++nextDecision, action), session))
        drain()
    }

    private fun drain() {
        while (active && !state.value.writing && pending == null && requests.isNotEmpty()) {
            val next = requests.removeFirst()
            val action = next.decision.action
            // File commands remain attached to the session requested, even behind queued navigation.
            if (isCommand(action) && next.session != session) continue
            if (state.value.dirty) {
                pending = next
                mutableState.value = state.value.copy(pendingDecision = next.decision)
                break
            }
            perform(action)
        }
        mutableState.value = state.value.copy(queuedActions = requests.map { it.decision.action })
    }

    private fun finishDecision() {
        val request = pending
        pending = null
        savingDecision = null
        mutableState.value = state.value.copy(pendingDecision = null)
        if (request != null && (!isCommand(request.decision.action) || request.session == session)) {
            perform(request.decision.action)
        }
        drain()
    }

    private fun perform(action: EditorAction) {
        when (action) {
            is EditorAction.Open -> {
                reset()
                mutableState.value = state.value.copy(relativePath = action.selection.relativePath,
                    selection = action.selection, status = EditorStatus.LOADING)
                onSelectionChanged?.invoke(action.selection)
                load(LoadPurpose.REPLACE)
            }
            is EditorAction.New -> {
                reset()
                mutableState.value = state.value.copy(relativePath = action.path, source = "",
                    isNew = true, dirty = true, status = EditorStatus.READY, validating = true)
                onSelectionChanged?.invoke(null)
                validate()
            }
            EditorAction.Close -> reset()
            EditorAction.Reload -> if (state.value.isNew) {
                mutableState.value = state.value.copy(source = "", dirty = true, validating = true)
                revision++
                validate()
            } else load(LoadPurpose.REPLACE)
            else -> startCommand(action)
        }
    }

    private fun startCommand(action: EditorAction) {
        if (!state.value.canCommand) {
            mutableState.value = state.value.copy(failure = if (state.value.readOnlyReason != null) EditorFailure.READ_ONLY else EditorFailure.DATA)
            return
        }
        val captured = snapshot() ?: return
        val stamp = captured.stamp ?: return
        loadGeneration++
        loadJob?.cancel()
        historyGeneration++
        runningCommand = action
        mutableState.value = state.value.copy(status = EditorStatus.COMMAND, failure = null,
            history = state.value.history.copy(loading = false))
        viewModelScope.launch {
            val completed = command(captured) { editing ->
                when (action) {
                    is EditorAction.Rename -> editing.rename(captured.relativePath, action.filename, stamp)
                    is EditorAction.Move -> editing.move(captured.relativePath, action.folder, stamp)
                    EditorAction.Delete -> editing.delete(captured.relativePath, stamp)
                    is EditorAction.Restore -> editing.restore(action.revision, captured.relativePath, stamp)
                    else -> error("Not a file command.")
                }
            }
            if (!current(captured)) return@launch
            runningCommand = null
            mutableState.value = state.value.copy(status = EditorStatus.READY)
            when (val outcome = completed.result) {
                is EditResult.Saved -> {
                    if (action is EditorAction.Restore) historyRequested = true
                    acceptCommit(completed, DraftAcceptance.REPLACE)
                }
                EditResult.Deleted -> { onSelectionChanged?.invoke(null); reset() }
                is EditResult.Relocated -> {
                    // The move committed. Never reuse its source stamp or recreate the vacated path.
                    baseline = Baseline(outcome.baseline, captured.source, null, projectFromState())
                    mutableState.value = state.value.copy(relativePath = outcome.baseline.relativePath,
                        selection = selection(outcome.baseline), stamp = null)
                    onSelectionChanged?.invoke(selection(outcome.baseline))
                    applyObservation(Observation(outcome.current, completed.projection), LoadPurpose.RELOCATED)
                }
                else -> applyFailure(outcome)
            }
            drain()
        }
    }

    private suspend fun command(captured: EditorSnapshot, work: (EditingService) -> EditResult): CommandResult = try {
        repository.withLibrary { _, editing ->
            if (!current(captured)) return@withLibrary CommandResult(EditResult.Failed(LibraryError.OperationFailed), null)
            val result = work(editing)
            val document = when (result) {
                is EditResult.Saved -> result.commit.entry.document
                is EditResult.Relocated -> (result.current as? PromptLoadResult.Loaded)?.prompt?.entry?.document
                else -> null
            }
            CommandResult(result, document?.let(::project))
        }
    } catch (error: Exception) {
        if (error is CancellationException) throw error
        CommandResult(EditResult.Failed(error), null)
    }

    private fun acceptCommit(completed: CommandResult, acceptance: DraftAcceptance) {
        val saved = (completed.result as EditResult.Saved).commit
        val entry = saved.entry
        val loaded = Baseline(entry, entry.document.source, null, checkNotNull(completed.projection))
        val identityChanged = state.value.selection != selection(entry)
        baseline = loaded
        if (acceptance == DraftAcceptance.REPLACE) acceptBaseline(loaded)
        else mutableState.value = state.value.copy(selection = selection(entry), stamp = entry.stamp,
            isNew = false, conflict = null, dirty = state.value.source != loaded.source)
        mutableState.value = state.value.copy(historyMaintenanceFailed = saved.historyMaintenanceFailed)
        onSelectionChanged?.invoke(selection(entry))
        if (identityChanged) {
            historyGeneration++
            mutableState.value = state.value.copy(history = EditorHistoryState())
        }
        if (historyRequested) loadHistory()
        refresh()
    }

    private fun applyFailure(result: EditResult) {
        when (result) {
            is EditResult.Conflict -> {
                mutableState.value = state.value.copy(conflict = EditorConflict(false, result.currentStamp, loading = true))
                load(LoadPurpose.RECONCILE)
            }
            EditResult.Missing -> mutableState.value = state.value.copy(conflict = EditorConflict(deleted = true))
            EditResult.DestinationOccupied -> mutableState.value = state.value.copy(failure = EditorFailure.OCCUPIED)
            is EditResult.Invalid -> mutableState.value = state.value.copy(failure = EditorFailure.INVALID, issues = result.issues)
            is EditResult.ReadOnly -> mutableState.value = state.value.copy(failure = EditorFailure.READ_ONLY)
            is EditResult.ForensicRestoreBlocked -> mutableState.value = state.value.copy(failure = EditorFailure.FORENSIC)
            is EditResult.Failed -> mutableState.value = state.value.copy(failure = failure(result.error))
            else -> Unit
        }
    }

    /** Foreground/index reconciliation preserves a draft typed after this read was requested. */
    fun refresh() {
        if (!active || !state.value.isOpen || state.value.isNew || state.value.writing || state.value.status == EditorStatus.LOADING) return
        load(LoadPurpose.RECONCILE)
    }

    private fun load(purpose: LoadPurpose) {
        val path = state.value.relativePath ?: return
        val epoch = session
        val token = ++loadGeneration
        loadJob?.cancel()
        if (purpose == LoadPurpose.REPLACE) mutableState.value = state.value.copy(status = EditorStatus.LOADING, failure = null)
        loadJob = viewModelScope.launch {
            val observed = try {
                repository.withLibrary { _, editing ->
                    val loaded = editing.load(path)
                    Observation(loaded, (loaded as? PromptLoadResult.Loaded)?.prompt?.entry?.document?.let(::project))
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                Observation(PromptLoadResult.Failed(error), null)
            }
            if (!active || epoch != session || token != loadGeneration) return@launch
            if (purpose == LoadPurpose.REPLACE) mutableState.value = state.value.copy(status = EditorStatus.READY)
            applyObservation(observed, purpose)
            drain()
        }
    }

    private fun applyObservation(observed: Observation, purpose: LoadPurpose) {
        when (val load = observed.load) {
            is PromptLoadResult.Loaded -> {
                val loaded = load.prompt
                if (purpose == LoadPurpose.REPLACE || purpose == LoadPurpose.RECONCILE && !state.value.dirty && state.value.conflict == null) {
                    // Own-commit reconciliation must not erase a committed maintenance warning.
                    if (purpose != LoadPurpose.REPLACE && loaded.entry.stamp == state.value.stamp) return
                    val previous = state.value.selection
                    acceptBaseline(Baseline(loaded.entry, loaded.source, loaded.readOnlyReason, checkNotNull(observed.projection)))
                    if (previous != state.value.selection) onSelectionChanged?.invoke(state.value.selection)
                    if (pending != null) finishDecision()
                } else if (purpose == LoadPurpose.RELOCATED || loaded.entry.stamp != state.value.stamp || state.value.conflict != null) {
                    mutableState.value = state.value.copy(conflict = EditorConflict(false, loaded.entry.stamp,
                        loaded.source, loaded.readOnlyReason))
                }
            }
            PromptLoadResult.Missing -> if (state.value.dirty || state.value.conflict != null || purpose == LoadPurpose.RELOCATED) {
                mutableState.value = state.value.copy(conflict = EditorConflict(deleted = true))
            } else { reset(); if (pending != null) finishDecision() }
            is PromptLoadResult.Failed -> mutableState.value = state.value.copy(failure = failure(load.error),
                conflict = state.value.conflict?.copy(loading = false, failure = failure(load.error)))
        }
    }

    fun loadHistory() {
        if (!active) return
        historyRequested = true
        val selection = state.value.selection ?: return
        if (state.value.writing) return
        val epoch = session
        val token = ++historyGeneration
        mutableState.value = state.value.copy(history = state.value.history.copy(loading = true, failure = null))
        viewModelScope.launch {
            try {
                val revisions = repository.withLibrary { _, editing ->
                    editing.history(selection.identity, selection.relativePath.substringAfterLast('/')).map { snapshot ->
                        val document = snapshot.document
                        val unavailable = document.issues.any { it.code == PromptIssueCode.INVALID_UTF8 || it.code == PromptIssueCode.SOURCE_TOO_LARGE }
                        EditorRevision(snapshot.revision, snapshot.sourceBytes.size,
                            if (unavailable) null else document.source, document.canRender)
                    }
                }
                if (!active || epoch != session || token != historyGeneration || state.value.selection != selection) return@launch
                mutableState.value = state.value.copy(history = EditorHistoryState(revisions,
                    state.value.history.selected?.takeIf { selected -> revisions.any { it.revision == selected } }))
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (!active || epoch != session || token != historyGeneration) return@launch
                mutableState.value = state.value.copy(history = state.value.history.copy(loading = false, failure = failure(error)))
            }
        }
    }

    fun selectRevision(revision: HistoryRevision?) {
        if (!active) return
        if (revision != null && state.value.history.revisions.none { it.revision == revision }) return
        mutableState.value = state.value.copy(history = state.value.history.copy(selected = revision))
    }

    private fun acceptBaseline(loaded: Baseline) {
        baseline = loaded
        revision++
        validationJob?.cancel()
        mutableState.value = state.value.copy(relativePath = loaded.entry.relativePath,
            selection = selection(loaded.entry), source = loaded.source, stamp = loaded.entry.stamp,
            readOnlyReason = loaded.readOnlyReason, dirty = false, isNew = false, status = EditorStatus.READY,
            conflict = null, failure = null, historyMaintenanceFailed = false)
        applyProjection(loaded.projection)
    }

    private fun applyProjection(projection: EditorDocumentState) {
        mutableState.value = state.value.copy(title = projection.title, issues = projection.issues,
            fields = projection.fields, preview = projection.preview, previewAvailable = projection.previewAvailable, validating = false)
    }

    private fun projectFromState() = EditorDocumentState(state.value.title, state.value.issues,
        state.value.fields, state.value.preview, state.value.previewAvailable)
    private fun project(document: PromptDocument) = projectEditor(document, clock.now(), ZoneId.systemDefault())
    private fun selection(entry: LibraryEntry) = LibrarySelection(entry.identity, entry.relativePath)
    private fun current(snapshot: EditorSnapshot): Boolean = active && session == snapshot.session
    private fun isCommand(action: EditorAction): Boolean = action is EditorAction.Rename || action is EditorAction.Move ||
        action == EditorAction.Delete || action is EditorAction.Restore

    private fun failure(error: Exception): EditorFailure = when (error) {
        StoreError.InvalidPath, LibraryError.InvalidPromptPath -> EditorFailure.INVALID_PATH
        LibraryError.IdentityMismatch, LibraryError.KeyedStateConflict -> EditorFailure.IDENTITY
        LibraryError.RecoveryRequired -> EditorFailure.RECOVERY
        LibraryError.CommitUnverified -> EditorFailure.UNVERIFIED
        else -> EditorFailure.DATA
    }

    private fun reset() {
        session++
        revision++
        loadGeneration++
        historyGeneration++
        loadJob?.cancel()
        validationJob?.cancel()
        baseline = null
        runningCommand = null
        historyRequested = false
        mutableState.value = EditorUiState(pendingDecision = pending?.decision,
            queuedActions = requests.map { it.decision.action })
    }

    override fun onCleared() {
        active = false
        reset()
        pending = null
        requests.clear()
        onSelectionChanged = null
        super.onCleared()
    }
}
