package ch.lkmc.monkeyspaw.ui.setup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ch.lkmc.monkeyspaw.R

@Composable
internal fun SettingsScreen(onKeyboardTileSetup: () -> Unit, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    Column(modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.settings_title), style = MaterialTheme.typography.headlineMedium)
        Button(onClick = onKeyboardTileSetup) { Text(stringResource(R.string.setup_title)) }
        TextButton(onClick = onBack) { Text(stringResource(R.string.setup_back)) }
    }
}
