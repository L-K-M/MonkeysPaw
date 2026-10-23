package ch.lkmc.monkeyspaw.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing
import ch.lkmc.monkeyspaw.ui.theme.PawLayout

@Composable
internal fun AccountScreen(
    state: AccountUiState,
    onServer: (String) -> Unit, onUsername: (String) -> Unit, onPassword: (String) -> Unit, onDeviceName: (String) -> Unit,
    onSignIn: () -> Unit, onRefresh: () -> Unit, onCancel: () -> Unit, onBack: () -> Unit,
    onTrust: (Boolean) -> Unit, onRequestSignOut: () -> Unit, onSignOut: () -> Unit,
    onRequestRevoke: (String) -> Unit, onRevoke: () -> Unit,
    onSelectHold: (HeldIdentity) -> Unit,
    onRequestInclude: () -> Unit, onInclude: () -> Unit, onDismissConfirmation: () -> Unit,
    onSyncNow: () -> Unit, onSyncDetails: () -> Unit, onRecover: () -> Unit,
    onInviteDraft: (String) -> Unit, onStageInvite: () -> Unit, onInviteMode: (InviteMode) -> Unit,
    onAcceptInvite: () -> Unit, onDismissInvite: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val trustDescription = stringResource(R.string.account_trust)
    var securityExpanded by remember(state.server) { mutableStateOf(state.trustsUserCAs) }
    PawScreen(stringResource(R.string.account_title), modifier, onBack = onBack, contentMaxWidth = PawLayout.formWidth, actions = {
        IconButton(onClick = onRefresh, enabled = state.busy == null) {
            Icon(Icons.Rounded.Refresh, stringResource(R.string.library_refresh))
        }
    }) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PawLayout.contentPadding,
            verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
            if (state.account.account == null) item {
                PawIntro(stringResource(R.string.design_account_intro), stringResource(R.string.design_account_intro_help),
                    Icons.Rounded.CloudSync)
            }
            if (state.account.account != null || state.busy != null || state.failure != null || !state.cleanup.isComplete) item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                    if (state.account.account != null || state.busy != null) Surface(shape = MaterialTheme.shapes.large,
                        color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(PawSpacing.large),
                            verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(PawSpacing.medium),
                                verticalAlignment = Alignment.CenterVertically) {
                                Icon(conditionIcon(state.condition), null, Modifier.size(20.dp),
                                    tint = conditionTint(state.condition))
                                Text(stringResource(state.conditionText), style = MaterialTheme.typography.titleMedium)
                            }
                            state.account.account?.let {
                                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                                    Text(stringResource(R.string.account_connection, it.username, it.identity.serverURL),
                                        style = MaterialTheme.typography.bodyMedium)
                                    Text(stringResource(R.string.account_device_identity, it.deviceName),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            if (state.busy != null) {
                                LinearProgressIndicator(Modifier.fillMaxWidth())
                                if (state.busy != AccountAction.SIGN_OUT) {
                                    TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.End)) {
                                        Text(stringResource(R.string.fill_cancel))
                                    }
                                }
                            }
                        }
                    }
                    state.failure?.let { PawMessage(stringResource(it), tone = PawMessageTone.ERROR) }
                    if (!state.cleanup.isComplete) CleanupNotice(state)
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    PawSectionHeading(stringResource(R.string.account_sign_in_section))
                    Surface(shape = MaterialTheme.shapes.large,
                        color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(PawSpacing.large),
                            verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                            OutlinedTextField(state.draft.server, onServer,
                                label = { Text(stringResource(R.string.account_server)) }, singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                                 modifier = Modifier.fillMaxWidth(), colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest), shape = MaterialTheme.shapes.medium)
                            if (state.httpWarning) {
                                PawMessage(stringResource(R.string.account_http_warning), tone = PawMessageTone.WARNING)
                            }
                            OutlinedTextField(state.draft.username, onUsername,
                                label = { Text(stringResource(R.string.account_username)) },
                                singleLine = true, modifier = Modifier.fillMaxWidth(), colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest), shape = MaterialTheme.shapes.medium)
                            OutlinedTextField(state.draft.deviceName, onDeviceName,
                                label = { Text(stringResource(R.string.account_device_name)) },
                                singleLine = true, modifier = Modifier.fillMaxWidth(), colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest), shape = MaterialTheme.shapes.medium)
                            OutlinedTextField(state.draft.password, onPassword,
                                label = { Text(stringResource(R.string.account_password)) },
                                singleLine = true, visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                                modifier = Modifier.fillMaxWidth(), colors = pawInputColors(MaterialTheme.colorScheme.surfaceContainerLowest), shape = MaterialTheme.shapes.medium)
                            TextButton(onClick = { securityExpanded = !securityExpanded }) {
                                Icon(Icons.Rounded.Security, null, Modifier.size(20.dp))
                                Spacer(Modifier.width(PawSpacing.small))
                                Text(stringResource(R.string.design_connection_security))
                                Spacer(Modifier.width(PawSpacing.small))
                                Icon(if (securityExpanded) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore, null)
                            }
                            if (securityExpanded) Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(stringResource(R.string.account_trust), style = MaterialTheme.typography.bodyLarge)
                                    Text(stringResource(R.string.account_trust_detail), style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Switch(checked = state.trustsUserCAs, onCheckedChange = onTrust,
                                    enabled = state.busy == null && state.server != null && !state.httpWarning,
                                    modifier = Modifier.semantics { contentDescription = trustDescription })
                            }
                            Button(onClick = onSignIn, enabled = state.canSignIn, modifier = Modifier.fillMaxWidth()) {
                                Text(stringResource(if (state.account.account == null) R.string.account_sign_in
                                    else R.string.account_reauthenticate))
                            }
                            if (state.canSignOut) {
                                TextButton(onClick = onRequestSignOut, enabled = state.busy != AccountAction.SIGN_OUT,
                                    colors = ButtonDefaults.textButtonColors(
                                        contentColor = MaterialTheme.colorScheme.error)) {
                                    Text(stringResource(R.string.account_sign_out))
                                }
                            }
                        }
                    }
                }
            }
            item { AccountInviteSection(state, onInviteDraft, onStageInvite, onInviteMode, onAcceptInvite, onDismissInvite) }
            if (state.account.account == null) return@LazyColumn
            item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    PawSectionHeading(stringResource(R.string.account_sync_section))
                    SyncFooter(state.sync, onSyncDetails)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                        Button(onClick = onSyncNow, enabled = state.canSync) {
                            Text(stringResource(R.string.sync_now))
                        }
                        if (state.condition == AccountCondition.RECOVERY) {
                            TextButton(onClick = onRecover, enabled = state.busy == null) {
                                Text(stringResource(R.string.sync_retry_recovery))
                            }
                        }
                    }
                }
            }
            item { PawSectionHeading(stringResource(R.string.account_devices)) }
            if (state.account.me == null) item { Text(stringResource(R.string.account_devices_unavailable),
                style = MaterialTheme.typography.bodyMedium) }
            items(state.account.me?.devices.orEmpty(), key = { "device:" + it.id }) { device ->
                ListItem(headlineContent = { Text(device.name) }, leadingContent = {
                    Icon(Icons.Rounded.Devices, null, tint = MaterialTheme.colorScheme.primary)
                }, supportingContent = {
                    Column {
                        if (device.isCurrent) Text(stringResource(R.string.account_current_device),
                            style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                        device.lastSeenAt?.let { Text(stringResource(R.string.account_last_seen, it)) }
                        if (device.revokedAt != null) Text(stringResource(R.string.account_device_revoked),
                            color = MaterialTheme.colorScheme.error)
                    }
                }, trailingContent = {
                    if (device.revokedAt == null) TextButton(onClick = { onRequestRevoke(device.id) },
                        enabled = state.busy == null && state.account.enabled,
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(stringResource(R.string.account_revoke))
                    }
                }, colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow))
            }
            if (state.account.me?.groups.orEmpty().isNotEmpty()) {
                item { PawSectionHeading(stringResource(R.string.account_memberships)) }
                items(state.account.me?.groups.orEmpty(), key = { "group:" + it.groupID }) { membership ->
                    ListItem(headlineContent = { Text(stringResource(R.string.account_membership, membership.name, membership.role.wireValue)) },
                        leadingContent = { Icon(Icons.Rounded.Group, null, tint = MaterialTheme.colorScheme.primary) },
                        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow))
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    PawSectionHeading(stringResource(R.string.account_held_title), stringResource(R.string.account_held_detail))
                    if (state.holds.isEmpty()) {
                        Text(stringResource(R.string.account_no_holds), style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
            items(state.holds, key = { "hold:" + it.identity.storageKey }) { hold ->
                val description = stringResource(R.string.account_select_hold, hold.path)
                Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, shape = MaterialTheme.shapes.medium) {
                    Row(Modifier.fillMaxWidth().heightIn(min = PawLayout.touchTarget)
                        .toggleable(value = hold.identity in state.selectedHolds, enabled = state.busy == null && state.account.enabled,
                            role = Role.Checkbox, onValueChange = { onSelectHold(hold.identity) })
                        .semantics { contentDescription = description }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = hold.identity in state.selectedHolds, onCheckedChange = null,
                            enabled = state.busy == null && state.account.enabled)
                        Text(hold.path, style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f).padding(end = PawSpacing.large))
                    }
                }
            }
            if (state.holds.isNotEmpty()) item {
                Button(onClick = onRequestInclude,
                    enabled = state.busy == null && state.account.enabled && state.selectedHolds.isNotEmpty()) {
                    Text(stringResource(R.string.account_include))
                }
            }
        }
    }
    val revoke = state.account.me?.devices?.firstOrNull { it.id == state.revokeConfirmation }
    if (state.signOutConfirmation || revoke != null || state.includeConfirmation) AlertDialog(
        onDismissRequest = onDismissConfirmation,
        title = { Text(stringResource(when {
            state.signOutConfirmation -> R.string.account_sign_out
            revoke != null -> R.string.account_revoke
            else -> R.string.account_include
        })) },
        text = { Text(when {
            state.signOutConfirmation -> stringResource(R.string.account_sign_out_confirm)
            revoke != null -> stringResource(if (revoke.isCurrent) R.string.account_revoke_current_confirm
                else R.string.account_revoke_confirm, revoke.name)
            else -> pluralStringResource(R.plurals.account_include_confirm, state.selectedHolds.size,
                state.selectedHolds.size,
                state.account.account?.username.orEmpty(), state.account.account?.identity?.serverURL.orEmpty())
        }) },
        confirmButton = { TextButton(onClick = when {
            state.signOutConfirmation -> onSignOut
            revoke != null -> onRevoke
            else -> onInclude
        }, enabled = state.busy == null,
            colors = if (state.signOutConfirmation || revoke != null)
                ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error) else ButtonDefaults.textButtonColors()) {
            Text(stringResource(when {
                state.signOutConfirmation -> R.string.account_sign_out
                revoke != null -> R.string.account_revoke
                else -> R.string.account_include
            }))
        } },
        dismissButton = { TextButton(onClick = onDismissConfirmation) { Text(stringResource(R.string.fill_cancel)) } },
    )
}

private fun conditionIcon(condition: AccountCondition): ImageVector = when (condition) {
    AccountCondition.ACTIVE -> Icons.Rounded.CloudDone
    AccountCondition.OFFLINE -> Icons.Rounded.CloudOff
    AccountCondition.NEEDS_SIGN_IN -> Icons.Rounded.SyncProblem
    AccountCondition.RECOVERY -> Icons.Rounded.WarningAmber
    AccountCondition.INACTIVE -> Icons.Rounded.SyncDisabled
}

@Composable
private fun conditionTint(condition: AccountCondition): Color = when (condition) {
    AccountCondition.ACTIVE -> MaterialTheme.colorScheme.primary
    AccountCondition.INACTIVE -> MaterialTheme.colorScheme.onSurfaceVariant
    AccountCondition.OFFLINE -> MaterialTheme.colorScheme.tertiary
    else -> MaterialTheme.colorScheme.error
}

@Composable
private fun CleanupNotice(state: AccountUiState) {
    if (state.cleanup.isComplete) return
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        PawMessage(stringResource(R.string.account_cleanup_incomplete), tone = PawMessageTone.ERROR)
        if (state.remoteCleanupUnconfirmed) {
            Text(stringResource(R.string.account_remote_unconfirmed), style = MaterialTheme.typography.bodyMedium)
        }
        if (state.cleanup.secretFailures.isNotEmpty()) {
            Text(stringResource(R.string.account_secret_cleanup, state.cleanup.secretFailures.size),
                style = MaterialTheme.typography.bodyMedium)
        }
        if (state.cleanup.metadataIssue != null) {
            Text(stringResource(R.string.account_metadata_cleanup), style = MaterialTheme.typography.bodyMedium)
        }
        if (state.cleanup.recoveryRequired) {
            Text(stringResource(R.string.sync_recovery_required), style = MaterialTheme.typography.bodyMedium)
        }
    }
}
