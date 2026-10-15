package ch.lkmc.monkeyspaw.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R

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
    modifier: Modifier = Modifier,
) {
    val trustDescription = stringResource(R.string.account_trust)
    LazyColumn(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TextButton(onClick = onBack) { Text(stringResource(R.string.account_back)) }
            Text(stringResource(R.string.account_title), style = MaterialTheme.typography.headlineMedium)
            Text(stringResource(state.conditionText))
            state.account.account?.let {
                Text(stringResource(R.string.account_connection, it.username, it.identity.serverURL))
                Text(stringResource(R.string.account_device_identity, it.deviceName))
            }
            if (state.busy != null) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                if (state.busy != AccountAction.SIGN_OUT) TextButton(onClick = onCancel) { Text(stringResource(R.string.fill_cancel)) }
            }
            state.failure?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            CleanupNotice(state)
        }
        item {
            OutlinedTextField(state.draft.server, onServer, label = { Text(stringResource(R.string.account_server)) },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            if (state.httpWarning) Text(stringResource(R.string.account_http_warning), color = MaterialTheme.colorScheme.error)
            Row {
                Switch(checked = state.trustsUserCAs, onCheckedChange = onTrust,
                    enabled = state.busy == null && state.server != null && !state.httpWarning,
                    modifier = Modifier.semantics { contentDescription = trustDescription })
                Text(stringResource(R.string.account_trust), modifier = Modifier.padding(start = 8.dp, top = 12.dp))
            }
            Text(stringResource(R.string.account_trust_detail), style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(state.draft.username, onUsername, label = { Text(stringResource(R.string.account_username)) },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(state.draft.deviceName, onDeviceName, label = { Text(stringResource(R.string.account_device_name)) },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(state.draft.password, onPassword, label = { Text(stringResource(R.string.account_password)) },
                singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth())
            Button(onClick = onSignIn, enabled = state.canSignIn) {
                Text(stringResource(if (state.account.account == null) R.string.account_sign_in else R.string.account_reauthenticate))
            }
            TextButton(onClick = onRefresh, enabled = state.busy == null) { Text(stringResource(R.string.library_refresh)) }
            if (state.canSignOut) TextButton(onClick = onRequestSignOut,
                enabled = state.busy != AccountAction.SIGN_OUT) { Text(stringResource(R.string.account_sign_out)) }
        }
        item {
            SyncFooter(state.sync, onSyncDetails)
            TextButton(onClick = onSyncNow, enabled = state.canSync) { Text(stringResource(R.string.sync_now)) }
            if (state.condition == AccountCondition.RECOVERY) TextButton(onClick = onRecover, enabled = state.busy == null) {
                Text(stringResource(R.string.sync_retry_recovery))
            }
        }
        item { Text(stringResource(R.string.account_devices), style = MaterialTheme.typography.titleMedium) }
        if (state.account.me == null) item { Text(stringResource(R.string.account_devices_unavailable)) }
        items(state.account.me?.devices.orEmpty(), key = { it.id }) { device ->
            Column {
                Text(device.name)
                if (device.isCurrent) Text(stringResource(R.string.account_current_device))
                device.lastSeenAt?.let { Text(stringResource(R.string.account_last_seen, it)) }
                if (device.revokedAt != null) Text(stringResource(R.string.account_device_revoked))
                else TextButton(onClick = { onRequestRevoke(device.id) }, enabled = state.busy == null && state.account.enabled) {
                    Text(stringResource(R.string.account_revoke))
                }
            }
        }
        item { Text(stringResource(R.string.account_memberships), style = MaterialTheme.typography.titleMedium) }
        items(state.account.me?.groups.orEmpty(), key = { it.groupID }) {
            Text(stringResource(R.string.account_membership, it.name, it.role.wireValue))
        }
        item {
            Text(stringResource(R.string.account_held_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.account_held_detail))
            if (state.holds.isEmpty()) Text(stringResource(R.string.account_no_holds))
        }
        items(state.holds, key = { it.identity.storageKey }) { hold ->
            val description = stringResource(R.string.account_select_hold, hold.path)
            Row {
                Checkbox(checked = hold.identity in state.selectedHolds, onCheckedChange = { onSelectHold(hold.identity) },
                    enabled = state.busy == null && state.account.enabled,
                    modifier = Modifier.semantics { contentDescription = description })
                Text(hold.path, modifier = Modifier.padding(top = 12.dp))
            }
        }
        if (state.holds.isNotEmpty()) item {
            Button(onClick = onRequestInclude, enabled = state.busy == null && state.account.enabled && state.selectedHolds.isNotEmpty()) {
                Text(stringResource(R.string.account_include))
            }
        }
        item { Spacer(Modifier.height(12.dp)) }
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
            revoke != null -> stringResource(if (revoke.isCurrent) R.string.account_revoke_current_confirm else R.string.account_revoke_confirm, revoke.name)
            else -> pluralStringResource(R.plurals.account_include_confirm, state.selectedHolds.size, state.selectedHolds.size,
                state.account.account?.username.orEmpty(), state.account.account?.identity?.serverURL.orEmpty())
        }) },
        confirmButton = { TextButton(onClick = when {
            state.signOutConfirmation -> onSignOut
            revoke != null -> onRevoke
            else -> onInclude
        }) { Text(stringResource(R.string.account_confirm)) } },
        dismissButton = { TextButton(onClick = onDismissConfirmation) { Text(stringResource(R.string.fill_cancel)) } },
    )
}

@Composable
private fun CleanupNotice(state: AccountUiState) {
    if (state.cleanup.isComplete) return
    Text(stringResource(R.string.account_cleanup_incomplete), color = MaterialTheme.colorScheme.error)
    if (state.remoteCleanupUnconfirmed) Text(stringResource(R.string.account_remote_unconfirmed))
    if (state.cleanup.secretFailures.isNotEmpty()) Text(stringResource(R.string.account_secret_cleanup, state.cleanup.secretFailures.size))
    if (state.cleanup.metadataIssue != null) Text(stringResource(R.string.account_metadata_cleanup))
    if (state.cleanup.recoveryRequired) Text(stringResource(R.string.sync_recovery_required))
}
