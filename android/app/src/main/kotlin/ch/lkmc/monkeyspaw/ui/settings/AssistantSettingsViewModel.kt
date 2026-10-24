package ch.lkmc.monkeyspaw.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.services.AssistantConnectionService
import ch.lkmc.monkeyspaw.core.services.AssistantConnectionTest
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsService
import ch.lkmc.monkeyspaw.core.services.ProviderSyncKeyError
import ch.lkmc.monkeyspaw.core.services.ProviderSyncKeyService
import ch.lkmc.monkeyspaw.di.ApplicationScope
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.di.IoDispatcher
import ch.lkmc.monkeyspaw.di.SyncAccountUser
import dagger.Lazy
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject

/** UI-confined staging. Core services own validation, credentials, IO and the Test deadline. */
@HiltViewModel
internal class AssistantSettingsViewModel @Inject constructor(
    private val settings: Lazy<ProviderSettingsService>,
    private val testing: Lazy<AssistantConnectionService>,
    @IoDispatcher private val worker: CoroutineDispatcher,
    @ApplicationScope private val applicationScope: CoroutineScope,
    private val providerChanges: AssistantProviderChanges,
    private val syncKeys: Lazy<ProviderSyncKeyService>,
    private val syncAccount: SyncAccountUser,
) : ViewModel() {
    private enum class KeyInputHandling { PRESERVE, RESET }

    private val mutableState = MutableStateFlow(AssistantSettingsUiState())
    val state = mutableState.asStateFlow()
    private var snapshot = ProviderSettingsSnapshot(ProviderSettings())
    private var draft: ProviderDraft? = null
    private var picker: AssistantModelPickerState? = null
    private var connectionService: AssistantConnectionService? = null
    private var isOpen = false
    @Volatile private var operation: AssistantSettingsOperation? = null
    private var error: ProviderSettingsError? = null
    private var keyStorage: AssistantKeyStorage = AssistantKeyStorage.None
    private var keyInputReset = 0L
    private var editRevision = 0L
    private var storageRevision = 0L
    private var navigationRevision = 0L
    private var loadJob: Job? = null
    private var storageJob: Job? = null
    private var activeTest: ConnectionTestRequestID? = null
    private var test: AssistantConnectionTest? = null
    @Volatile private var alive = true
    private var syncKey = AssistantSyncKey()
    private var syncKeyInput = ""
    private var syncKeyInputReset = 0L
    private var syncKeyRevision = 0L
    private var syncKeyJob: Job? = null
    private var syncKeyAccountID: ULID? = null
    private var syncKeyBindingRevision = 0L
    private var syncKeyOperationActive = false
    private var syncKeyOperationPermit: AtomicBoolean? = null
    private var observedSettings: ProviderSettingsService? = null
    private var storeObserver: Long? = null
    private val canChangeProfiles: Boolean get() = operation == null && !snapshot.isReadOnly
    private val canEditDraft: Boolean get() = draft != null && !snapshot.isReadOnly &&
        (operation == null || operation == AssistantSettingsOperation.SAVING)

    fun open() {
        if (!alive || isOpen) return
        isOpen = true
        if (operation == null) refresh() else publish()
    }

    /** Navigation owns departure; no Bundle, SavedStateHandle or saved Compose state carries input. */
    fun close() {
        navigationRevision++
        loadJob?.cancel()
        storageJob?.cancel()
        storageRevision++
        useDraft(null)
        isOpen = false
        keyStorage = AssistantKeyStorage.None
        error = null
        syncKeyInput = ""
        syncKeyRevision++
        syncKeyJob?.cancel()
        syncKey = syncKey.copy(notice = null, revealedKey = null)
        if (operation == AssistantSettingsOperation.LOADING) operation = null
        publish()
    }

    fun refresh(preserveDraft: Boolean = false) {
        if (!isOpen || operation != null) return
        val navigation = navigationRevision
        stopTest()
        operation = AssistantSettingsOperation.LOADING
        error = null
        publish()
        if (!isOpen || navigation != navigationRevision) return
        loadJob = viewModelScope.launch {
            // Hilt's Lazy keeps synchronous ProviderSettingsStore construction off UI.
            val loaded = try { withContext(worker) { settings.get().let { it to (it.snapshot to testing.get()) } } }
            catch (failure: CancellationException) { throw failure }
            catch (failure: Exception) {
                if (navigation != navigationRevision) return@launch
                val typed = failure as? ProviderSettingsError ?: ProviderSettingsError.ReadFailed
                snapshot = ProviderSettingsSnapshot(snapshot.settings, typed)
                operation = null
                error = typed
                keyStorage = AssistantKeyStorage.Failed(typed)
                publish()
                return@launch
            }
            if (navigation != navigationRevision) return@launch
            // A remote apply rewrites the file out-of-band; the open page reloads.
            if (storeObserver == null) {
                observedSettings = loaded.first
                storeObserver = loaded.first.observeChanges { onSettingsStoreChange() }
            }
            snapshot = loaded.second.first
            connectionService = loaded.second.second
            operation = null
            error = snapshot.readOnlyError
            // Observer-triggered reloads keep staged edits; an unedited or
            // absent draft still re-derives so remote selection applies.
            val staged = draft
            val committed = staged?.let { current ->
                snapshot.settings.profiles.firstOrNull { it.id == current.id } }
            val keepDraft = staged != null && (committed == null || staged != ProviderDraft(committed))
            if (!preserveDraft || !keepDraft) useDraft(selectedDraft())
            reloadStorage()
            refreshSyncKey()
        }
    }

    /** Store writes during an admitted operation are covered by its completion. */
    private fun onSettingsStoreChange() {
        if (operation != null || !alive) return
        viewModelScope.launch(Dispatchers.Main.immediate) {
            if (alive && isOpen && operation == null) refresh(preserveDraft = true)
        }
    }

    fun addProfile(kind: ProviderKind = ProviderKind.ANTHROPIC) {
        if (!isOpen || !canChangeProfiles) return
        error = null
        useDraft(ProviderDraft(kind = kind))
        reloadStorage()
    }

    fun selectProfile(id: ProviderProfileID?) = perform(AssistantSettingsOperation.SELECTING,
        edit = { it.selectProfile(id) }, finish = { if (it) useDraft(selectedDraft()) })

    fun renameProfile(name: String) = editDraft { it.copy(displayName = name) }
    fun setKind(kind: ProviderKind) = editDraft { it.copy(kind = kind) }
    fun setBaseURL(url: String) = editDraft { it.copy(baseURL = url) }
    fun setModelID(id: String) = editDraft { it.copy(modelID = id) }
    fun setKeyInput(input: String) = editDraft { it.copy(key = ProviderKeyEdit.typed(input)) }
    fun keepKey() = editDraft(KeyInputHandling.RESET) { it.copy(key = ProviderKeyEdit.Keep) }
    fun clearKey() = editDraft(KeyInputHandling.RESET) { it.copy(key = ProviderKeyEdit.Clear) }

    /** Disposal retires a replacement even during persistence/read-only state: a new field is blank. */
    fun discardTypedKey() {
        val current = draft ?: return
        if (current.key !is ProviderKeyEdit.Replace) return
        draft = current.copy(key = ProviderKeyEdit.Keep)
        editRevision++
        resetKeyInput()
        picker?.update(requireNotNull(draft))
        stopTest()
        error = null
        publish()
    }

    fun save() {
        val submitted = draft ?: return
        val revision = editRevision
        perform(AssistantSettingsOperation.SAVING, edit = { it.save(submitted) }) { success ->
            if (!success) return@perform
            if (editRevision == revision) {
                useDraft(snapshot.settings.profiles.firstOrNull { it.id == submitted.id }?.let(::ProviderDraft))
            } else {
                // Retire only the committed key; newer input stays staged with newer metadata.
                val current = draft ?: return@perform
                if (current.id != submitted.id || current.key != submitted.key) return@perform
                draft = current.copy(key = ProviderKeyEdit.Keep)
                editRevision++
                resetKeyInput()
                picker?.update(requireNotNull(draft))
            }
        }
    }

    fun deleteProfile(id: ProviderProfileID) {
        if (!isOpen || !canChangeProfiles) return
        if (draft?.id == id && snapshot.settings.profiles.none { it.id == id }) {
            error = null
            useDraft(selectedDraft())
            reloadStorage()
            return
        }
        perform(AssistantSettingsOperation.DELETING, edit = { it.deleteProfile(id) }) { success ->
            if (success && draft?.id == id) useDraft(selectedDraft())
        }
    }

    fun testConnection() {
        if (!isOpen || !canChangeProfiles) return
        val submitted = draft ?: return
        val service = connectionService ?: return
        val request = picker?.beginTest() ?: return
        activeTest = request
        val previous = test
        test = null
        previous?.cancel()
        error = null
        publish()
        if (activeTest != request) return
        val handle = service.testConnection(submitted) { result ->
            if (!alive || activeTest != request || picker?.receive(result, request) != true) return@testConnection
            activeTest = null
            test = null
            publish()
        }
        if (activeTest == request) test = handle else handle.cancel()
    }

    fun cancelTest() { stopTest(); publish() }

    /** Raw entry text stays in the ViewModel until Enter commits it, like the draft key. */
    fun setSyncKeyInput(text: String) { syncKeyInput = text }
    fun syncKeyGenerate() = syncKeyOperation { keys, userID -> keys.generateKey(userID) }
    fun syncKeyEnter() { val text = syncKeyInput; syncKeyOperation { keys, userID -> keys.enterKey(userID, text) } }
    fun syncKeyRemove() = syncKeyOperation { keys, userID -> keys.removeKey(userID); null }

    fun syncKeyDismissReveal() {
        if (syncKey.revealedKey == null) return
        syncKey = syncKey.copy(revealedKey = null)
        publish()
    }

    private data class SyncKeyBinding(
        val userID: ULID?, val status: AssistantSyncKeyStatus,
    )

    private fun refreshSyncKey() {
        // Status reads may discover an account change while an accepted key
        // operation finishes; they never cancel that operation's storage work.
        val revision = ++syncKeyRevision
        syncKeyJob?.cancel()
        syncKeyJob = viewModelScope.launch {
            val binding = withContext(worker) { readSyncKeyBinding() }
            if (!alive || revision != syncKeyRevision) return@launch
            applySyncKeyBinding(binding)
            publish()
        }
    }

    private suspend fun readSyncKeyBinding(): SyncKeyBinding {
        val userID = try { syncAccount.userID() }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) { return SyncKeyBinding(null, AssistantSyncKeyStatus.UNAVAILABLE) }
            ?: return SyncKeyBinding(null, AssistantSyncKeyStatus.NO_ACCOUNT)
        val status = try {
            if (syncKeys.get().tier(userID) != null) AssistantSyncKeyStatus.PROVISIONED else AssistantSyncKeyStatus.MISSING
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { AssistantSyncKeyStatus.UNAVAILABLE }
        return SyncKeyBinding(userID, status)
    }

    private fun applySyncKeyBinding(binding: SyncKeyBinding) {
        val changed = syncKeyAccountID != binding.userID
        syncKeyAccountID = binding.userID
        if (changed) {
            syncKeyOperationPermit?.set(false)
            syncKeyBindingRevision++
            syncKeyInput = ""
            syncKeyInputReset++
        }
        syncKey = syncKey.copy(status = binding.status, busy = syncKeyOperationActive,
            notice = if (changed) null else syncKey.notice,
            revealedKey = if (changed) null else syncKey.revealedKey)
    }

    /** Accepted key operations outlive this screen and ViewModel, like profile saves. */
    private fun syncKeyOperation(operation: suspend (ProviderSyncKeyService, ULID) -> String?) {
        if (!syncKey.canEdit) return
        val submittedAccount = syncKeyAccountID ?: return
        val bindingRevision = syncKeyBindingRevision
        syncKeyOperationActive = true
        val permit = AtomicBoolean(true)
        syncKeyOperationPermit = permit
        // The admitted account stays immutable while storage work outlives navigation.
        syncKeyRevision++
        syncKeyJob?.cancel()
        syncKey = syncKey.copy(busy = true, notice = null, revealedKey = null)
        publish()
        applicationScope.launch(worker) {
            var revealed: String? = null
            var notice: AssistantSyncKeyNotice? = null
            try {
                if (syncAccount.userID() == submittedAccount && permit.getAndSet(false)) {
                    revealed = operation(syncKeys.get(), submittedAccount)
                }
            } catch (error: CancellationException) { throw error }
            catch (error: ProviderSyncKeyError) {
                notice = if (error is ProviderSyncKeyError.InvalidKey) AssistantSyncKeyNotice.INVALID_KEY
                    else AssistantSyncKeyNotice.OPERATION_FAILED
            } catch (error: Exception) { notice = AssistantSyncKeyNotice.OPERATION_FAILED }
            val binding = readSyncKeyBinding()
            withContext(Dispatchers.Main.immediate) {
                if (!alive) return@withContext
                syncKeyOperationActive = false
                syncKeyOperationPermit = null
                // A newer account status may already have rendered while this
                // operation was finishing. Release busy without restoring old state.
                if (bindingRevision == syncKeyBindingRevision) applySyncKeyBinding(binding)
                else syncKey = syncKey.copy(busy = false)
                val current = binding.userID == submittedAccount && bindingRevision == syncKeyBindingRevision
                syncKeyInput = ""
                syncKeyInputReset++
                syncKey = syncKey.copy(notice = if (current) notice else null,
                    revealedKey = if (current) revealed else null, inputReset = syncKeyInputReset)
                publish()
            }
        }
    }

    private fun editDraft(keyInput: KeyInputHandling = KeyInputHandling.PRESERVE, edit: (ProviderDraft) -> ProviderDraft) {
        if (!isOpen || !canEditDraft) return
        val current = draft ?: return
        val next = edit(current)
        if (keyInput == KeyInputHandling.RESET) resetKeyInput()
        if (current != next) {
            draft = next
            editRevision++
            picker?.update(next)
            stopTest()
            error = null
        }
        publish()
    }

    private fun selectedDraft(): ProviderDraft? = snapshot.settings.profiles
        .firstOrNull { it.id == snapshot.settings.selectedProfileID }?.let(::ProviderDraft)

    private fun useDraft(next: ProviderDraft?) {
        stopTest()
        draft = next
        picker = next?.let(::AssistantModelPickerState)
        editRevision++
        resetKeyInput()
    }

    private fun resetKeyInput() {
        keyInputReset++
    }

    private fun stopTest() {
        picker?.cancelTest()
        activeTest = null
        val previous = test
        test = null
        previous?.cancel()
    }

    private fun perform(operation: AssistantSettingsOperation, edit: suspend (ProviderSettingsService) -> Unit,
        finish: (Boolean) -> Unit) {
        if (!isOpen || !canChangeProfiles) return
        val navigation = navigationRevision
        val previousSnapshot = snapshot
        this.operation = operation
        error = null
        stopTest()
        providerChanges.changed()
        publish()
        // Accepted mutations outlive this screen and ViewModel. Core protects commit/compensation.
        applicationScope.launch(worker) {
            var service: ProviderSettingsService? = null
            val failure = try {
                val resolved = settings.get()
                service = resolved
                edit(resolved)
                null
            }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { error as? ProviderSettingsError ?: ProviderSettingsError.WriteFailed }
            val updated = service?.snapshot ?: ProviderSettingsSnapshot(previousSnapshot.settings, failure)
            withContext(Dispatchers.Main.immediate) {
                providerChanges.changed()
                if (!alive) return@withContext
                snapshot = updated
                this@AssistantSettingsViewModel.operation = null
                error = failure
                if (navigation == navigationRevision && isOpen) finish(failure == null)
                else if (isOpen) useDraft(selectedDraft())
                reloadStorage()
            }
        }
    }

    private fun reloadStorage() {
        val revision = ++storageRevision
        storageJob?.cancel()
        val id = draft?.id
        val storage = when {
            id == null -> AssistantKeyStorage.None
            snapshot.readOnlyError != null -> AssistantKeyStorage.Failed(requireNotNull(snapshot.readOnlyError))
            snapshot.settings.profiles.none { it.id == id && it.secretReference != null } -> AssistantKeyStorage.None
            else -> AssistantKeyStorage.Loading
        }
        keyStorage = storage
        publish()
        if (storage != AssistantKeyStorage.Loading || storageRevision != revision || draft?.id != id || !isOpen) return
        storageJob = viewModelScope.launch {
            val result = try {
                withContext(worker) { settings.get().secretTier(requireNotNull(id)) }
                    ?.let(AssistantKeyStorage::Saved) ?: AssistantKeyStorage.None
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { AssistantKeyStorage.Failed(error as? ProviderSettingsError
                ?: ProviderSettingsError.Secret(SecretStoreError.ReadFailed)) }
            if (storageRevision != revision || draft?.id != id) return@launch
            keyStorage = result
            publish()
        }
    }

    private fun publish() {
        mutableState.value = AssistantSettingsUiState(isOpen = isOpen, operation = operation, error = error,
            keyStorage = keyStorage, keyInputReset = keyInputReset, profiles = snapshot.settings.profiles,
            selectedProfileID = snapshot.settings.selectedProfileID, draft = draft?.let(::AssistantSettingsDraft),
            readOnlyError = snapshot.readOnlyError, keyEdit = when (draft?.key ?: ProviderKeyEdit.Keep) {
                ProviderKeyEdit.Keep -> AssistantKeyEdit.KEEP
                ProviderKeyEdit.Clear -> AssistantKeyEdit.CLEAR
                is ProviderKeyEdit.Replace -> AssistantKeyEdit.REPLACE
            }, availableModels = picker?.availableModels.orEmpty(), testResult = picker?.lastResult,
            isTesting = picker?.isTesting == true, syncKey = syncKey.copy(inputReset = syncKeyInputReset))
    }

    override fun onCleared() {
        alive = false
        close()
        storeObserver?.let { observedSettings?.removeObserver(it) }
        storeObserver = null
        observedSettings = null
        connectionService = null
        super.onCleared()
    }

    override fun toString(): String = "<assistant settings model redacted>"
}
