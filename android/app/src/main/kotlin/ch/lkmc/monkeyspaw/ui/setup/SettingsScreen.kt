package ch.lkmc.monkeyspaw.ui.setup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.ui.components.*
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing
import ch.lkmc.monkeyspaw.ui.theme.PawLayout

@Composable
internal fun SettingsScreen(onKeyboardTileSetup: () -> Unit, onBack: () -> Unit, modifier: Modifier = Modifier,
    onAccount: (() -> Unit)? = null, onAssistantSettings: (() -> Unit)? = null) {
    BackHandler(onBack = onBack)
    PawScreen(stringResource(R.string.settings_title), modifier, onBack = onBack, style = PawScreenStyle.OVERVIEW) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(PawLayout.pageGutter),
            verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
            Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                PawSectionHeading(stringResource(R.string.design_library_group))
                Surface(shape = MaterialTheme.shapes.large) {
                    Column {
                        PawSettingRow(stringResource(R.string.setup_title), stringResource(R.string.design_keyboard_subtitle),
                            Icons.Rounded.Keyboard, onKeyboardTileSetup)
                        onAccount?.let { account ->
                            HorizontalDivider(Modifier.padding(start = PawLayout.iconWell + PawSpacing.page),
                                color = MaterialTheme.colorScheme.surface)
                            PawSettingRow(stringResource(R.string.account_title), stringResource(R.string.design_account_subtitle),
                                Icons.Rounded.AccountCircle, account)
                        }
                    }
                }
            }
            onAssistantSettings?.let { settings ->
                Column(verticalArrangement = Arrangement.spacedBy(PawSpacing.small)) {
                    PawSectionHeading(stringResource(R.string.design_assistant_section))
                    Surface(shape = MaterialTheme.shapes.large) {
                        PawSettingRow(stringResource(R.string.assistant_settings_title), stringResource(R.string.design_assistant_subtitle),
                            Icons.Rounded.Tune, settings)
                    }
                }
            }
        }
    }
}
