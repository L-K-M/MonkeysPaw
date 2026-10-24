package ch.lkmc.monkeyspaw.ui.settings

import ch.lkmc.monkeyspaw.core.domain.llm.*

/** Published metadata has no ProviderDraft, ProviderKeyEdit or SecretValue. */
internal data class AssistantSettingsDraft(
    val id: ProviderProfileID,
    val displayName: String,
    val kind: ProviderKind,
    val baseURL: String,
    val modelID: String,
) {
    constructor(draft: ProviderDraft) : this(draft.id, draft.displayName, draft.kind, draft.baseURL, draft.modelID)
    override fun toString(): String = "<assistant settings draft redacted>"
}

internal enum class AssistantKeyEdit { KEEP, REPLACE, CLEAR }
internal enum class AssistantSettingsOperation { LOADING, SAVING, SELECTING, DELETING }

internal sealed interface AssistantKeyStorage {
    data object None : AssistantKeyStorage
    data object Loading : AssistantKeyStorage
    data class Saved(val tier: SecretTier) : AssistantKeyStorage
    data class Failed(val error: ProviderSettingsError) : AssistantKeyStorage
}

internal enum class AssistantSyncKeyStatus { NO_ACCOUNT, MISSING, PROVISIONED, UNAVAILABLE }
internal enum class AssistantSyncKeyNotice { INVALID_KEY, OPERATION_FAILED }

/** §26 S12: the reveal is the only key text ever published; toString stays redacted. */
internal data class AssistantSyncKey(
    val status: AssistantSyncKeyStatus = AssistantSyncKeyStatus.NO_ACCOUNT,
    val busy: Boolean = false,
    val notice: AssistantSyncKeyNotice? = null,
    val revealedKey: String? = null,
    /** Secure input clears on commit and navigation, like keyInputReset. */
    val inputReset: Long = 0,
) {
    val canEdit: Boolean get() = !busy &&
        (status == AssistantSyncKeyStatus.MISSING || status == AssistantSyncKeyStatus.PROVISIONED)
    override fun toString(): String = "<assistant sync key redacted>"
}

internal data class AssistantSettingsUiState(
    val isOpen: Boolean = false,
    val profiles: List<ProviderProfile> = emptyList(),
    val selectedProfileID: ProviderProfileID? = null,
    val draft: AssistantSettingsDraft? = null,
    val keyEdit: AssistantKeyEdit = AssistantKeyEdit.KEEP,
    val keyStorage: AssistantKeyStorage = AssistantKeyStorage.None,
    val operation: AssistantSettingsOperation? = null,
    val readOnlyError: ProviderSettingsError? = null,
    val error: ProviderSettingsError? = null,
    val availableModels: List<ModelDescriptor> = emptyList(),
    val testResult: ConnectionTestResult? = null,
    val isTesting: Boolean = false,
    val syncKey: AssistantSyncKey = AssistantSyncKey(),
    /** Secure input clears on commit/discard, including when the profile ID stays the same. */
    val keyInputReset: Long = 0,
) {
    val isReadOnly: Boolean get() = readOnlyError != null
    val isNewProfile: Boolean get() = draft != null && profiles.none { it.id == draft.id }
    val canChangeProfiles: Boolean get() = operation == null && !isReadOnly
    val canEditDraft: Boolean get() = draft != null && !isReadOnly &&
        (operation == null || operation == AssistantSettingsOperation.SAVING)
    val canSave: Boolean get() = canChangeProfiles && draft != null
    val canTest: Boolean get() = canSave && !isTesting
    val requiresKeyReentry: Boolean get() = error == ProviderSettingsError.KeyRequiredForChangedDestination ||
        testResult == ConnectionTestResult.Settings(ProviderSettingsError.KeyRequiredForChangedDestination)

    override fun toString(): String = "<assistant settings state redacted>"
}
