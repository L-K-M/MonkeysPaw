package ch.lkmc.monkeyspaw.ui.locallibrary

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing
import ch.lkmc.monkeyspaw.ui.theme.PawLayout

@Composable
internal fun SeedOfferScreen(
    state: SeedOfferUiState,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    onSettings: (() -> Unit)? = null,
) {
    PawScreen(stringResource(R.string.design_library_title), modifier, contentMaxWidth = PawLayout.formWidth,
        bottomBar = { if (state == SeedOfferUiState.Offer) PawActionDock {
            TextButton(onClick = onDecline) { Text(stringResource(R.string.seeds_decline)) }
            Button(onClick = onAccept) { Text(stringResource(R.string.seeds_accept)) }
        } }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(PawLayout.pageGutter),
            verticalArrangement = Arrangement.spacedBy(PawSpacing.large)) {
            when (state) {
                SeedOfferUiState.Loading, SeedOfferUiState.Installing -> {
                    PawLoading(stringResource(if (state == SeedOfferUiState.Installing) R.string.seeds_installing else R.string.library_loading))
                }
                SeedOfferUiState.Offer -> {
                    PawIntro(stringResource(R.string.seeds_offer_title), stringResource(R.string.seeds_offer_help), Icons.Rounded.AutoAwesome)
                }
                SeedOfferUiState.Ready -> Unit // MainActivity routes the completed offer to LibraryScreen.
                is SeedOfferUiState.Failed -> {
                    PawMessage(stringResource(if (state.partial == null) R.string.library_load_failed else R.string.seeds_failed), tone = PawMessageTone.ERROR)
                    state.partial?.let { Text(pluralStringResource(R.plurals.seeds_added_count, it.seededCount, it.seededCount)) }
                    Button(onClick = onRefresh) {
                        Text(stringResource(if (state.partial == null) R.string.retry else R.string.continue_to_library))
                    }
                    onSettings?.let { TextButton(onClick = it) { Text(stringResource(R.string.account_settings)) } }
                }
            }
        }
    }
}
