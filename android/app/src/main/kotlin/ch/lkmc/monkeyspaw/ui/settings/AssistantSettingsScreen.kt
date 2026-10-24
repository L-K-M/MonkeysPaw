package ch.lkmc.monkeyspaw.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.SmartToy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.ConnectionTestResult
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderKind
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderSettingsError
import ch.lkmc.monkeyspaw.core.domain.llm.SecretStoreError
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing
import ch.lkmc.monkeyspaw.ui.theme.PawLayout

/** Renders safe metadata and forwards intents; only the native password field owns raw input. */
@OptIn(ExperimentalMaterial3Api::class)
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
    onSyncKeyInput: (String) -> Unit,
    onSyncKeyGenerate: () -> Unit,
    onSyncKeyEnter: () -> Unit,
    onSyncKeyRemove: () -> Unit,
    onSyncKeyDismissReveal: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    DisposableEffect(Unit) { onDispose { onKeyInputDiscarded() } }
    var menuOpen by remember { mutableStateOf(false) }
    var privacyDetails by remember { mutableStateOf(false) }
    var deleteConfirmation by remember(state.draft?.id) { mutableStateOf<ProviderProfileID?>(null) }
    PawScreen(stringResource(R.string.assistant_settings_title), modifier, onBack = onBack, contentMaxWidth = PawLayout.formWidth,
        actions = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Rounded.MoreVert, stringResource(R.string.design_more_options))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.assistant_refresh)) },
                        leadingIcon = { Icon(Icons.Rounded.Refresh, null) },
                        enabled = state.operation == null,
                        onClick = { menuOpen = false; onRefresh() })
                }
            }
        }, bottomBar = {
            AssistantSettingsDock(state, onSave, onTest, onCancelTest)
        }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(PawLayout.pageGutter),
            verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
            // Disclose storage and outbound data before the first editable control.
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Column(Modifier.padding(PawSpacing.large), verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    Text(stringResource(R.string.design_provider_privacy), style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    TextButton(onClick = { privacyDetails = true }) { Text(stringResource(R.string.design_privacy_details)) }
                }
            }
            AssistantSection(stringResource(R.string.assistant_profiles)) {
                var profilesExpanded by remember { mutableStateOf(false) }
                ExposedDropdownMenuBox(expanded = profilesExpanded, onExpandedChange = { profilesExpanded = it }) {
                    OutlinedTextField(
                        value = state.draft?.displayName ?: stringResource(R.string.assistant_no_profile),
                        onValueChange = {}, readOnly = true, singleLine = true,
                        label = { Text(stringResource(R.string.assistant_profile_label)) },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = profilesExpanded) },
                        enabled = state.canChangeProfiles,
                        modifier = Modifier
                            .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, state.canChangeProfiles)
                            .fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                        colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest))
                    ExposedDropdownMenu(expanded = profilesExpanded, onDismissRequest = { profilesExpanded = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.assistant_disable)) },
                            onClick = { profilesExpanded = false; onSelect(null) })
                        for (profile in state.profiles) DropdownMenuItem(text = {
                            Text(if (profile.id == state.selectedProfileID)
                                stringResource(R.string.assistant_profile_active, profile.displayName)
                                else profile.displayName)
                        }, onClick = { profilesExpanded = false; onSelect(profile.id) })
                    }
                }
                val active = state.profiles.firstOrNull { it.id == state.selectedProfileID }
                PawMessage(if (active == null) stringResource(R.string.assistant_inactive)
                    else stringResource(R.string.assistant_active_provider, active.displayName),
                    tone = if (active == null) PawMessageTone.WARNING else PawMessageTone.INFO)
                if (state.isNewProfile) {
                    PawMessage(stringResource(R.string.assistant_new_profile), tone = PawMessageTone.INFO)
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    FilledTonalButton(onClick = onAdd, enabled = state.canChangeProfiles) {
                        Text(stringResource(R.string.assistant_add))
                    }
                    TextButton(onClick = {
                        val id = state.draft?.id ?: return@TextButton
                        if (state.isNewProfile) onDelete(id) else deleteConfirmation = id
                    }, enabled = state.canSave,
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(stringResource(R.string.assistant_delete))
                    }
                    if (!state.isNewProfile && state.draft != null && state.draft.id != state.selectedProfileID) {
                        TextButton(onClick = { onSelect(state.draft.id) }, enabled = state.canChangeProfiles) {
                            Text(stringResource(R.string.assistant_make_active))
                        }
                    }
                    TextButton(onClick = { onSelect(null) }, enabled = state.canChangeProfiles) {
                        Text(stringResource(R.string.assistant_disable))
                    }
                }
            }
            val draft = state.draft
            if (draft != null) {
                AssistantSection(stringResource(R.string.assistant_section_profile)) {
                    OutlinedTextField(value = draft.displayName, onValueChange = onRename, enabled = state.canEditDraft,
                        label = { Text(stringResource(R.string.assistant_profile_name)) }, singleLine = true,
                        modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                        colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest))
                    Text(stringResource(R.string.assistant_provider_kind), style = MaterialTheme.typography.labelLarge)
                    // Give long protocol labels room to wrap at the user's font size.
                    Column(Modifier.selectableGroup()) {
                        for (kind in ProviderKind.entries) {
                            Row(Modifier.fillMaxWidth().heightIn(min = PawLayout.touchTarget)
                                .selectable(selected = draft.kind == kind, enabled = state.canEditDraft,
                                    role = Role.RadioButton, onClick = { onKind(kind) })
                                .padding(vertical = PawSpacing.small),
                                horizontalArrangement = Arrangement.spacedBy(PawSpacing.small),
                                verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = draft.kind == kind, onClick = null, enabled = state.canEditDraft)
                                Text(stringResource(if (kind == ProviderKind.ANTHROPIC) R.string.assistant_anthropic
                                    else R.string.assistant_compatible), style = MaterialTheme.typography.bodyLarge,
                                    modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }
                AssistantSection(stringResource(R.string.assistant_section_endpoint)) {
                    OutlinedTextField(value = draft.baseURL, onValueChange = onBaseURL, enabled = state.canEditDraft,
                        label = { Text(stringResource(R.string.assistant_base_url)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                        colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest))
                }
                AssistantSection(stringResource(R.string.assistant_section_model)) {
                    var modelsExpanded by remember { mutableStateOf(false) }
                    Box {
                        OutlinedTextField(value = draft.modelID, onValueChange = onModelID, enabled = state.canEditDraft,
                            label = { Text(stringResource(R.string.assistant_model_id)) }, singleLine = true,
                            supportingText = { Text(stringResource(R.string.assistant_manual_model)) },
                            trailingIcon = {
                                IconButton(onClick = { modelsExpanded = true },
                                    enabled = state.canEditDraft && state.availableModels.isNotEmpty()) {
                                    Icon(Icons.Rounded.ArrowDropDown, stringResource(R.string.assistant_choose_model))
                                }
                            }, modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                            colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest))
                        DropdownMenu(expanded = modelsExpanded, onDismissRequest = { modelsExpanded = false }) {
                            for (model in state.availableModels) DropdownMenuItem(text = {
                                val name = model.displayName
                                Text(if (name == null || name == model.id) model.id
                                    else stringResource(R.string.assistant_model_label, name, model.id))
                            }, onClick = { modelsExpanded = false; onModelID(model.id) })
                        }
                    }
                }
                AssistantSection(stringResource(R.string.assistant_api_key)) {
                    AssistantSettingsKeyField(state.keyInputReset, state.canEditDraft,
                        stringResource(R.string.assistant_key_placeholder), onKeyInput, Modifier.fillMaxWidth())
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                        TextButton(onClick = onKeepKey, enabled = state.canEditDraft) {
                            Text(stringResource(R.string.assistant_keep_key))
                        }
                        TextButton(onClick = onClearKey, enabled = state.canEditDraft) {
                            Text(stringResource(R.string.assistant_clear_key))
                        }
                    }
                    Text(stringResource(when (state.keyEdit) {
                        AssistantKeyEdit.KEEP -> R.string.assistant_key_keep
                        AssistantKeyEdit.REPLACE -> R.string.assistant_key_replace
                        AssistantKeyEdit.CLEAR -> R.string.assistant_key_clear
                    }), style = MaterialTheme.typography.bodyMedium)
                    Text(stringResource(when (state.keyStorage) {
                        AssistantKeyStorage.None -> R.string.assistant_key_none
                        AssistantKeyStorage.Loading -> R.string.assistant_key_loading
                        is AssistantKeyStorage.Saved -> R.string.assistant_key_saved
                        is AssistantKeyStorage.Failed -> R.string.assistant_key_unknown
                    }), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else if (state.operation == null) {
                PawEmptyState(stringResource(R.string.assistant_empty_title), stringResource(R.string.assistant_empty),
                    Icons.Rounded.SmartToy)
            }
            AssistantSyncKeySection(state.syncKey, onSyncKeyInput, onSyncKeyGenerate,
                onSyncKeyEnter, onSyncKeyRemove, onSyncKeyDismissReveal)
        }
    }
    if (privacyDetails) AlertDialog(onDismissRequest = { privacyDetails = false },
        title = { Text(stringResource(R.string.design_privacy_details)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(PawSpacing.large)) {
                Text(stringResource(R.string.assistant_key_disclosure))
                Text(stringResource(R.string.assistant_outbound_disclosure))
            }
        }, confirmButton = {
            TextButton(onClick = { privacyDetails = false }) { Text(stringResource(R.string.design_close)) }
        })
    val deleting = state.profiles.firstOrNull { it.id == deleteConfirmation }
    if (deleting != null) AlertDialog(onDismissRequest = { deleteConfirmation = null },
        title = { Text(stringResource(R.string.design_delete_profile, deleting.displayName)) },
        text = { Text(stringResource(R.string.design_delete_profile_body)) },
        confirmButton = {
            TextButton(onClick = { deleteConfirmation = null; onDelete(deleting.id) }, enabled = state.canSave,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                Text(stringResource(R.string.assistant_delete))
            }
        }, dismissButton = {
            TextButton(onClick = { deleteConfirmation = null }) { Text(stringResource(R.string.fill_cancel)) }
        })
}

/** §26 S12: the dedicated key encrypts synced provider settings; it is entered here,
 * revealed once, and never uploaded. */
@Composable
private fun AssistantSyncKeySection(syncKey: AssistantSyncKey, onSyncKeyInput: (String) -> Unit,
    onGenerate: () -> Unit, onEnter: () -> Unit, onRemove: () -> Unit, onDismissReveal: () -> Unit) {
    AssistantSection(stringResource(R.string.assistant_sync_title)) {
        Text(stringResource(when (syncKey.status) {
            AssistantSyncKeyStatus.NO_ACCOUNT -> R.string.assistant_sync_no_account
            AssistantSyncKeyStatus.MISSING -> R.string.assistant_sync_missing
            AssistantSyncKeyStatus.PROVISIONED -> R.string.assistant_sync_provisioned
            AssistantSyncKeyStatus.UNAVAILABLE -> R.string.assistant_sync_unavailable
        }), style = MaterialTheme.typography.bodyMedium)
        syncKey.notice?.let {
            PawMessage(stringResource(when (it) {
                AssistantSyncKeyNotice.INVALID_KEY -> R.string.assistant_sync_notice_invalid
                AssistantSyncKeyNotice.OPERATION_FAILED -> R.string.assistant_sync_notice_failed
            }), tone = PawMessageTone.ERROR)
        }
        syncKey.revealedKey?.let { key ->
            PawMessage(stringResource(R.string.assistant_sync_reveal), tone = PawMessageTone.INFO)
            SelectionContainer {
                Text(key, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
            }
            TextButton(onClick = onDismissReveal) { Text(stringResource(R.string.assistant_sync_hide)) }
        }
        AssistantSettingsKeyField(syncKey.inputReset, syncKey.canEdit,
            stringResource(R.string.assistant_sync_key_placeholder), onSyncKeyInput, Modifier.fillMaxWidth())
        if (syncKey.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
            FilledTonalButton(onClick = onGenerate, enabled = syncKey.canEdit) {
                Text(stringResource(R.string.assistant_sync_generate))
            }
            TextButton(onClick = onEnter, enabled = syncKey.canEdit) {
                Text(stringResource(R.string.assistant_sync_enter))
            }
            TextButton(onClick = onRemove,
                enabled = syncKey.canEdit && syncKey.status == AssistantSyncKeyStatus.PROVISIONED,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                Text(stringResource(R.string.assistant_sync_remove))
            }
        }
    }
}

@Composable
private fun AssistantSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        PawSectionHeading(title)
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow,
            modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(PawSpacing.large), verticalArrangement = Arrangement.spacedBy(PawSpacing.medium),
                content = content)
        }
    }
}

@Composable
private fun AssistantSettingsDock(state: AssistantSettingsUiState, onSave: () -> Unit, onTest: () -> Unit,
    onCancelTest: () -> Unit) {
    Column {
        val progress = state.operation?.let {
            when (it) {
                AssistantSettingsOperation.LOADING -> R.string.assistant_loading
                AssistantSettingsOperation.SAVING -> R.string.assistant_saving
                AssistantSettingsOperation.SELECTING -> R.string.assistant_selecting
                AssistantSettingsOperation.DELETING -> R.string.assistant_deleting
            }
        } ?: R.string.assistant_testing.takeIf { state.isTesting }
        val failures = listOfNotNull(state.readOnlyError, state.error,
            (state.keyStorage as? AssistantKeyStorage.Failed)?.error).distinct()
        if (progress != null || failures.isNotEmpty() || state.testResult != null) {
            Column(Modifier.fillMaxWidth().heightIn(max = 200.dp).verticalScroll(rememberScrollState())
                .padding(horizontal = PawSpacing.large, vertical = PawSpacing.small),
                verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                if (progress != null) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(progress), style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f))
                        if (state.isTesting) {
                            TextButton(onClick = onCancelTest) { Text(stringResource(R.string.assistant_cancel_test)) }
                        }
                    }
                }
                for (failure in failures) {
                    PawMessage(stringResource(settingsErrorResource(failure)), tone = PawMessageTone.ERROR)
                }
                state.testResult?.let { PawMessage(testResultMessage(it), tone = testResultTone(it)) }
            }
        }
        PawActionBar {
            OutlinedButton(onClick = onTest, enabled = state.canTest, modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.assistant_test))
            }
            Button(onClick = onSave, enabled = state.canSave, modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.assistant_save))
            }
        }
    }
}

private fun testResultTone(result: ConnectionTestResult): PawMessageTone = when (result) {
    is ConnectionTestResult.Ok -> PawMessageTone.SUCCESS
    ConnectionTestResult.Cancelled -> PawMessageTone.INFO
    else -> PawMessageTone.ERROR
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
