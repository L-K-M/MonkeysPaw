package ch.lkmc.monkeyspaw.ui.locallibrary

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R

@Composable
internal fun SeedOfferScreen(
    state: SeedOfferUiState,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.local_library_title), style = MaterialTheme.typography.headlineMedium)
        when (state) {
            SeedOfferUiState.Loading, SeedOfferUiState.Installing -> {
                CircularProgressIndicator()
                Text(stringResource(if (state == SeedOfferUiState.Installing) R.string.seeds_installing else R.string.library_loading))
            }
            SeedOfferUiState.Offer -> {
                Text(stringResource(R.string.seeds_offer_title), style = MaterialTheme.typography.titleLarge)
                Text(stringResource(R.string.seeds_offer_help))
                Button(onClick = onAccept) { Text(stringResource(R.string.seeds_accept)) }
                TextButton(onClick = onDecline) { Text(stringResource(R.string.seeds_decline)) }
            }
            SeedOfferUiState.Ready -> Unit // MainActivity routes the completed offer to LibraryScreen.
            is SeedOfferUiState.Failed -> {
                Text(stringResource(if (state.partial == null) R.string.library_load_failed else R.string.seeds_failed))
                state.partial?.let { Text(pluralStringResource(R.plurals.seeds_added_count, it.seededCount, it.seededCount)) }
                Button(onClick = onRefresh) {
                    Text(stringResource(if (state.partial == null) R.string.retry else R.string.continue_to_library))
                }
            }
        }
    }
}
