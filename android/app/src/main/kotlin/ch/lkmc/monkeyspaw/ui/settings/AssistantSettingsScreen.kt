package ch.lkmc.monkeyspaw.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.ConnectionTestResult
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderKind
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderSettingsError
import ch.lkmc.monkeyspaw.core.domain.llm.SecretStoreError

/** Renders safe metadata and forwards intents; only the native password field owns raw input. */
@Composable
internal fun AssistantSettingsScreen(
    state: AssistantSettingsUiState,
    onBack: () -> Unit,
    onAdd: () -> Unit,
    onSelect: (ProviderProfileID?) -> Unit,
    onDelete: (ProviderProfileID) -> Unit,
    onRename: (String) -> Unit,
    onKind: (ProviderKind) -> Unit,
    onBaseURL: (String) -> Unit,
    onModelID: (String) -> Unit,
    onKeyInput: (String) -> Unit,
    onKeepKey: () -> Unit,
    onClearKey: () -> Unit,
    onKeyInputDiscarded: () -> Unit,
    onSave: () -> Unit,
    onRefresh: () -> Unit,
    onTest: () -> Unit,
    onCancelTest: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    DisposableEffect(Unit) { onDispose { onKeyInputDiscarded() } }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TextButton(onClick = onBack) { Text(stringResource(R.string.assistant_settings_back)) }
        Text(stringResource(R.string.assistant_settings_title), style = MaterialTheme.typography.headlineMedium)
        // Disclose storage and outbound data before the first editable control.
        Text(stringResource(R.string.assistant_key_disclosure), style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.assistant_outbound_disclosure), style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.assistant_profiles), style = MaterialTheme.typography.titleMedium)
        var profilesExpanded by remember { mutableStateOf(false) }
        Box {
            OutlinedButton(onClick = { profilesExpanded = true }, enabled = state.canChangeProfiles) {
                Text(state.draft?.displayName ?: stringResource(R.string.assistant_no_profile))
            }
            DropdownMenu(expanded = profilesExpanded, onDismissRequest = { profilesExpanded = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.assistant_disable)) },
                    onClick = { profilesExpanded = false; onSelect(null) })
                for (profile in state.profiles) DropdownMenuItem(text = {
                    Text(if (profile.id == state.selectedProfileID) stringResource(R.string.assistant_profile_active, profile.displayName)
                        else profile.displayName)
                }, onClick = { profilesExpanded = false; onSelect(profile.id) })
            }
        }
        val active = state.profiles.firstOrNull { it.id == state.selectedProfileID }
        Text(if (active == null) stringResource(R.string.assistant_inactive)
            else stringResource(R.string.assistant_active_provider, active.displayName))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onAdd, enabled = state.canChangeProfiles) { Text(stringResource(R.string.assistant_add)) }
            TextButton(onClick = { state.draft?.id?.let(onDelete) }, enabled = state.canSave) {
                Text(stringResource(R.string.assistant_delete))
            }
        }
        if (!state.isNewProfile && state.draft != null && state.draft.id != state.selectedProfileID) {
            TextButton(onClick = { onSelect(state.draft.id) }, enabled = state.canChangeProfiles) {
                Text(stringResource(R.string.assistant_make_active))
            }
        }
        TextButton(onClick = { onSelect(null) }, enabled = state.canChangeProfiles) {
            Text(stringResource(R.string.assistant_disable))
        }
        val draft = state.draft
        if (state.isNewProfile) Text(stringResource(R.string.assistant_new_profile))
        if (draft != null) {
            OutlinedTextField(value = draft.displayName, onValueChange = onRename, enabled = state.canEditDraft,
                label = { Text(stringResource(R.string.assistant_profile_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Text(stringResource(R.string.assistant_provider_kind))
            for (kind in ProviderKind.entries) {
                FilterChip(selected = draft.kind == kind, onClick = { onKind(kind) }, enabled = state.canEditDraft,
                    label = { Text(stringResource(if (kind == ProviderKind.ANTHROPIC) R.string.assistant_anthropic
                        else R.string.assistant_compatible)) })
            }
            OutlinedTextField(value = draft.baseURL, onValueChange = onBaseURL, enabled = state.canEditDraft,
                label = { Text(stringResource(R.string.assistant_base_url)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = draft.modelID, onValueChange = onModelID, enabled = state.canEditDraft,
                label = { Text(stringResource(R.string.assistant_model_id)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Text(stringResource(R.string.assistant_manual_model), style = MaterialTheme.typography.bodySmall)
            var modelsExpanded by remember { mutableStateOf(false) }
            Box {
                OutlinedButton(onClick = { modelsExpanded = true }, enabled = state.canEditDraft && state.availableModels.isNotEmpty()) {
                    Text(stringResource(R.string.assistant_choose_model))
                }
                DropdownMenu(expanded = modelsExpanded, onDismissRequest = { modelsExpanded = false }) {
                    for (model in state.availableModels) DropdownMenuItem(text = {
                        val name = model.displayName
                        Text(if (name == null || name == model.id) model.id
                            else stringResource(R.string.assistant_model_label, name, model.id))
                    }, onClick = { modelsExpanded = false; onModelID(model.id) })
                }
            }
            HorizontalDivider()
            Text(stringResource(R.string.assistant_api_key), style = MaterialTheme.typography.titleMedium)
            AssistantSettingsKeyField(state.keyInputReset, state.canEditDraft,
                stringResource(R.string.assistant_key_placeholder), onKeyInput, Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onKeepKey, enabled = state.canEditDraft) { Text(stringResource(R.string.assistant_keep_key)) }
                TextButton(onClick = onClearKey, enabled = state.canEditDraft) { Text(stringResource(R.string.assistant_clear_key)) }
            }
            Text(stringResource(when (state.keyEdit) {
                AssistantKeyEdit.KEEP -> R.string.assistant_key_keep
                AssistantKeyEdit.REPLACE -> R.string.assistant_key_replace
                AssistantKeyEdit.CLEAR -> R.string.assistant_key_clear
            }))
            Text(stringResource(when (state.keyStorage) {
                AssistantKeyStorage.None -> R.string.assistant_key_none
                AssistantKeyStorage.Loading -> R.string.assistant_key_loading
                is AssistantKeyStorage.Saved -> R.string.assistant_key_saved
                is AssistantKeyStorage.Failed -> R.string.assistant_key_unknown
            }))
        } else if (state.operation == null) Text(stringResource(R.string.assistant_empty))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = onSave, enabled = state.canSave) { Text(stringResource(R.string.assistant_save)) }
            OutlinedButton(onClick = onTest, enabled = state.canTest) { Text(stringResource(R.string.assistant_test)) }
        }
        if (state.isTesting) TextButton(onClick = onCancelTest) { Text(stringResource(R.string.assistant_cancel_test)) }
        TextButton(onClick = onRefresh, enabled = state.operation == null) { Text(stringResource(R.string.assistant_refresh)) }
        val progress = state.operation?.let {
            when (it) {
                AssistantSettingsOperation.LOADING -> R.string.assistant_loading
                AssistantSettingsOperation.SAVING -> R.string.assistant_saving
                AssistantSettingsOperation.SELECTING -> R.string.assistant_selecting
                AssistantSettingsOperation.DELETING -> R.string.assistant_deleting
            }
        } ?: R.string.assistant_testing.takeIf { state.isTesting }
        if (progress != null) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(stringResource(progress))
        }
        val failures = listOfNotNull(state.readOnlyError, state.error,
            (state.keyStorage as? AssistantKeyStorage.Failed)?.error).distinct()
        for (failure in failures) Text(stringResource(settingsErrorResource(failure)), color = MaterialTheme.colorScheme.error)
        state.testResult?.let { Text(testResultMessage(it)) }
    }
}

@Composable
private fun testResultMessage(result: ConnectionTestResult): String = when (result) {
    is ConnectionTestResult.Ok -> if (result.models.isEmpty()) stringResource(R.string.assistant_test_empty)
        else stringResource(R.string.assistant_test_ok, result.models.size)
    ConnectionTestResult.Authentication -> stringResource(R.string.assistant_test_authentication)
    ConnectionTestResult.NotFound -> stringResource(R.string.assistant_test_not_found)
    is ConnectionTestResult.RateLimited -> stringResource(R.string.assistant_test_rate_limited)
    ConnectionTestResult.Network -> stringResource(R.string.assistant_test_network)
    ConnectionTestResult.Timeout -> stringResource(R.string.assistant_test_timeout)
    ConnectionTestResult.UnsupportedListing -> stringResource(R.string.assistant_test_unsupported)
    ConnectionTestResult.InvalidResponse -> stringResource(R.string.assistant_test_invalid)
    ConnectionTestResult.Cancelled -> stringResource(R.string.assistant_test_cancelled)
    is ConnectionTestResult.Settings -> stringResource(settingsErrorResource(result.error))
    is ConnectionTestResult.ProviderFailure -> stringResource(R.string.assistant_test_provider_failure, result.statusCode)
}

internal fun settingsErrorResource(error: ProviderSettingsError): Int = when (error) {
    is ProviderSettingsError.FutureVersion -> R.string.assistant_error_future
    is ProviderSettingsError.UnsupportedVersion -> R.string.assistant_error_version
    ProviderSettingsError.CorruptFile -> R.string.assistant_error_corrupt
    ProviderSettingsError.ReadFailed -> R.string.assistant_error_read
    ProviderSettingsError.WriteFailed -> R.string.assistant_error_write
    ProviderSettingsError.InvalidBaseURL -> R.string.assistant_error_url
    ProviderSettingsError.InsecureBaseURL -> R.string.assistant_error_insecure
    ProviderSettingsError.CredentialsInURL -> R.string.assistant_error_url_credentials
    ProviderSettingsError.QueryOrFragmentInURL -> R.string.assistant_error_url_query
    ProviderSettingsError.InvalidProfile -> R.string.assistant_error_profile
    ProviderSettingsError.InvalidKey -> R.string.assistant_error_key
    ProviderSettingsError.DuplicateProfile -> R.string.assistant_error_duplicate
    ProviderSettingsError.ProfileNotFound -> R.string.assistant_error_missing
    ProviderSettingsError.KeyRequiredForChangedDestination -> R.string.assistant_error_reentry
    ProviderSettingsError.SecretRollbackFailed -> R.string.assistant_error_rollback
    is ProviderSettingsError.Secret -> when (error.error) {
        SecretStoreError.InvalidAccount -> R.string.assistant_error_account
        SecretStoreError.Unavailable -> R.string.assistant_error_store_unavailable
        SecretStoreError.Locked -> R.string.assistant_error_store_locked
        SecretStoreError.ReadOnly -> R.string.assistant_error_store_read_only
        SecretStoreError.ReadFailed -> R.string.assistant_error_key_read
        SecretStoreError.WriteFailed -> R.string.assistant_error_key_write
        SecretStoreError.DeleteFailed -> R.string.assistant_error_key_delete
    }
}
