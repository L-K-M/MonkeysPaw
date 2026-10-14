package ch.lkmc.monkeyspaw.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.services.AssistantConnectionService
import ch.lkmc.monkeyspaw.core.services.AssistantConnectionTest
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsService
import ch.lkmc.monkeyspaw.di.ApplicationScope
import ch.lkmc.monkeyspaw.di.AssistantProviderChanges
import ch.lkmc.monkeyspaw.di.IoDispatcher
import dagger.Lazy
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject

/** UI-confined staging. Core services own validation, credentials, IO and the Test deadline. */
@HiltViewModel
internal class AssistantSettingsViewModel @Inject constructor(
    private val settings: Lazy<ProviderSettingsService>,
    private val testing: Lazy<AssistantConnectionService>,
    @IoDispatcher private val worker: CoroutineDispatcher,
    @ApplicationScope private val applicationScope: CoroutineScope,
    private val providerChanges: AssistantProviderChanges,
) : ViewModel() {
    private enum class KeyInputHandling { PRESERVE, RESET }

    private val mutableState = MutableStateFlow(AssistantSettingsUiState())
    val state = mutableState.asStateFlow()
    private var snapshot = ProviderSettingsSnapshot(ProviderSettings())
    private var draft: ProviderDraft? = null
    private var picker: AssistantModelPickerState? = null
    private var connectionService: AssistantConnectionService? = null
    private var isOpen = false
    private var operation: AssistantSettingsOperation? = null
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
    private var alive = true
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
        if (operation == AssistantSettingsOperation.LOADING) operation = null
        publish()
    }

    fun refresh() {
        if (!isOpen || operation != null) return
        val navigation = navigationRevision
        stopTest()
        operation = AssistantSettingsOperation.LOADING
        error = null
        publish()
        if (!isOpen || navigation != navigationRevision) return
        loadJob = viewModelScope.launch {
            // Hilt's Lazy keeps synchronous ProviderSettingsStore construction off UI.
            val loaded = withContext(worker) { settings.get().snapshot to testing.get() }
            if (navigation != navigationRevision) return@launch
            snapshot = loaded.first
            connectionService = loaded.second
            operation = null
            error = snapshot.readOnlyError
            useDraft(selectedDraft())
            reloadStorage()
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

    /** A recreated native field is blank; discard its old replacement instead of saving hidden input. */
    fun discardTypedKey() {
        val current = draft ?: return
        if (current.key !is ProviderKeyEdit.Replace) return
        draft = current.copy(key = ProviderKeyEdit.Keep)
        editRevision++
        resetKeyInput()
        picker?.update(requireNotNull(draft))
        stopTest()
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
        this.operation = operation
        error = null
        stopTest()
        providerChanges.changed()
        publish()
        // Accepted mutations outlive this screen and ViewModel. Core protects commit/compensation.
        applicationScope.launch(worker) {
            val service = settings.get()
            val failure = try { edit(service); null }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { error as? ProviderSettingsError ?: ProviderSettingsError.WriteFailed }
            val updated = service.snapshot
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
            isTesting = picker?.isTesting == true)
    }

    override fun onCleared() {
        alive = false
        close()
        connectionService = null
        super.onCleared()
    }

    override fun toString(): String = "<assistant settings model redacted>"
}
