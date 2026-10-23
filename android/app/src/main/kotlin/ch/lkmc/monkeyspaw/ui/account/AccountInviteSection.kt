package ch.lkmc.monkeyspaw.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing
import ch.lkmc.monkeyspaw.ui.theme.PawLayout

@Composable
internal fun AccountInviteSection(
    state: AccountUiState, onDraft: (String) -> Unit, onStage: () -> Unit,
    onMode: (InviteMode) -> Unit, onAccept: () -> Unit, onDismiss: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
        PawSectionHeading(stringResource(R.string.invite_title))
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow,
            modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(PawSpacing.large), verticalArrangement = Arrangement.spacedBy(PawSpacing.medium)) {
                OutlinedTextField(state.inviteDraft, onDraft, label = { Text(stringResource(R.string.invite_input)) },
                    enabled = state.busy == null, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth())
                FlowRow(horizontalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    OutlinedButton(onClick = onStage, enabled = state.busy == null && state.inviteDraft.isNotEmpty()) {
                        Text(stringResource(R.string.invite_review))
                    }
                    if (state.invite != null || state.inviteDraft.isNotEmpty()) {
                        TextButton(onClick = onDismiss) { Text(stringResource(R.string.fill_cancel)) }
                    }
                }
                state.invite?.let { invite ->
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                        Text(stringResource(R.string.invite_destination, invite.serverURL),
                            style = MaterialTheme.typography.bodyLarge)
                        val current = invite.currentAccount
                        Text(if (current == null) stringResource(R.string.invite_no_account)
                            else stringResource(R.string.account_connection, current.username, current.identity.serverURL),
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (invite.usesHTTP) {
                        PawMessage(stringResource(R.string.invite_http_warning), tone = PawMessageTone.WARNING)
                    }
                    Column(Modifier.selectableGroup()) {
                        for (mode in InviteMode.entries) {
                            val description = stringResource(if (mode == InviteMode.EXISTING_ACCOUNT) R.string.invite_existing
                                else R.string.invite_new)
                            Row(Modifier.fillMaxWidth().heightIn(min = PawLayout.touchTarget)
                                .selectable(selected = state.inviteMode == mode, enabled = state.busy == null,
                                    role = Role.RadioButton, onClick = { onMode(mode) }),
                                verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = state.inviteMode == mode, onClick = null, enabled = state.busy == null)
                                Text(description, style = MaterialTheme.typography.bodyLarge)
                            }
                        }
                    }
                    if (state.inviteMode == InviteMode.NEW_ACCOUNT) {
                        Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.xs)) {
                            Text(stringResource(R.string.invite_registration_detail), style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(stringResource(R.string.invite_new_destination, state.draft.username, invite.serverURL),
                                style = MaterialTheme.typography.bodyMedium)
                        }
                    } else if (!invite.canJoin) {
                        PawMessage(stringResource(R.string.invite_authenticate), tone = PawMessageTone.INFO)
                    }
                    Button(onClick = onAccept, enabled = state.canAcceptInvite) {
                        Text(stringResource(if (state.inviteMode == InviteMode.NEW_ACCOUNT) R.string.invite_accept_new
                            else R.string.invite_accept))
                    }
                }
                state.inviteMessage?.let { PawMessage(stringResource(it), tone = PawMessageTone.INFO) }
            }
        }
    }
}
