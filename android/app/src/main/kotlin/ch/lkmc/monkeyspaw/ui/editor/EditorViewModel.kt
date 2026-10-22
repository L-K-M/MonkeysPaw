package ch.lkmc.monkeyspaw.ui.editor

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.library.PromptCreation
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview
import ch.lkmc.monkeyspaw.core.ports.Clock
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.ApplicationScope
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
    @ApplicationScope private val applicationScope: CoroutineScope,
) : ViewModel(), AssistantAcceptanceEditor {
    private enum class LoadPurpose { REPLACE, RECONCILE, RELOCATED }
    private enum class DraftAcceptance { REPLACE, KEEP_NEWER }
    private data class Baseline(val entry: LibraryEntry, val source: String?,
        val readOnlyReason: SourceReadOnlyReason?, val projection: EditorDocumentState)
    private enum class GuardMode { UNSAVED_EDITS, PREVIEWED_BUFFER }
    private data class Request(val decision: EditorPendingDecision, val session: Long, val accessGeneration: Long,
        val mode: GuardMode = GuardMode.UNSAVED_EDITS, val operation: (() -> Unit)? = null,
        val cancelled: (() -> Unit)? = null, val afterClose: (() -> Unit)? = null)
    private data class Observation(val load: PromptLoadResult, val projection: EditorDocumentState?)
    private data class CommandResult(val result: EditResult, val projection: EditorDocumentState?)

    private val mutableState = MutableStateFlow(EditorUiState())
    val state = mutableState.asStateFlow()
    private var currentState: EditorUiState
        get() = mutableState.value
        set(value) { mutableState.value = value; notifyAssistantContext() }
    private val assistantObservers = linkedMapOf<Long, () -> Unit>()
    private var nextAssistantObserver = 0L
    private var notifiedAssistantSnapshot: AssistantEditorSnapshot? = null
    private var highlightedSnapshot: AssistantEditorSnapshot? = null
    private var reading = false
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
    private var assistantPermit: AssistantSavePermit? = null
    private var assistantWritePermit: LibraryWritePermit? = null
    private var assistantWriteOwner: CompletableJob? = null
    private var assistantPreparing = false
    private var observedAccessGeneration = repository.accessSnapshot.generation
    private var assistantSource: AssistantEditorSnapshot? = null
    private var assistantDecision: Long? = null
    private var adoptingAssistant = false
    private var adoptingBaseline = false

    init {
        viewModelScope.launch {
            repository.state.collect { library ->
                updateAccess(repository.accessSnapshot)
                if (library.refreshing || library.snapshot.version == 0L || state.value.writing ||
                    state.value.status == EditorStatus.LOADING || state.value.isNew) return@collect
                val path = state.value.relativePath ?: return@collect
                val stamp = baseline?.entry?.stamp ?: return@collect
                val identity = state.value.selection?.identity
                var current = library.snapshot.prompts.firstOrNull { it.entry.relativePath == path }?.entry
                if (current?.identity != identity) {
                    val moved = library.snapshot.prompts.filter { it.entry.identity == identity }.singleOrNull()?.entry
                    if (moved != null) {
                        current = moved
                        currentState = state.value.copy(relativePath = current.relativePath, selection = selection(current))
                        onSelectionChanged?.invoke(selection(current))
                        updateAccess(repository.accessSnapshot)
                    }
                }
                if (current?.stamp != stamp || current.relativePath != path) refresh()
            }
        }
    }

    fun snapshot(): EditorSnapshot? {
        val current = state.value
        return EditorSnapshot(session, revision, current.relativePath ?: return null,
            current.source ?: return null, current.stamp, current.selection?.identity, current.isNew)
    }

    val assistantAccessGeneration: Long get() = repository.accessSnapshot.generation

    /** Capture on the UI thread. Parsing, merge and diff belong to AssistantService's worker. */
    val assistantSnapshot: AssistantEditorSnapshot? get() {
        if (!active) return null
        val current = state.value
        val path = current.relativePath ?: return null
        val availability = when {
            current.conflict != null -> AssistantEditorAvailability.CONFLICTED
            reading || current.status == EditorStatus.LOADING || current.writing || pending != null ||
                requests.isNotEmpty() || savingDecision != null -> AssistantEditorAvailability.BUSY
            else -> AssistantEditorAvailability.AVAILABLE
        }
        return AssistantEditorSnapshot(current.source, path, revision, session, current.stamp,
            baseline?.entry?.document?.frontMatter?.id, availability,
            current.readOnlyReason?.takeUnless { it == SourceReadOnlyReason.GROUP_VIEWER }, current.isNew)
    }

    /** Synchronous notifications preserve away-and-back transitions that StateFlow can conflate. */
    fun addAssistantContextObserver(observer: () -> Unit): Long = (++nextAssistantObserver).also {
        if (active) assistantObservers[it] = observer
    }

    fun removeAssistantContextObserver(token: Long) { assistantObservers.remove(token) }

    /** Selection is UI-only and belongs to the complete checked review snapshot. */
    fun highlightReviewQuote(reviewed: AssistantEditorSnapshot, quote: String, range: LlmReview.QuoteMatch.Matched): Boolean {
        clearReviewQuote()
        if (assistantSnapshot != reviewed || reviewed.availability != AssistantEditorAvailability.AVAILABLE) return false
        val source = reviewed.source ?: return false
        val selection = reviewQuoteSelection(source, quote, range) ?: return false
        highlightedSnapshot = reviewed
        currentState = state.value.copy(tab = EditorTab.EDIT, quoteSelection = selection)
        return true
    }

    fun clearReviewQuote() {
        highlightedSnapshot = null
        if (state.value.quoteSelection != null) currentState = state.value.copy(quoteSelection = null)
    }

    private fun notifyAssistantContext() {
        if (adoptingAssistant) return
        val captured = assistantSnapshot
        if (captured == notifiedAssistantSnapshot) return
        notifiedAssistantSnapshot = captured
        if (highlightedSnapshot != null && captured != highlightedSnapshot) {
            highlightedSnapshot = null
            mutableState.value = state.value.copy(quoteSelection = null)
        }
        val permit = assistantPermit
        if (permit != null && captured?.copy(availability = AssistantEditorAvailability.AVAILABLE) !=
            assistantSource?.copy(availability = AssistantEditorAvailability.AVAILABLE)) {
            val outcome = if (!active || captured?.session != assistantSource?.session) {
                AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Inactive)
            } else AssistantAcceptanceOutcome.Conflict(AssistantAcceptanceConflict.ChangedBuffer)
            permit.invalidate(outcome)
            if (assistantDecision != null) cancelAssistantAcceptance(permit)
        }
        assistantObservers.values.toList().forEach { it() }
    }

    override fun acceptAssistant(acceptance: AssistantAcceptance, permit: AssistantSavePermit,
        validate: () -> AssistantAcceptanceOutcome?, completion: (AssistantAcceptanceOutcome) -> Unit) {
        if (!active) { completion(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Inactive)); return }
        if (reading || state.value.writing || state.value.status == EditorStatus.LOADING ||
            state.value.conflict != null || assistantPermit != null) {
            completion(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.EditorBusy))
            return
        }
        assistantPermit = permit
        assistantSource = acceptance.candidate.context.editor
        val epoch = session
        val accessGeneration = repository.accessSnapshot.generation
        val owner = SupervisorJob(applicationScope.coroutineContext[Job])
        assistantWriteOwner = owner
        assistantPreparing = true
        var completed = false
        val finish: (AssistantAcceptanceOutcome) -> Unit = { outcome ->
            if (!completed) {
                completed = true
                releaseAssistantPermit(permit)
                completion(outcome)
            }
        }
        val start = {
            assistantDecision = null
            val writePermit = checkNotNull(assistantWritePermit)
            val refusal = permit.refusal ?: validate() ?: when {
                !active || epoch != session -> AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Inactive)
                reading || state.value.writing || state.value.status == EditorStatus.LOADING || state.value.conflict != null ->
                    AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.EditorBusy)
                assistantSnapshot?.copy(availability = AssistantEditorAvailability.AVAILABLE) !=
                    acceptance.candidate.context.editor?.copy(availability = AssistantEditorAvailability.AVAILABLE) ->
                    AssistantAcceptanceOutcome.Conflict(AssistantAcceptanceConflict.ChangedBuffer)
                else -> null
            }
            if (refusal != null) { permit.invalidate(refusal); finish(refusal) }
            else startAssistantSave(acceptance, permit, writePermit, epoch, finish)
        }
        val source = acceptance.candidate.context.editor
        val path = PromptCreation.relativePath(acceptance.candidate.content.document.frontMatter.title, clock.now())
        val action = if (acceptance.destination == AssistantSaveDestination.IMPROVE && state.value.selection != null) {
            EditorAction.Open(checkNotNull(state.value.selection))
        } else EditorAction.New(path)
        val id = ++nextDecision
        assistantDecision = id
        // Reserve ordering now; drain cannot expose the decision until IO captures its permit.
        requests.addLast(Request(EditorPendingDecision(id, action), source?.session ?: epoch, accessGeneration,
            if (acceptance.destination == AssistantSaveDestination.IMPROVE) GuardMode.PREVIEWED_BUFFER else GuardMode.UNSAVED_EDITS,
            start, { finish(permit.refusal ?: AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Cancelled)) }))
        drain()
        applicationScope.launch(owner + Dispatchers.Main.immediate) {
            try {
                val writePermit = repository.withLibrary { _, editing -> editing.captureWritePermit(owner) }
                if (assistantPermit !== permit) { writePermit.cancel(); return@launch }
                assistantWritePermit = writePermit
                if (writePermit.accessGeneration != accessGeneration ||
                    acceptance.candidate.context.accessGeneration != accessGeneration) {
                    permit.invalidate(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.StaleContext))
                    cancelAssistantAcceptance(permit)
                    return@launch
                }
                assistantPreparing = false
                drain()
            } catch (error: Exception) {
                val refusal = permit.refusal ?: AssistantAcceptanceOutcome.Failed(if (error is CancellationException)
                    AssistantAcceptanceFailure.Cancelled else AssistantAcceptanceFailure.Editing(error))
                permit.invalidate(refusal)
                cancelAssistantAcceptance(permit)
                finish(refusal)
            }
        }
    }

    override fun cancelAssistantAcceptance(permit: AssistantSavePermit) {
        if (assistantPermit !== permit) return
        val id = assistantDecision
        val request = if (id != null && pending?.decision?.id == id) {
            pending.also { pending = null; savingDecision = null }
        } else requests.indexOfFirst { it.decision.id == id }.takeIf { it >= 0 }?.let { requests.removeAt(it) }
        releaseAssistantPermit(permit)
        if (request != null) {
            currentState = state.value.copy(pendingDecision = pending?.decision,
                queuedActions = requests.map { it.decision.action })
            request.cancelled?.invoke()
            drain()
        }
    }

    private fun releaseAssistantPermit(permit: AssistantSavePermit) {
        if (assistantPermit !== permit) return
        assistantWritePermit?.cancel()
        assistantWritePermit = null
        assistantWriteOwner?.cancel()
        assistantWriteOwner = null
        assistantPreparing = false
        assistantPermit = null
        assistantSource = null
        assistantDecision = null
    }

    private fun startAssistantSave(acceptance: AssistantAcceptance, permit: AssistantSavePermit, writePermit: LibraryWritePermit, epoch: Long,
        completion: (AssistantAcceptanceOutcome) -> Unit) {
        loadGeneration++
        historyGeneration++
        loadJob?.cancel()
        reading = false
        currentState = state.value.copy(status = EditorStatus.SAVING, failure = null, saveIssues = emptyList())
        // Accepted publication outlives the ViewModel, just like the settings mutation contract.
        applicationScope.launch(Dispatchers.Main.immediate) {
            var projection: EditorDocumentState? = null
            val outcome = try {
                repository.withLibrary { _, editing ->
                    editing.accept(acceptance, permit, writePermit).also { result ->
                        projection = result.committed?.entry?.document?.let(::project)
                    }
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Editing(error))
            }
            releaseAssistantPermit(permit)
            // Adopt first, complete the token second, notify observers last.
            adoptingAssistant = true
            try {
                currentState = state.value.copy(assistantAcceptanceOutcome = outcome)
                if (active && session == epoch) {
                    currentState = state.value.copy(status = if (state.value.isOpen) EditorStatus.READY else EditorStatus.CLOSED)
                    val commit = outcome.committed
                    if (commit != null) {
                        val source = acceptance.candidate.context.editor
                        val unchanged = source?.revision == assistantSnapshot?.revision && source?.source == state.value.source
                        val command = CommandResult(EditResult.Saved(LibrarySaveResult(commit.entry,
                            commit.historyMaintenanceFailed, outcome is AssistantAcceptanceOutcome.CommittedWithProvenanceWarning)), projection)
                        if (acceptance.destination == AssistantSaveDestination.IMPROVE || unchanged) {
                            if (acceptance.destination != AssistantSaveDestination.IMPROVE) session++
                            acceptCommit(command, if (unchanged) DraftAcceptance.REPLACE else DraftAcceptance.KEEP_NEWER)
                        } else currentState = state.value.copy(lastAssistantCopy = selection(commit.entry),
                            historyMaintenanceFailed = commit.historyMaintenanceFailed,
                            provenanceMaintenanceFailed = outcome is AssistantAcceptanceOutcome.CommittedWithProvenanceWarning)
                    } else when (outcome) {
                        is AssistantAcceptanceOutcome.Conflict -> when (val reason = outcome.reason) {
                            is AssistantAcceptanceConflict.Modified -> applyFailure(EditResult.Conflict(reason.currentStamp))
                            AssistantAcceptanceConflict.Deleted -> applyFailure(EditResult.Missing)
                            AssistantAcceptanceConflict.ChangedBuffer -> Unit
                        }
                        is AssistantAcceptanceOutcome.Failed -> when (val reason = outcome.reason) {
                            is AssistantAcceptanceFailure.Editing -> applyFailure(EditResult.Failed(reason.error))
                            is AssistantAcceptanceFailure.Invalid -> applyFailure(EditResult.Invalid(reason.issues))
                            is AssistantAcceptanceFailure.ReadOnly -> applyFailure(EditResult.ReadOnly(reason.reason))
                            else -> Unit
                        }
                        else -> Unit
                    }
                }
                completion(outcome)
            } finally { adoptingAssistant = false; notifyAssistantContext() }
            if (active) drain()
        }
    }

    fun open(selection: LibrarySelection) = request(EditorAction.Open(selection))
    fun createDraft(path: String = "Untitled.md", folder: String = "") =
        request(EditorAction.New(if (folder.isEmpty()) path else "$folder/$path"))
    fun close() = request(EditorAction.Close)
    fun closeThen(onClosed: () -> Unit) = request(EditorAction.Close, onClosed)
    fun cancelCloseThen() {
        requests.removeAll { it.afterClose != null }
        if (pending?.afterClose != null) {
            pending = null
            savingDecision = null
            currentState = state.value.copy(pendingDecision = null)
        }
        drain()
    }
    fun reload() = request(EditorAction.Reload)
    fun rename(filename: String) = request(EditorAction.Rename(filename))
    fun move(folder: String) = request(EditorAction.Move(folder))
    fun move(target: EditorMoveTarget) {
        val access = repository.accessSnapshot
        val group = target.groupID?.let { access.groups[it] }
        if (target.groupID != null && group == null) {
            currentState = state.value.copy(failure = EditorFailure.ACCESS_CHANGED)
            return
        }
        val folder = if (group == null) target.subfolder else
            "Groups/${group.folder}" + if (target.subfolder.isEmpty()) "" else "/${target.subfolder}"
        val destination = (if (folder.isEmpty()) "" else "$folder/") + state.value.relativePath.orEmpty().substringAfterLast('/')
        if (access.access(destination).readOnlyReason != null) {
            currentState = state.value.copy(failure = EditorFailure.READ_ONLY)
            return
        }
        // A Personal subfolder must not silently select a managed group instead.
        if (group == null && access.access(destination) != PromptAccessState.Local) {
            currentState = state.value.copy(failure = EditorFailure.INVALID_PATH)
            return
        }
        move(folder)
    }
    fun delete() = request(EditorAction.Delete)
    fun restore(revision: HistoryRevision) = request(EditorAction.Restore(revision))

    fun edit(source: String) {
        if (!active || !state.value.canEdit || state.value.source == source) return
        revision++
        currentState = state.value.copy(source = source,
            dirty = state.value.isNew || source != baseline?.source, validating = true,
            failure = null, saveIssues = emptyList(), status = if (state.value.writing) state.value.status else EditorStatus.READY)
        validate()
    }

    fun setNewPath(path: String) {
        if (!active || !state.value.isNew || state.value.writing || state.value.relativePath == path) return
        revision++
        currentState = state.value.copy(relativePath = path, dirty = true, failure = null, saveIssues = emptyList(), validating = true)
        updateAccess(repository.accessSnapshot)
        validate()
    }

    fun setTab(tab: EditorTab) {
        if (!active) return
        currentState = state.value.copy(tab = tab)
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
        val accessGeneration = repository.accessSnapshot.generation
        loadGeneration++
        loadJob?.cancel()
        reading = false
        currentState = state.value.copy(status = EditorStatus.SAVING, failure = null, saveIssues = emptyList())
        viewModelScope.launch {
            val completed = command(captured, accessGeneration) { editing, permit ->
                if (captured.isNew) editing.create(captured.source, captured.relativePath, permit)
                else editing.save(captured.source, captured.relativePath, stamp, permit)
            }
            if (!current(captured)) return@launch
            currentState = state.value.copy(status = EditorStatus.READY)
            if (completed.result is EditResult.Saved) {
                val unchanged = state.value.source == captured.source && state.value.relativePath == captured.relativePath
                acceptCommit(completed, if (unchanged) DraftAcceptance.REPLACE else DraftAcceptance.KEEP_NEWER)
                if (savingDecision == pending?.decision?.id && !state.value.dirty) finishDecision()
            } else applyFailure(completed.result)
            savingDecision = null
            drain()
            notifyAssistantContext()
        }
    }

    fun privateCopy(destination: String) {
        if (!active || !state.value.canPrivateCopy) return
        val original = baseline?.entry ?: return
        val captured = snapshot() ?: return
        val accessGeneration = repository.accessSnapshot.generation
        loadGeneration++
        loadJob?.cancel()
        historyGeneration++
        currentState = state.value.copy(status = EditorStatus.COMMAND, failure = null,
            history = state.value.history.copy(loading = false))
        viewModelScope.launch {
            val completed = command(captured, accessGeneration) { editing, permit ->
                editing.createPrivateCopy(captured.source, original, destination, permit)
            }
            if (!current(captured)) return@launch
            currentState = state.value.copy(status = EditorStatus.READY)
            if (completed.result is EditResult.Saved) {
                // Retire source-bound commands when adopting a new private identity.
                session++
                acceptCommit(completed, DraftAcceptance.REPLACE)
            } else applyFailure(completed.result)
            drain()
        }
    }

    fun resolveDecision(id: Long, decision: EditorDecision) {
        if (!active || state.value.writing || pending?.decision?.id != id) return
        updateAccess(repository.accessSnapshot)
        if (pending?.decision?.id != id) return
        when (decision) {
            EditorDecision.SAVE -> {
                if (state.value.conflict != null) return
                savingDecision = id
                save()
            }
            EditorDecision.DISCARD -> {
                // A refused file command retains the draft until it commits.
                if (pending?.decision?.action?.let(::isCommand) != true) {
                    if (baseline != null) acceptBaseline(checkNotNull(baseline)) else {
                        revision++
                        currentState = state.value.copy(source = "", validating = true)
                        validate()
                    }
                    currentState = state.value.copy(dirty = false, conflict = null, failure = null)
                }
                finishDecision()
            }
            EditorDecision.CANCEL -> {
                val cancelled = pending
                pending = null
                savingDecision = null
                currentState = state.value.copy(pendingDecision = null)
                cancelled?.cancelled?.invoke()
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
            reading = false
            currentState = state.value.copy(conflict = conflict.copy(loading = false,
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
                currentState = state.value.copy(conflict = conflict.copy(presentation = EditorConflictPresentation.DIALOG))
                refresh()
            }
            EditorConflictChoice.CANCEL -> Unit
        }
    }

    private fun request(action: EditorAction, afterClose: (() -> Unit)? = null) {
        if (!active) return
        if (action is EditorAction.Open && action.selection == state.value.selection) return
        if (action == runningCommand) return
        if (pending?.let { it.session == session && it.decision.action == action } == true ||
            requests.any { it.session == session && it.decision.action == action }) return
        requests.addLast(Request(EditorPendingDecision(++nextDecision, action), session, repository.accessSnapshot.generation,
            afterClose = afterClose))
        drain()
    }

    private fun drain() {
        // Cancelling an assistant guard during Save must wait for baseline/selection adoption.
        if (adoptingBaseline) return
        while (active && !state.value.writing && pending == null && requests.isNotEmpty()) {
            val next = requests.first()
            val action = next.decision.action
            if (next.decision.id == assistantDecision && assistantPreparing) break
            // File commands remain attached to the session requested, even behind queued navigation.
            if (isCommand(action) && next.session != session) {
                requests.removeFirst()
                continue
            }
            if (state.value.status == EditorStatus.LOADING && isCommand(action)) break
            requests.removeFirst()
            if (next.operation != null && next.session != session) {
                next.cancelled?.invoke()
                continue
            }
            if (state.value.dirty && next.mode == GuardMode.UNSAVED_EDITS) {
                pending = next
                val previous = notifiedAssistantSnapshot
                currentState = state.value.copy(pendingDecision = next.decision)
                // Permit preparation already made the snapshot busy; publishing the guard still notifies.
                if (pending != null && previous == notifiedAssistantSnapshot) {
                    assistantObservers.values.toList().forEach { it() }
                }
                break
            }
            perform(next)
            if (action == EditorAction.Close && requests.isEmpty()) next.afterClose?.invoke()
        }
        currentState = state.value.copy(queuedActions = requests.map { it.decision.action })
    }

    private fun finishDecision() {
        val request = pending
        pending = null
        savingDecision = null
        currentState = state.value.copy(pendingDecision = null)
        if (request != null && (!isCommand(request.decision.action) || request.session == session)) {
            perform(request)
            if (request.decision.action == EditorAction.Close && requests.isEmpty()) request.afterClose?.invoke()
        }
        drain()
    }

    private fun perform(request: Request) {
        if (request.operation != null) request.operation.invoke() else perform(request.decision.action, request.accessGeneration)
    }

    private fun perform(action: EditorAction, accessGeneration: Long) {
        when (action) {
            is EditorAction.Open -> {
                reset()
                currentState = state.value.copy(relativePath = action.selection.relativePath,
                    selection = action.selection, status = EditorStatus.LOADING)
                onSelectionChanged?.invoke(action.selection)
                load(LoadPurpose.REPLACE)
            }
            is EditorAction.New -> {
                reset()
                currentState = state.value.copy(relativePath = action.path, source = "",
                    isNew = true, dirty = true, status = EditorStatus.READY, validating = true)
                onSelectionChanged?.invoke(null)
                updateAccess(repository.accessSnapshot)
                validate()
            }
            EditorAction.Close -> reset()
            EditorAction.Reload -> if (state.value.isNew) {
                revision++
                currentState = state.value.copy(source = "", dirty = true, validating = true)
                validate()
            } else load(LoadPurpose.REPLACE)
            else -> startCommand(action, accessGeneration)
        }
    }

    private fun startCommand(action: EditorAction, accessGeneration: Long) {
        if (accessGeneration != repository.accessSnapshot.generation) {
            currentState = state.value.copy(failure = EditorFailure.ACCESS_CHANGED)
            return
        }
        if (!state.value.canCommand) {
            currentState = state.value.copy(failure = if (state.value.readOnlyReason != null) EditorFailure.READ_ONLY else EditorFailure.DATA)
            return
        }
        val captured = snapshot() ?: return
        val stamp = captured.stamp ?: return
        loadGeneration++
        loadJob?.cancel()
        reading = false
        historyGeneration++
        runningCommand = action
        currentState = state.value.copy(status = EditorStatus.COMMAND, failure = null,
            history = state.value.history.copy(loading = false))
        viewModelScope.launch {
            val completed = command(captured, accessGeneration) { editing, permit ->
                when (action) {
                    is EditorAction.Rename -> editing.rename(captured.relativePath, action.filename, stamp, permit)
                    is EditorAction.Move -> editing.move(captured.relativePath, action.folder, stamp, permit)
                    EditorAction.Delete -> editing.delete(captured.relativePath, stamp, permit)
                    is EditorAction.Restore -> editing.restore(action.revision, captured.relativePath, stamp, permit)
                    else -> error("Not a file command.")
                }
            }
            if (!current(captured)) return@launch
            runningCommand = null
            currentState = state.value.copy(status = EditorStatus.READY)
            when (val outcome = completed.result) {
                is EditResult.Saved -> {
                    if (action is EditorAction.Restore) historyRequested = true
                    acceptCommit(completed, DraftAcceptance.REPLACE)
                }
                EditResult.Deleted -> { onSelectionChanged?.invoke(null); reset() }
                is EditResult.Relocated -> {
                    // The move committed. Never reuse its source stamp or recreate the vacated path.
                    baseline = Baseline(outcome.baseline, captured.source, null, projectFromState())
                    currentState = state.value.copy(relativePath = outcome.baseline.relativePath,
                        selection = selection(outcome.baseline), stamp = null)
                    onSelectionChanged?.invoke(selection(outcome.baseline))
                    applyObservation(Observation(outcome.current, completed.projection), LoadPurpose.RELOCATED)
                }
                else -> applyFailure(outcome)
            }
            drain()
        }
    }

    private suspend fun command(captured: EditorSnapshot, accessGeneration: Long,
                                work: (EditingService, LibraryWritePermit) -> EditResult): CommandResult = try {
        val owner = currentCoroutineContext()[Job]
        repository.withLibrary { _, editing ->
            if (!current(captured)) return@withLibrary CommandResult(EditResult.Failed(LibraryError.OperationFailed), null)
            val permit = editing.captureWritePermit(owner)
            if (permit.accessGeneration != accessGeneration) throw LibraryError.AccessChanged
            val result = work(editing, permit)
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
        else currentState = state.value.copy(selection = selection(entry), stamp = entry.stamp,
            isNew = false, conflict = null, dirty = state.value.source != loaded.source)
        currentState = state.value.copy(historyMaintenanceFailed = saved.historyMaintenanceFailed,
            provenanceMaintenanceFailed = saved.provenanceMaintenanceFailed)
        onSelectionChanged?.invoke(selection(entry))
        if (identityChanged) {
            historyGeneration++
            currentState = state.value.copy(history = EditorHistoryState())
        }
        if (historyRequested) loadHistory()
        refresh()
    }

    private fun applyFailure(result: EditResult) {
        when (result) {
            is EditResult.Conflict -> {
                currentState = state.value.copy(conflict = EditorConflict(false, result.currentStamp, loading = true),
                    history = state.value.history.copy(currentProvenance = null))
                load(LoadPurpose.RECONCILE)
            }
            EditResult.Missing -> currentState = state.value.copy(conflict = EditorConflict(deleted = true),
                history = state.value.history.copy(currentProvenance = null))
            EditResult.DestinationOccupied -> currentState = state.value.copy(failure = EditorFailure.OCCUPIED)
            // The submitted draft may be older than the current live validation.
            is EditResult.Invalid -> currentState = state.value.copy(failure = EditorFailure.INVALID, saveIssues = result.issues)
            is EditResult.ReadOnly -> currentState = state.value.copy(failure = EditorFailure.READ_ONLY)
            is EditResult.ForensicRestoreBlocked -> currentState = state.value.copy(failure = EditorFailure.FORENSIC)
            is EditResult.Failed -> currentState = state.value.copy(failure = failure(result.error))
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
        reading = true
        notifyAssistantContext()
        if (purpose == LoadPurpose.REPLACE) currentState = state.value.copy(status = EditorStatus.LOADING, failure = null)
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
            if (purpose == LoadPurpose.REPLACE) currentState = state.value.copy(status = EditorStatus.READY)
            applyObservation(observed, purpose)
            drain()
            if (token == loadGeneration) reading = false
            notifyAssistantContext()
        }
    }

    private fun applyObservation(observed: Observation, purpose: LoadPurpose) {
        when (val load = observed.load) {
            is PromptLoadResult.Loaded -> {
                val loaded = load.prompt
                updateAccess(repository.accessSnapshot)
                // Folder renames and remodes can change stamps without changing the loaded source.
                if (purpose == LoadPurpose.RECONCILE && state.value.dirty && state.value.conflict == null &&
                    loaded.entry.identity == baseline?.entry?.identity && loaded.source == baseline?.source) {
                    baseline = Baseline(loaded.entry, loaded.source, loaded.readOnlyReason, checkNotNull(observed.projection))
                    currentState = state.value.copy(selection = selection(loaded.entry), stamp = loaded.entry.stamp)
                    return
                }
                if (purpose == LoadPurpose.REPLACE || purpose == LoadPurpose.RECONCILE && !state.value.dirty && state.value.conflict == null) {
                    // Own-commit reconciliation must not erase a committed maintenance warning.
                    if (purpose != LoadPurpose.REPLACE && loaded.entry.stamp == state.value.stamp) {
                        baseline = Baseline(loaded.entry, loaded.source, loaded.readOnlyReason, checkNotNull(observed.projection))
                        currentState = state.value.copy(failure = null, saveIssues = emptyList())
                        return
                    }
                    val previous = state.value.selection
                    acceptBaseline(Baseline(loaded.entry, loaded.source, loaded.readOnlyReason, checkNotNull(observed.projection)))
                    if (previous != state.value.selection) onSelectionChanged?.invoke(state.value.selection)
                    if (historyRequested) loadHistory()
                    if (pending != null) finishDecision()
                } else if (purpose == LoadPurpose.RELOCATED || loaded.entry.stamp != state.value.stamp || state.value.conflict != null) {
                    currentState = state.value.copy(conflict = EditorConflict(false, loaded.entry.stamp,
                        loaded.source, loaded.readOnlyReason), history = state.value.history.copy(currentProvenance = null))
                }
            }
            PromptLoadResult.Missing -> if (state.value.dirty || state.value.conflict != null || purpose == LoadPurpose.RELOCATED) {
                currentState = state.value.copy(conflict = EditorConflict(deleted = true),
                    history = state.value.history.copy(currentProvenance = null))
            } else { reset(); if (pending != null) finishDecision() }
            is PromptLoadResult.Failed -> currentState = state.value.copy(failure = failure(load.error),
                conflict = state.value.conflict?.copy(loading = false, failure = failure(load.error)))
        }
    }

    fun loadHistory() {
        if (!active) return
        historyRequested = true
        val selection = state.value.selection ?: return
        val stamp = state.value.stamp ?: return
        if (state.value.writing) return
        val epoch = session
        val token = ++historyGeneration
        currentState = state.value.copy(history = state.value.history.copy(loading = true, failure = null,
            currentProvenance = null))
        viewModelScope.launch {
            try {
                val history = repository.withLibrary { library, editing ->
                    val current = try { library.provenance(selection.relativePath, stamp) }
                    catch (_: LibraryError.InvalidProvenance) { null }
                    val revisions = editing.history(selection.identity, selection.relativePath.substringAfterLast('/')).map { snapshot ->
                        val document = snapshot.document
                        val unavailable = document.issues.any { it.code == PromptIssueCode.INVALID_UTF8 || it.code == PromptIssueCode.SOURCE_TOO_LARGE }
                        EditorRevision(snapshot.revision, snapshot.sourceBytes.size,
                            if (unavailable) null else document.source, document.canRender, snapshot.provenance)
                    }
                    EditorHistoryState(revisions = revisions, currentProvenance = current)
                }
                if (!active || epoch != session || token != historyGeneration || state.value.selection != selection ||
                    state.value.stamp != stamp) return@launch
                currentState = state.value.copy(history = history.copy(
                    selected = state.value.history.selected?.takeIf { selected -> history.revisions.any { it.revision == selected } }))
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (!active || epoch != session || token != historyGeneration) return@launch
                currentState = state.value.copy(history = state.value.history.copy(loading = false, failure = failure(error)))
            }
        }
    }

    fun selectRevision(revision: HistoryRevision?) {
        if (!active) return
        if (revision != null && state.value.history.revisions.none { it.revision == revision }) return
        currentState = state.value.copy(history = state.value.history.copy(selected = revision))
    }

    private fun acceptBaseline(loaded: Baseline) {
        val previous = adoptingBaseline
        adoptingBaseline = true
        try {
            baseline = loaded
            revision++
            validationJob?.cancel()
            currentState = state.value.copy(relativePath = loaded.entry.relativePath,
                selection = selection(loaded.entry), source = loaded.source, stamp = loaded.entry.stamp,
                readOnlyReason = loaded.readOnlyReason, dirty = false, isNew = false, status = EditorStatus.READY,
                conflict = null, failure = null, saveIssues = emptyList(), historyMaintenanceFailed = false,
                provenanceMaintenanceFailed = false, history = state.value.history.copy(currentProvenance = null))
            updateAccess(repository.accessSnapshot)
            applyProjection(loaded.projection)
        } finally { adoptingBaseline = previous }
    }

    private fun updateAccess(access: GroupAccessSnapshot) {
        val changed = observedAccessGeneration != access.generation
        observedAccessGeneration = access.generation
        val path = state.value.relativePath
        val policy = if (path == null) PromptAccessState.Local else access.access(path, state.value.selection?.identity)
        val formatReason = state.value.readOnlyReason?.takeUnless {
            it == SourceReadOnlyReason.GROUP_VIEWER || it == SourceReadOnlyReason.GROUP_UNAVAILABLE
        }
        val invalidPending = pending?.let { isCommand(it.decision.action) && it.accessGeneration != access.generation } == true
        val invalidQueued = requests.removeAll { isCommand(it.decision.action) && it.accessGeneration != access.generation }
        if (invalidPending) {
            pending = null
            savingDecision = null
        }
        mutableState.value = state.value.copy(access = policy, readOnlyReason = formatReason ?: policy.readOnlyReason,
            destinations = listOf(EditorDestination()) + access.groups.values.sortedBy { it.name }.map(::EditorDestination),
            pendingDecision = pending?.decision, queuedActions = requests.map { it.decision.action },
            failure = if (invalidPending || invalidQueued) EditorFailure.ACCESS_CHANGED else state.value.failure)
        if (changed) {
            assistantPermit?.let { permit ->
                permit.invalidate(AssistantAcceptanceOutcome.Failed(if (policy == PromptAccessState.Unavailable)
                    AssistantAcceptanceFailure.AccessDenied else AssistantAcceptanceFailure.StaleContext))
                cancelAssistantAcceptance(permit)
            }
            assistantObservers.values.toList().forEach { it() }
        }
        if (invalidPending || invalidQueued) drain()
    }

    private fun applyProjection(projection: EditorDocumentState) {
        currentState = state.value.copy(title = projection.title, issues = projection.issues,
            fields = projection.fields, preview = projection.preview, previewAvailable = projection.previewAvailable,
            isPrivate = projection.isPrivate, validating = false)
    }

    private fun projectFromState() = EditorDocumentState(state.value.title, state.value.issues,
        state.value.fields, state.value.preview, state.value.previewAvailable, state.value.isPrivate)
    private fun project(document: PromptDocument) = projectEditor(document, clock.now(), ZoneId.systemDefault())
    private fun selection(entry: LibraryEntry) = LibrarySelection(entry.identity, entry.relativePath)
    private fun current(snapshot: EditorSnapshot): Boolean = active && session == snapshot.session
    private fun isCommand(action: EditorAction): Boolean = action is EditorAction.Rename || action is EditorAction.Move ||
        action == EditorAction.Delete || action is EditorAction.Restore

    private fun failure(error: Exception): EditorFailure = when (error) {
        StoreError.InvalidPath, LibraryError.InvalidPromptPath -> EditorFailure.INVALID_PATH
        LibraryError.IdentityMismatch, LibraryError.KeyedStateConflict -> EditorFailure.IDENTITY
        LibraryError.RecoveryRequired -> EditorFailure.RECOVERY
        LibraryError.AccessDenied -> EditorFailure.READ_ONLY
        LibraryError.AccessChanged -> EditorFailure.ACCESS_CHANGED
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
        reading = false
        baseline = null
        runningCommand = null
        historyRequested = false
        currentState = EditorUiState(pendingDecision = pending?.decision,
            queuedActions = requests.map { it.decision.action })
    }

    override fun onCleared() {
        active = false
        assistantPermit?.let { permit ->
            permit.invalidate(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.Inactive))
            cancelAssistantAcceptance(permit)
        }
        reset()
        pending = null
        requests.clear()
        onSelectionChanged = null
        assistantObservers.clear()
        super.onCleared()
    }
}
