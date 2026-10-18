package ch.lkmc.monkeyspaw.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import ch.lkmc.monkeyspaw.R

@Composable
internal fun AccountInviteSection(
    state: AccountUiState, onDraft: (String) -> Unit, onStage: () -> Unit,
    onMode: (InviteMode) -> Unit, onAccept: () -> Unit, onDismiss: () -> Unit,
) {
    Column {
        Text(stringResource(R.string.invite_title), style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(state.inviteDraft, onDraft, label = { Text(stringResource(R.string.invite_input)) },
            enabled = state.busy == null, singleLine = true, visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth())
        TextButton(onClick = onStage, enabled = state.busy == null && state.inviteDraft.isNotEmpty()) {
            Text(stringResource(R.string.invite_review))
        }
        state.invite?.let { invite ->
            Text(stringResource(R.string.invite_destination, invite.serverURL))
            val current = invite.currentAccount
            Text(if (current == null) stringResource(R.string.invite_no_account)
                else stringResource(R.string.account_connection, current.username, current.identity.serverURL))
            if (invite.usesHTTP) Text(stringResource(R.string.invite_http_warning), color = MaterialTheme.colorScheme.error)
            for (mode in InviteMode.entries) Row {
                val description = stringResource(if (mode == InviteMode.EXISTING_ACCOUNT) R.string.invite_existing else R.string.invite_new)
                RadioButton(selected = state.inviteMode == mode, onClick = { onMode(mode) }, enabled = state.busy == null,
                    modifier = Modifier.semantics { contentDescription = description })
                Text(description)
            }
            if (state.inviteMode == InviteMode.NEW_ACCOUNT) {
                Text(stringResource(R.string.invite_registration_detail))
                Text(stringResource(R.string.invite_new_destination, state.draft.username, invite.serverURL))
            } else if (!invite.canJoin) Text(stringResource(R.string.invite_authenticate))
            Button(onClick = onAccept, enabled = state.canAcceptInvite) {
                Text(stringResource(if (state.inviteMode == InviteMode.NEW_ACCOUNT) R.string.invite_accept_new else R.string.invite_accept))
            }
        }
        state.inviteMessage?.let { Text(stringResource(it)) }
        if (state.invite != null || state.inviteDraft.isNotEmpty()) TextButton(onClick = onDismiss) {
            Text(stringResource(R.string.fill_cancel))
        }
    }
}
